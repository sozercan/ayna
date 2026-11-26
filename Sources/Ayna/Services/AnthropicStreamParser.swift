import Foundation
import os

private enum AnthropicStreamParserLimits {
    static let initialBlockBufferCapacity = 1024
    static let maxToolInputSize = 10_485_760
    static let maxSignatureSize = 65_536
}

struct AnthropicStreamResult: Sendable {
    let shouldComplete: Bool
    let content: String?
    let reasoning: String?
    let toolCall: AnthropicToolCall?
    let error: (any Error)?

    static var empty: AnthropicStreamResult {
        AnthropicStreamResult(
            shouldComplete: false,
            content: nil,
            reasoning: nil,
            toolCall: nil,
            error: nil
        )
    }
}

struct AnthropicToolCall: Sendable {
    let id: String
    let name: String
    let input: [String: AnyCodable]
}

enum AnthropicContentBlockType: String {
    case text
    case thinking
    case redactedThinking = "redacted_thinking"
    case toolUse = "tool_use"
}

struct AnthropicBlockState {
    let type: AnthropicContentBlockType
    var buffer: Data
    var toolName: String?
    var toolId: String?

    init(type: AnthropicContentBlockType, toolName: String? = nil, toolId: String? = nil) {
        self.type = type
        buffer = Data(capacity: AnthropicStreamParserLimits.initialBlockBufferCapacity)
        self.toolName = toolName
        self.toolId = toolId
    }
}

final class AnthropicStreamParser {
    private var pendingEventType: String?

    private var activeBlocks: [Int: AnthropicBlockState] = [:]

    private(set) var stopReason: String?

    private(set) var messageId: String?

    typealias ChunkCallback = @Sendable (String) -> Void
    typealias ReasoningCallback = @Sendable (String) -> Void
    typealias ToolCallCallback = @Sendable (String, String, [String: AnyCodable]) -> Void
    typealias CompleteCallback = @Sendable () -> Void
    typealias ErrorCallback = @Sendable (any Error) -> Void

    private let onChunk: ChunkCallback?
    private let onReasoning: ReasoningCallback?
    private let onToolCallRequested: ToolCallCallback?
    private let onComplete: CompleteCallback?
    private let onError: ErrorCallback?

    init(
        onChunk: ChunkCallback? = nil,
        onReasoning: ReasoningCallback? = nil,
        onToolCallRequested: ToolCallCallback? = nil,
        onComplete: CompleteCallback? = nil,
        onError: ErrorCallback? = nil
    ) {
        self.onChunk = onChunk
        self.onReasoning = onReasoning
        self.onToolCallRequested = onToolCallRequested
        self.onComplete = onComplete
        self.onError = onError
    }

    func processLine(_ line: String) -> AnthropicStreamResult {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLine.isEmpty else {
            return .empty
        }

        if trimmedLine.hasPrefix(Self.eventFieldPrefix) {
            var eventType = trimmedLine.dropFirst(Self.eventFieldPrefix.count)
            if eventType.first == " " {
                eventType = eventType.dropFirst()
            }
            pendingEventType = String(eventType)
            return .empty
        }

        if trimmedLine.hasPrefix(Self.dataFieldPrefix) {
            var dataValue = trimmedLine.dropFirst(Self.dataFieldPrefix.count)
            if dataValue.first == " " {
                dataValue = dataValue.dropFirst()
            }
            let dataString = String(dataValue)

            if dataString.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingEventType = nil
                return .empty
            }

            let result = processDataLine(Data(dataString.utf8), eventType: pendingEventType)
            pendingEventType = nil
            return result
        }

