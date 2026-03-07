import Foundation
import os

/// Result from parsing a single SSE stream line
///
/// Marked as `@unchecked Sendable` because the `toolCallBuffers` dictionary
/// contains JSON-like data that is only accessed sequentially within the
/// streaming pipeline. The dictionary is never mutated concurrently.
struct StreamLineResult: @unchecked Sendable {
    let shouldComplete: Bool
    let toolCallBuffers: [Int: [String: Any]]
    let toolCallIds: [Int: String]
    let content: String?
    let reasoning: String?

    /// Empty result indicating no meaningful data was parsed
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

/// Result from tool call completion handling
///
/// Marked as `@unchecked Sendable` because the `buffers` dictionary
/// contains JSON-like data that is only accessed sequentially within the
/// streaming pipeline.
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
    static let legacyArguments = "arguments"
}

/// Callbacks for streaming response events
struct StreamCallbacks {
    let onChunk: @Sendable (String) -> Void
    let onComplete: @Sendable () -> Void
    let onError: @Sendable (Error) -> Void
    let onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?
    let onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    let onReasoning: (@Sendable (String) -> Void)?
}

/// Stateless parser for OpenAI SSE (Server-Sent Events) streaming responses.
///
/// Handles parsing of:
/// - Regular content chunks
/// - Reasoning content (for o1/o3 models)
/// - Tool calls with argument accumulation
/// - Structured content arrays
enum OpenAIStreamParser {
    // MARK: - Public API

