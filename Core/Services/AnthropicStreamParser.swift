//
//  AnthropicStreamParser.swift
//  ayna
//
//  Created on 1/30/26.
//

import Foundation
import os

/// Result from parsing Anthropic SSE events
struct AnthropicStreamResult: @unchecked Sendable {
    let shouldComplete: Bool
    let content: String?
    let reasoning: String?
    let toolCall: AnthropicToolCall?
    let error: Error?

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
struct AnthropicToolCall: @unchecked Sendable {
    let id: String
    let name: String
    let input: [String: Any]
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
        buffer = Data()
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
final class AnthropicStreamParser: @unchecked Sendable {
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
    typealias ToolCallCallback = @Sendable (String, String, [String: Any]) -> Void
    typealias CompleteCallback = @Sendable () -> Void
    typealias ErrorCallback = @Sendable (Error) -> Void

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

            let result = processDataLine(dataString, eventType: pendingEventType)
            pendingEventType = nil
            return result
        }

        return .empty
    }

    /// Reset the parser state for a new stream.
    func reset() {
        pendingEventType = nil
        activeBlocks.removeAll()
        stopReason = nil
        messageId = nil
    }

    // MARK: - Private Methods

    private func processDataLine(_ dataString: String, eventType: String?) -> AnthropicStreamResult {
        guard let data = dataString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            DiagnosticsLogger.logThrottled(
                .anthropicService,
                level: .debug,
                throttleKey: "anthropic.parser.unparseable",
                interval: 2.0,
                message: "Could not parse data line",
                metadata: ["preview": String(dataString.prefix(100))]
            )
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
            DiagnosticsLogger.logThrottled(
                .anthropicService,
                level: .debug,
                throttleKey: "anthropic.parser.unknownType",
                interval: 5.0,
                message: "Unknown event type",
                metadata: ["type": type]
            )
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
                activeBlocks[index]?.buffer.append(partialData)
            }

        case "signature_delta":
            // Accumulate signature for redacted thinking
            if let signature = delta["signature"] as? String,
               let sigData = signature.data(using: .utf8)
            {
                activeBlocks[index]?.buffer.append(sigData)
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
                toolCall = AnthropicToolCall(id: toolId, name: toolName, input: inputJson)
            } else {
                // JSON parse failure
                let bufferPreview = String(data: state.buffer.prefix(200), encoding: .utf8) ?? ""
                DiagnosticsLogger.log(
                    .anthropicService,
                    level: .error,
                    message: "Failed to parse tool input JSON",
                    metadata: ["toolName": toolName, "bufferPreview": bufferPreview]
                )
                // Create synthetic error result
                toolCall = AnthropicToolCall(
                    id: toolId,
                    name: toolName,
                    input: ["_error": "Failed to parse tool input"]
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
