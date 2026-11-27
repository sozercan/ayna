import Foundation
import os

struct StreamLineResult: @unchecked Sendable {
    let shouldComplete: Bool
    let toolCallBuffers: [Int: [String: Any]]
    let toolCallIds: [Int: String]
    let content: String?
    let reasoning: String?

    static var empty: StreamLineResult {
        StreamLineResult(
            shouldComplete: false,
            toolCallBuffers: [:],
            toolCallIds: [:],
            content: nil,
            reasoning: nil
        )
    }
}

struct ToolCallCompletionResult: @unchecked Sendable {
    let buffers: [Int: [String: Any]]
    let ids: [Int: String]
    let content: String?
}

private struct SendableToolArguments: @unchecked Sendable {
    let value: [String: Any]
}

private enum ToolCallBufferKey {
    static let name = "name"
    static let argumentsData = "argumentsData"
}

struct StreamCallbacks {
    let onChunk: @Sendable (String) -> Void
    let onComplete: @Sendable () -> Void
    let onError: @Sendable (Error) -> Void
    let onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    let onReasoning: (@Sendable (String) -> Void)?
}

enum OpenAIStreamParser {
    static func processStreamLine(
        _ line: String,
        toolCallBuffers: [Int: [String: Any]],
        toolCallIds: [Int: String],
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
        onReasoning _: (@Sendable (String) -> Void)? = nil
    ) async -> StreamLineResult {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedLine.hasPrefix("data:") else {
            return StreamLineResult(
                shouldComplete: false,
                toolCallBuffers: toolCallBuffers,
                toolCallIds: toolCallIds,
                content: nil,
                reasoning: nil
            )
        }

        var payload = trimmedLine.dropFirst(5)
        if payload.first == " " {
            payload = payload.dropFirst()
        }
        return await processDataLine(
            Data(payload.utf8),
            toolCallBuffers: toolCallBuffers,
            toolCallIds: toolCallIds,
            onToolCallRequested: onToolCallRequested
        )
    }

    static func processStreamLine(
        _ lineData: Data,
        toolCallBuffers: [Int: [String: Any]],
        toolCallIds: [Int: String],
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
        onReasoning _: (@Sendable (String) -> Void)? = nil
    ) async -> StreamLineResult {
        guard let jsonData = dataPayload(in: lineData) else {
            return StreamLineResult(
                shouldComplete: false,
                toolCallBuffers: toolCallBuffers,
                toolCallIds: toolCallIds,
                content: nil,
                reasoning: nil
            )
        }

        return await processDataLine(
            jsonData,
            toolCallBuffers: toolCallBuffers,
            toolCallIds: toolCallIds,
            onToolCallRequested: onToolCallRequested
        )
    }