    /// Process a single SSE line from the stream.
    ///
    /// - Parameters:
    ///   - line: The raw SSE line (e.g., "data: {...}")
    ///   - toolCallBuffers: Current accumulated tool call data keyed by tool call index
    ///   - toolCallIds: Current tool call IDs keyed by tool call index
    ///   - onToolCall: Legacy callback for inline tool execution
    ///   - onToolCallRequested: Callback when a tool call is requested
    ///   - onReasoning: Callback for reasoning content (reserved for future use)
    /// - Returns: A `StreamLineResult` with parsed data and updated state
    static func processStreamLine(
        _ line: String,
        toolCallBuffers: [Int: [String: Any]],
        toolCallIds: [Int: String],
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
        onReasoning _: (@Sendable (String) -> Void)? = nil
    ) async -> StreamLineResult {
        var updatedToolCallBuffers = toolCallBuffers
        var updatedToolCallIds = toolCallIds
        var extractedContent: String?
        var extractedReasoning: String?
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Log all non-empty lines to track what we receive
        if !trimmedLine.isEmpty {
            DiagnosticsLogger.logThrottled(
                .aiService,
                level: .debug,
                throttleKey: "stream.parser.processingLine",
                interval: 2.0,
                message: "📍 Parser: Processing line",
                metadata: [
                    "lineLength": String(trimmedLine.count),
                    "hasDataPrefix": String(trimmedLine.hasPrefix("data: "))
                ]
            )
        }

        guard trimmedLine.hasPrefix("data: ") else {
            return StreamLineResult(
                shouldComplete: false,
                toolCallBuffers: updatedToolCallBuffers,
                toolCallIds: updatedToolCallIds,
                content: nil,
                reasoning: nil
            )
        }

        let jsonString = String(trimmedLine.dropFirst(6))

        // Check for stream completion marker
        if jsonString == "[DONE]" {
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

        // Parse JSON payload
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any]
        else {
            // Log unparseable lines for debugging
            if !jsonString.isEmpty, jsonString != "[DONE]" {
                DiagnosticsLogger.logThrottled(
                    .aiService,
                    level: .debug,
                    throttleKey: "stream.parser.unparseable",
                    interval: 2.0,
                    message: "📍 Parser: Could not parse line",
                    metadata: ["linePreview": String(jsonString.prefix(100))]
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

        // Handle regular content
        if let contentField = delta["content"], !(contentField is NSNull) {
            let textSegments = extractTextSegments(
                from: contentField,
                source: "stream.chat",
                metadata: ["phase": "delta"]
            )

            if !textSegments.isEmpty {
                extractedContent = textSegments.joined()
                DiagnosticsLogger.logThrottled(
                    .aiService,
                    level: .debug,
                    throttleKey: "stream.parser.extractedContent",
                    interval: 1.0,
                    message: "📍 Parser: Extracted content chunk",
                    metadata: ["chunkLength": String(extractedContent?.count ?? 0)]
                )
            }
        }

        // Handle reasoning content (for o1/o3 models)
        let reasoningContent =
            delta["reasoning_content"] as? String
                ?? delta["reasoning"] as? String
                ?? delta["thought"] as? String

        if let reasoning = reasoningContent {
            extractedReasoning = reasoning
        }

        // Handle tool calls
        (updatedToolCallBuffers, updatedToolCallIds) = processToolCallDelta(
            delta: delta,
            currentBuffers: updatedToolCallBuffers,
            currentIds: updatedToolCallIds
        )

        // Check if tool call is complete and execute
        let toolResult = await handleToolCallCompletion(
            firstChoice: firstChoice,
            toolCallBuffers: updatedToolCallBuffers,
            toolCallIds: updatedToolCallIds,
            extractedContent: extractedContent,
            onToolCall: onToolCall,
            onToolCallRequested: onToolCallRequested
        )
        updatedToolCallBuffers = toolResult.buffers
        updatedToolCallIds = toolResult.ids
        extractedContent = toolResult.content

        return StreamLineResult(
            shouldComplete: false,
            toolCallBuffers: updatedToolCallBuffers,
            toolCallIds: updatedToolCallIds,
            content: extractedContent,
            reasoning: extractedReasoning
        )
    }

    // MARK: - Tool Call Helpers

    /// Process tool call delta from stream chunk
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
                if let name = function["name"] as? String {
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

    /// Handle tool call completion and execution
    private static func handleToolCallCompletion(
        firstChoice: [String: Any],
        toolCallBuffers: [Int: [String: Any]],
        toolCallIds: [Int: String],
        extractedContent: String?,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    ) async -> ToolCallCompletionResult {
        guard let finishReason = firstChoice["finish_reason"] as? String,
              finishReason == "tool_calls"
        else {
            return ToolCallCompletionResult(buffers: toolCallBuffers, ids: toolCallIds, content: extractedContent)
        }

        var remainingBuffers = toolCallBuffers
        var remainingIds = toolCallIds
        var content = extractedContent

        for index in toolCallBuffers.keys.sorted() {
            guard let toolCallBuffer = toolCallBuffers[index],
                  let toolName = toolCallBuffer[ToolCallBufferKey.name] as? String,
                  let argsData = toolArgumentsData(from: toolCallBuffer),
                  let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
            else {
                continue
            }

            let toolCallId = toolCallIds[index] ?? ""

            // Notify about tool call request (for proper flow)
            if let onToolCallRequested {
                let sendableArguments = SendableToolArguments(value: arguments)
                await MainActor.run {
                    onToolCallRequested(toolCallId, toolName, sendableArguments.value)
                }
            }
            // Legacy support: still execute inline if old callback provided
            else if let onToolCall {
                let result = await onToolCall(toolCallId, toolName, arguments)
                let toolOutput = "\n\n[Tool: \(toolName)]\n\(result)\n"
                content = (content ?? "") + toolOutput
            }

            remainingBuffers.removeValue(forKey: index)
            remainingIds.removeValue(forKey: index)
        }

        return ToolCallCompletionResult(buffers: remainingBuffers, ids: remainingIds, content: content)
    }

    private static func toolArgumentsData(from toolCallBuffer: [String: Any]) -> Data? {
        if let argumentsData = toolCallBuffer[ToolCallBufferKey.argumentsData] as? Data {
            return argumentsData
        }

        if let arguments = toolCallBuffer[ToolCallBufferKey.legacyArguments] as? String {
            return Data(arguments.utf8)
        }

        return nil
    }

    // MARK: - Text Extraction

    /// Recursively extract text segments from structured content.
    ///
    /// Handles:
    /// - Plain strings
    /// - Arrays of content blocks with "type" and "text" fields
    /// - Nested content structures
    ///
    /// - Parameters:
    ///   - contentField: The content field from the API response
    ///   - source: Identifier for logging purposes
    ///   - metadata: Additional metadata for logging
    /// - Returns: Array of extracted text strings
    static func extractTextSegments(
        from contentField: Any,
        source: String,
        metadata: [String: String] = [:]
    ) -> [String] {
        // Simple string content
        if let stringContent = contentField as? String {
            return [stringContent]
        }

        // Array of content blocks
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

                // Direct text field
                if let text = part["text"] as? String, !text.isEmpty {
                    segments.append(text)
                    continue
                }

                // Nested content
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

        // Single content block (wrap in array and recurse)
        if let singlePart = contentField as? [String: Any] {
            return extractTextSegments(from: [singlePart], source: source, metadata: metadata)
        }

        // Unsupported type (log warning)
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

    // MARK: - Metadata Helpers

    /// Merge metadata dictionaries.
    ///
    /// - Parameters:
    ///   - metadata: Base metadata dictionary
    ///   - additions: Additional key-value pairs to add
    /// - Returns: Combined metadata dictionary
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
