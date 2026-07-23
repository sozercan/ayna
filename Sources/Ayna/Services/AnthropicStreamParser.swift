//
//  AnthropicStreamParser.swift
//  ayna
//
//  Created on 1/30/26.
//

import Foundation
import os

private enum AnthropicStreamParserLimits {
    static let initialBlockBufferCapacity = 1024
    static let maxToolInputSize = 10_485_760 // 10MB
    static let maxSignatureSize = 65_536 // 64KB
}

/// Result from parsing Anthropic SSE events
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

/// Represents a parsed tool call from the stream
struct AnthropicToolCall: Sendable {
    let id: String
    let name: String
    let input: [String: AnyCodable]
}

/// Content block types in Anthropic responses
enum AnthropicContentBlockType: String {
    case text
    case thinking
    case redactedThinking = "redacted_thinking"
    case toolUse = "tool_use"
}

/// State for tracking a content block during streaming
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

/// Parser for Anthropic SSE (Server-Sent Events) streaming responses.
///
/// Handles Anthropic's two-line SSE format:
/// ```
/// event: message_start
/// data: {"type": "message_start", ...}
/// ```
///
/// Supports:
/// - Text content streaming
/// - Extended thinking blocks
/// - Interleaved thinking (multiple thinking blocks)
/// - Tool use with JSON fragment accumulation
/// - Error events
///
/// Note: This parser maintains mutable state and should only be used from a single
/// task context. `AnthropicProvider` drives it from a single streaming task, ensuring
/// sequential access to the parser's state.
final class AnthropicStreamParser {
    // MARK: - State

    /// Pending event type from the previous line
    private var pendingEventType: String?

    /// Active content blocks being accumulated
    private var activeBlocks: [Int: AnthropicBlockState] = [:]

    /// Stop reason from message_delta
    private(set) var stopReason: String?

    /// Message ID from message_start
    private(set) var messageId: String?

    // MARK: - Callbacks

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

    // MARK: - Initialization

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

    // MARK: - Public API

    /// Process a single line from the SSE stream.
    ///
    /// - Parameter line: The raw line from the stream
    /// - Returns: Result indicating whether to complete and any extracted data
    func processLine(_ line: String) -> AnthropicStreamResult {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty lines
        guard !trimmedLine.isEmpty else {
            return .empty
        }

        // Handle event: lines
        if trimmedLine.hasPrefix("event: ") {
            pendingEventType = String(trimmedLine.dropFirst(7))
            return .empty
        }

        // Handle data: lines
        if trimmedLine.hasPrefix("data: ") {
            let dataString = String(trimmedLine.dropFirst(6))

            // Skip empty data
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

    /// Process a single UTF-8 SSE line without converting the full line to `String`.
    ///
    /// Byte-oriented stream readers can use this to avoid `Data -> String -> Data`
    /// round trips for each Anthropic content delta.
    func processLine(_ lineData: Data) -> AnthropicStreamResult {
        guard let trimmedRange = Self.asciiTrimmedRange(in: lineData) else {
            return .empty
        }

        // Handle event: lines. Only the event name becomes a String because it is
        // carried as parser state for the following data line.
        if Self.hasPrefix(Self.eventLinePrefix, in: lineData, range: trimmedRange) {
            let eventStart = trimmedRange.lowerBound + Self.eventLinePrefix.count
            pendingEventType = String(data: lineData[eventStart ..< trimmedRange.upperBound], encoding: .utf8)
            return .empty
        }

        // Handle data: lines by passing the JSON payload bytes straight to JSONSerialization.
        if Self.hasPrefix(Self.dataLinePrefix, in: lineData, range: trimmedRange) {
            let dataStart = trimmedRange.lowerBound + Self.dataLinePrefix.count
            let data = lineData[dataStart ..< trimmedRange.upperBound]
            let result = processDataLine(data, eventType: pendingEventType)
            pendingEventType = nil
            return result
        }

        return .empty
    }

    private static let eventLinePrefix: [UInt8] = Array("event: ".utf8)
    private static let dataLinePrefix: [UInt8] = Array("data: ".utf8)

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

    /// Reset the parser state for a new stream.
    func reset() {
        pendingEventType = nil
        activeBlocks.removeAll()
        stopReason = nil
        messageId = nil
    }

    // MARK: - Private Methods

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
            // Keep-alive, ignore
            return .empty

        case "error":
            return handleError(json)

        default:
            return .empty
        }
    }

    // MARK: - Event Handlers

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

        // For tool_use, capture the tool name and ID
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
            // Accumulate tool input JSON
            if let partialJson = delta["partial_json"] as? String,
               let partialData = partialJson.data(using: .utf8)
            {
                if (activeBlocks[index]?.buffer.count ?? 0) + partialData.count <= AnthropicStreamParserLimits.maxToolInputSize {
                    activeBlocks[index]?.buffer.append(partialData)
                }
            }

        case "signature_delta":
            // Accumulate signature for redacted thinking
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

        // If this was a tool_use block, parse the accumulated JSON
        if state.type == .toolUse,
           let toolId = state.toolId,
           let toolName = state.toolName
        {
            if state.buffer.isEmpty {
                // Empty input, use empty object
                toolCall = AnthropicToolCall(id: toolId, name: toolName, input: [:])
            } else if let inputJson = try? JSONSerialization.jsonObject(with: state.buffer) as? [String: Any] {
                // Convert [String: Any] to [String: AnyCodable] for Sendable safety
                let codableInput = inputJson.mapValues { AnyCodable($0) }
                toolCall = AnthropicToolCall(id: toolId, name: toolName, input: codableInput)
            } else {
                // JSON parse failure
                let bufferPreview = String(data: state.buffer.prefix(200), encoding: .utf8) ?? ""
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "Failed to parse tool input JSON",
                    metadata: ["toolName": toolName, "bufferPreview": bufferPreview]
                )
                // Create synthetic error result
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

        // Clean up the block state
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

// MARK: - Convenience Static Methods

extension AnthropicStreamParser {
    /// Process a single line without callbacks, returning the result.
    ///
    /// - Parameters:
    ///   - line: The raw line from the stream
    ///   - parser: An existing parser instance (for state tracking)
    /// - Returns: The parse result
    static func processLine(_ line: String, parser: AnthropicStreamParser) -> AnthropicStreamResult {
        parser.processLine(line)
    }

    /// Create a new parser with the standard callbacks.
    static func createParser(
        onChunk: @escaping ChunkCallback,
        onComplete: @escaping CompleteCallback,
        onError: @escaping ErrorCallback,
        onToolCallRequested: ToolCallCallback? = nil,
        onReasoning: ReasoningCallback? = nil
    ) -> AnthropicStreamParser {
        AnthropicStreamParser(
            onChunk: onChunk,
            onReasoning: onReasoning,
            onToolCallRequested: onToolCallRequested,
            onComplete: onComplete,
            onError: onError
        )
    }
}