        return .empty
    }

    func processLine(_ lineData: Data) -> AnthropicStreamResult {
        guard let trimmedRange = Self.asciiTrimmedRange(in: lineData) else {
            return .empty
        }

        if Self.hasPrefix(Self.eventLinePrefix, in: lineData, range: trimmedRange) {
            let eventStart = Self.fieldValueStart(
                after: Self.eventLinePrefix,
                in: lineData,
                range: trimmedRange
            )
            pendingEventType = String(data: lineData[eventStart ..< trimmedRange.upperBound], encoding: .utf8)
            return .empty
        }

        if Self.hasPrefix(Self.dataLinePrefix, in: lineData, range: trimmedRange) {
            let dataStart = Self.fieldValueStart(
                after: Self.dataLinePrefix,
                in: lineData,
                range: trimmedRange
            )
            let data = lineData[dataStart ..< trimmedRange.upperBound]
            let result = processDataLine(data, eventType: pendingEventType)
            pendingEventType = nil
            return result
        }

        return .empty
    }

    private static let eventFieldPrefix = "event:"
    private static let dataFieldPrefix = "data:"
    private static let eventLinePrefix: [UInt8] = Array(eventFieldPrefix.utf8)
    private static let dataLinePrefix: [UInt8] = Array(dataFieldPrefix.utf8)

    private static func asciiTrimmedRange(in data: Data) -> Range<Data.Index>? {
        var start = data.startIndex
        var end = data.endIndex

        while start < end, isASCIIWhitespace(data[start]) {
            start = data.index(after: start)
        }
        while start < end {
            let previous = data.index(before: end)
            if !isASCIIWhitespace(data[previous]) {
                break
            }
            end = previous
        }

        return start < end ? start ..< end : nil
    }

    private static func hasPrefix(_ prefix: [UInt8], in data: Data, range: Range<Data.Index>) -> Bool {
        guard data.distance(from: range.lowerBound, to: range.upperBound) >= prefix.count else {
            return false
        }

        for (offset, byte) in prefix.enumerated() where data[range.lowerBound + offset] != byte {
            return false
        }
        return true
    }

    private static func fieldValueStart(
        after prefix: [UInt8],
        in data: Data,
        range: Range<Data.Index>
    ) -> Data.Index {
        let start = range.lowerBound + prefix.count
        guard start < range.upperBound, data[start] == 0x20 else {
            return start
        }
        return data.index(after: start)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
            true
        default:
            false
        }
    }

    func reset() {
        pendingEventType = nil
        activeBlocks.removeAll()
        stopReason = nil
        messageId = nil
    }

    private func processDataLine(_ data: Data, eventType: String?) -> AnthropicStreamResult {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .empty
        }

        let type = json["type"] as? String ?? eventType ?? ""

        switch type {
        case "message_start":
            return handleMessageStart(json)

        case "content_block_start":
            return handleContentBlockStart(json)

        case "content_block_delta":
            return handleContentBlockDelta(json)

        case "content_block_stop":
            return handleContentBlockStop(json)

        case "message_delta":
            return handleMessageDelta(json)

        case "message_stop":
            onComplete?()
            return AnthropicStreamResult(
                shouldComplete: true,
                content: nil,
                reasoning: nil,
                toolCall: nil,
                error: nil
            )

        case "ping":
            return .empty

        case "error":
            return handleError(json)

        default:
            return .empty
        }
    }

    private func handleMessageStart(_ json: [String: Any]) -> AnthropicStreamResult {
        if let message = json["message"] as? [String: Any] {
            messageId = message["id"] as? String
        }
        return .empty
    }

    private func handleContentBlockStart(_ json: [String: Any]) -> AnthropicStreamResult {
        guard let index = json["index"] as? Int,
              let contentBlock = json["content_block"] as? [String: Any],
              let typeStr = contentBlock["type"] as? String
        else {
            return .empty
        }

        let blockType = AnthropicContentBlockType(rawValue: typeStr) ?? .text

        var state = AnthropicBlockState(type: blockType)

        if blockType == .toolUse {
            state.toolName = contentBlock["name"] as? String
            state.toolId = contentBlock["id"] as? String
        }

        activeBlocks[index] = state

        return .empty
    }

    private func handleContentBlockDelta(_ json: [String: Any]) -> AnthropicStreamResult {
        guard let index = json["index"] as? Int,
              let delta = json["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String
        else {
            return .empty
        }

        var content: String?
        var reasoning: String?

        switch deltaType {
        case "text_delta":
            if let text = delta["text"] as? String {
                content = text
                onChunk?(text)
            }

        case "thinking_delta":
            if let thinking = delta["thinking"] as? String {
                reasoning = thinking
                onReasoning?(thinking)
            }

        case "input_json_delta":
            if let partialJson = delta["partial_json"] as? String,
               let partialData = partialJson.data(using: .utf8)
            {
                if (activeBlocks[index]?.buffer.count ?? 0) + partialData.count <= AnthropicStreamParserLimits.maxToolInputSize {
                    activeBlocks[index]?.buffer.append(partialData)
                }
            }

        case "signature_delta":
            if let signature = delta["signature"] as? String,
               let sigData = signature.data(using: .utf8)
            {
                if (activeBlocks[index]?.buffer.count ?? 0) + sigData.count <= AnthropicStreamParserLimits.maxSignatureSize {
                    activeBlocks[index]?.buffer.append(sigData)
                }
            }

        default:
            break
        }

        return AnthropicStreamResult(
            shouldComplete: false,
            content: content,
            reasoning: reasoning,
            toolCall: nil,
            error: nil
        )
    }

    private func handleContentBlockStop(_ json: [String: Any]) -> AnthropicStreamResult {
        guard let index = json["index"] as? Int,
              let state = activeBlocks[index]
        else {
            return .empty
        }

        var toolCall: AnthropicToolCall?

        if state.type == .toolUse,
           let toolId = state.toolId,
           let toolName = state.toolName
        {
            if state.buffer.isEmpty {
                toolCall = AnthropicToolCall(id: toolId, name: toolName, input: [:])
            } else if let inputJson = try? JSONSerialization.jsonObject(with: state.buffer) as? [String: Any] {
                let codableInput = inputJson.mapValues { AnyCodable($0) }
                toolCall = AnthropicToolCall(id: toolId, name: toolName, input: codableInput)
            } else {
                let bufferPreview = String(data: state.buffer.prefix(200), encoding: .utf8) ?? ""
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "Failed to parse tool input JSON",
                    metadata: ["toolName": toolName, "bufferPreview": bufferPreview]
                )
                toolCall = AnthropicToolCall(
                    id: toolId,
                    name: toolName,
                    input: ["_error": AnyCodable("Failed to parse tool input")]
                )
            }

            if let call = toolCall {
                onToolCallRequested?(call.id, call.name, call.input)
            }
        }

        activeBlocks.removeValue(forKey: index)

        return AnthropicStreamResult(
            shouldComplete: false,
            content: nil,
            reasoning: nil,
            toolCall: toolCall,
            error: nil
        )
    }

    private func handleMessageDelta(_ json: [String: Any]) -> AnthropicStreamResult {
        if let delta = json["delta"] as? [String: Any] {
            stopReason = delta["stop_reason"] as? String
        }
        return .empty
    }

    private func handleError(_ json: [String: Any]) -> AnthropicStreamResult {
        var message = "Anthropic API error"

        if let errorObj = json["error"] as? [String: Any] {
            if let errorMessage = errorObj["message"] as? String {
                message = errorMessage
            }
        }

        let error = AynaError.apiError(message: message)
        onError?(error)

        return AnthropicStreamResult(
            shouldComplete: false,
            content: nil,
            reasoning: nil,
            toolCall: nil,
            error: error
        )
    }
}

extension AnthropicStreamParser {
    static func processLine(_ line: String, parser: AnthropicStreamParser) -> AnthropicStreamResult {
        parser.processLine(line)
    }
}