    private static func processDataLine(
        _ jsonData: Data,
        toolCallBuffers: [Int: [String: Any]],
        toolCallIds: [Int: String],
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    ) async -> StreamLineResult {
        var updatedToolCallBuffers = toolCallBuffers
        var updatedToolCallIds = toolCallIds
        var extractedContent: String?
        var extractedReasoning: String?

        if jsonData == doneMarkerData {
            DiagnosticsLogger.log(
                .aiService,
                level: .debug,
                message: "📍 Parser: [DONE] marker received"
            )
            return StreamLineResult(
                shouldComplete: true,
                toolCallBuffers: updatedToolCallBuffers,
                toolCallIds: updatedToolCallIds,
                content: nil,
                reasoning: nil
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any]
        else {
            if !jsonData.isEmpty {
                let linePreview = String(data: jsonData.prefix(100), encoding: .utf8) ?? ""
                DiagnosticsLogger.logThrottled(
                    .aiService,
                    level: .debug,
                    throttleKey: "stream.parser.unparseable",
                    interval: 2.0,
                    message: "📍 Parser: Could not parse line",
                    metadata: ["linePreview": linePreview]
                )
            }
            return StreamLineResult(
                shouldComplete: false,
                toolCallBuffers: updatedToolCallBuffers,
                toolCallIds: updatedToolCallIds,
                content: nil,
                reasoning: nil
            )
        }

        if let stringContent = delta["content"] as? String {
            extractedContent = stringContent
        } else if let contentField = delta["content"], !(contentField is NSNull) {
            let textSegments = extractTextSegments(
                from: contentField,
                source: "stream.chat",
                metadata: ["phase": "delta"]
            )

            if !textSegments.isEmpty {
                extractedContent = textSegments.joined()
            }
        }

        let reasoningContent =
            delta["reasoning_content"] as? String
                ?? delta["reasoning"] as? String
                ?? delta["thought"] as? String

        if let reasoning = reasoningContent {
            extractedReasoning = reasoning
        }

        (updatedToolCallBuffers, updatedToolCallIds) = processToolCallDelta(
            delta: delta,
            currentBuffers: updatedToolCallBuffers,
            currentIds: updatedToolCallIds
        )

        if firstChoice["finish_reason"] as? String == "tool_calls" {
            let toolResult = await handleToolCallCompletion(
                firstChoice: firstChoice,
                toolCallBuffers: updatedToolCallBuffers,
                toolCallIds: updatedToolCallIds,
                extractedContent: extractedContent,
                onToolCallRequested: onToolCallRequested
            )
            updatedToolCallBuffers = toolResult.buffers
            updatedToolCallIds = toolResult.ids
            extractedContent = toolResult.content
        }

        return StreamLineResult(
            shouldComplete: false,
            toolCallBuffers: updatedToolCallBuffers,
            toolCallIds: updatedToolCallIds,
            content: extractedContent,
            reasoning: extractedReasoning
        )
    }

    private static let dataLinePrefix: [UInt8] = Array("data:".utf8)
    private static let doneMarkerData = Data("[DONE]".utf8)

    private static func dataPayload(in lineData: Data) -> Data? {
        guard let trimmedRange = asciiTrimmedRange(in: lineData),
              hasPrefix(dataLinePrefix, in: lineData, range: trimmedRange)
        else {
            return nil
        }

        var payloadStart = trimmedRange.lowerBound + dataLinePrefix.count
        if payloadStart < trimmedRange.upperBound, lineData[payloadStart] == 0x20 {
            payloadStart += 1
        }
        return lineData[payloadStart ..< trimmedRange.upperBound]
    }

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

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
            true
        default:
            false
        }
    }

    private static func processToolCallDelta(
        delta: [String: Any],
        currentBuffers: [Int: [String: Any]],
        currentIds: [Int: String]
    ) -> (buffers: [Int: [String: Any]], ids: [Int: String]) {
        var buffers = currentBuffers
        var ids = currentIds

        guard let toolCalls = delta["tool_calls"] as? [[String: Any]] else {
            return (buffers, ids)
        }

        for toolCall in toolCalls {
            let index = toolCall["index"] as? Int ?? 0
            var buffer = buffers[index] ?? [:]

            if let newId = toolCall["id"] as? String {
                ids[index] = newId
            }
            if let function = toolCall["function"] as? [String: Any] {
                if let name = function["name"] as? String,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    buffer[ToolCallBufferKey.name] = name
                }
                if let argsChunk = function["arguments"] as? String {
                    var argumentsData = buffer[ToolCallBufferKey.argumentsData] as? Data
                        ?? Data(capacity: max(256, argsChunk.utf8.count))
                    argumentsData.reserveCapacity(argumentsData.count + argsChunk.utf8.count)
                    argumentsData.append(contentsOf: argsChunk.utf8)
                    buffer[ToolCallBufferKey.argumentsData] = argumentsData
                }
            }

            buffers[index] = buffer
        }

        return (buffers, ids)
    }

    private static func handleToolCallCompletion(
        firstChoice: [String: Any],
        toolCallBuffers: [Int: [String: Any]],
        toolCallIds: [Int: String],
        extractedContent: String?,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    ) async -> ToolCallCompletionResult {
        guard let finishReason = firstChoice["finish_reason"] as? String,
              finishReason == "tool_calls"
        else {
            return ToolCallCompletionResult(buffers: toolCallBuffers, ids: toolCallIds, content: extractedContent)
        }

        var remainingBuffers = toolCallBuffers
        var remainingIds = toolCallIds
        let content = extractedContent

        for index in toolCallBuffers.keys.sorted() {
            guard let toolCallBuffer = toolCallBuffers[index],
                  let toolName = toolCallBuffer[ToolCallBufferKey.name] as? String,
                  !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let argsData = toolArgumentsData(from: toolCallBuffer),
                  let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
            else {
                continue
            }

            let toolCallId = toolCallIds[index] ?? ""

            if let onToolCallRequested {
                let sendableArguments = SendableToolArguments(value: arguments)
                await MainActor.run {
                    onToolCallRequested(toolCallId, toolName, sendableArguments.value)
                }
            }

            remainingBuffers.removeValue(forKey: index)
            remainingIds.removeValue(forKey: index)
        }

        return ToolCallCompletionResult(buffers: remainingBuffers, ids: remainingIds, content: content)
    }

    private static func toolArgumentsData(from toolCallBuffer: [String: Any]) -> Data? {
        toolCallBuffer[ToolCallBufferKey.argumentsData] as? Data
    }

    static func extractTextSegments(
        from contentField: Any,
        source: String,
        metadata: [String: String] = [:]
    ) -> [String] {
        if let stringContent = contentField as? String {
            return [stringContent]
        }

        if let contentArray = contentField as? [[String: Any]] {
            let meta = mergedMetadata(metadata, additions: ["source": source, "parts": "\(contentArray.count)"])
            DiagnosticsLogger.logThrottled(
                .aiService,
                level: .debug,
                throttleKey: "stream.parser.structuredContentArray",
                interval: 5.0,
                message: "🧩 Received structured content array",
                metadata: meta
            )

            var segments: [String] = []
            for (index, part) in contentArray.enumerated() {
                guard let type = part["type"] as? String else {
                    let meta = mergedMetadata(metadata, additions: ["source": source, "index": "\(index)"])
                    DiagnosticsLogger.logThrottled(
                        .aiService,
                        level: .debug,
                        throttleKey: "stream.parser.structuredMissingType",
                        interval: 5.0,
                        message: "⚠️ Structured content part missing type",
                        metadata: meta
                    )
                    continue
                }

                if let text = part["text"] as? String, !text.isEmpty {
                    segments.append(text)
                    continue
                }

                if let nested = part["content"] {
                    let nestedMetadata = mergedMetadata(
                        metadata,
                        additions: ["source": source, "parentType": type, "parentIndex": "\(index)"]
                    )
                    segments.append(contentsOf: extractTextSegments(from: nested, source: source, metadata: nestedMetadata))
                    continue
                }

                let meta = mergedMetadata(
                    metadata,
                    additions: [
                        "source": source,
                        "type": type,
                        "index": "\(index)"
                    ]
                )
                DiagnosticsLogger.logThrottled(
                    .aiService,
                    level: .debug,
                    throttleKey: "stream.parser.structuredMissingText",
                    interval: 5.0,
                    message: "⚠️ Structured content part missing text",
                    metadata: meta
                )
            }

            return segments
        }

        if let singlePart = contentField as? [String: Any] {
            return extractTextSegments(from: [singlePart], source: source, metadata: metadata)
        }

        if !(contentField is NSNull) {
            let meta = mergedMetadata(
                metadata,
                additions: ["source": source, "payloadType": "\(type(of: contentField))"]
            )
            DiagnosticsLogger.logThrottled(
                .aiService,
                level: .debug,
                throttleKey: "stream.parser.unsupportedContentPayload",
                interval: 5.0,
                message: "⚠️ Unsupported content payload",
                metadata: meta
            )
        }

        return []
    }

    static func mergedMetadata(
        _ metadata: [String: String],
        additions: [String: String]
    ) -> [String: String] {
        var combined = metadata
        for (key, value) in additions {
            combined[key] = value
        }
        return combined
    }
}
