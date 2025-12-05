import Foundation
import os

/// Result from parsing a single SSE stream line
///
/// Marked as `@unchecked Sendable` because the `toolCallBuffer` dictionary
/// contains JSON-like data that is only accessed sequentially within the
/// streaming pipeline. The dictionary is never mutated concurrently.
struct StreamLineResult: @unchecked Sendable {
    let shouldComplete: Bool
    let toolCallBuffer: [String: Any]
    let toolCallId: String
    let content: String?
    let reasoning: String?

    /// Empty result indicating no meaningful data was parsed
    static var empty: StreamLineResult {
        StreamLineResult(
            shouldComplete: false,
            toolCallBuffer: [:],
            toolCallId: "",
            content: nil,
            reasoning: nil
        )
    }
}

/// Result from tool call completion handling
///
/// Marked as `@unchecked Sendable` because the `buffer` dictionary
/// contains JSON-like data that is only accessed sequentially within the
/// streaming pipeline.
struct ToolCallCompletionResult: @unchecked Sendable {
    let buffer: [String: Any]
    let id: String
    let content: String?
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
    ///   - toolCallBuffer: Current accumulated tool call data
    ///   - toolCallId: Current tool call ID being processed
    ///   - onToolCall: Legacy callback for inline tool execution
    ///   - onToolCallRequested: Callback when a tool call is requested
    ///   - onReasoning: Callback for reasoning content (reserved for future use)
    /// - Returns: A `StreamLineResult` with parsed data and updated state
    static func processStreamLine(
        _ line: String,
        toolCallBuffer: [String: Any],
        toolCallId: String,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
        onReasoning _: (@Sendable (String) -> Void)? = nil
    ) async -> StreamLineResult {
        var updatedToolCallBuffer = toolCallBuffer
        var updatedToolCallId = toolCallId
        var extractedContent: String?
        var extractedReasoning: String?
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Log all non-empty lines to track what we receive
        if !trimmedLine.isEmpty {
            DiagnosticsLogger.log(
                .openAIService,
                level: .debug,
                message: "📍 Parser: Processing line",
                metadata: ["lineLength": String(trimmedLine.count), "hasDataPrefix": String(trimmedLine.hasPrefix("data: "))]
            )
        }

        guard trimmedLine.hasPrefix("data: ") else {
            return StreamLineResult(
                shouldComplete: false,
                toolCallBuffer: updatedToolCallBuffer,
                toolCallId: updatedToolCallId,
                content: nil,
                reasoning: nil
            )
        }

        let jsonString = String(trimmedLine.dropFirst(6))

        // Check for stream completion marker
        if jsonString == "[DONE]" {
            DiagnosticsLogger.log(
                .openAIService,
                level: .debug,
                message: "📍 Parser: [DONE] marker received"
            )
            return StreamLineResult(
                shouldComplete: true,
                toolCallBuffer: updatedToolCallBuffer,
                toolCallId: updatedToolCallId,
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
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .debug,
                    message: "📍 Parser: Could not parse line",
                    metadata: ["linePreview": String(jsonString.prefix(100))]
                )
            }
            return StreamLineResult(
                shouldComplete: false,
                toolCallBuffer: updatedToolCallBuffer,
                toolCallId: updatedToolCallId,
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
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .debug,
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
        (updatedToolCallBuffer, updatedToolCallId) = processToolCallDelta(
            delta: delta,
            currentBuffer: updatedToolCallBuffer,
            currentId: updatedToolCallId
        )

        // Check if tool call is complete and execute
        let toolResult = await handleToolCallCompletion(
            firstChoice: firstChoice,
            toolCallBuffer: updatedToolCallBuffer,
            toolCallId: updatedToolCallId,
            extractedContent: extractedContent,
            onToolCall: onToolCall,
            onToolCallRequested: onToolCallRequested
        )
        updatedToolCallBuffer = toolResult.buffer
        updatedToolCallId = toolResult.id
        extractedContent = toolResult.content

        return StreamLineResult(
            shouldComplete: false,
            toolCallBuffer: updatedToolCallBuffer,
            toolCallId: updatedToolCallId,
            content: extractedContent,
            reasoning: extractedReasoning
        )
    }

    // MARK: - Tool Call Helpers

    /// Process tool call delta from stream chunk
    private static func processToolCallDelta(
        delta: [String: Any],
        currentBuffer: [String: Any],
        currentId: String
    ) -> (buffer: [String: Any], id: String) {
        var buffer = currentBuffer
        var id = currentId

        guard let toolCalls = delta["tool_calls"] as? [[String: Any]],
              let toolCall = toolCalls.first
        else {
            return (buffer, id)
        }

        if let newId = toolCall["id"] as? String {
            id = newId
        }
        if let function = toolCall["function"] as? [String: Any] {
            if let name = function["name"] as? String {
                buffer["name"] = name
            }
            if let argsChunk = function["arguments"] as? String {
                let currentArgs = buffer["arguments"] as? String ?? ""
                buffer["arguments"] = currentArgs + argsChunk
            }
        }
        return (buffer, id)
    }

    /// Handle tool call completion and execution
    private static func handleToolCallCompletion(
        firstChoice: [String: Any],
        toolCallBuffer: [String: Any],
        toolCallId: String,
        extractedContent: String?,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    ) async -> ToolCallCompletionResult {
        guard let finishReason = firstChoice["finish_reason"] as? String,
              finishReason == "tool_calls",
              let toolName = toolCallBuffer["name"] as? String,
              let argsString = toolCallBuffer["arguments"] as? String,
              let argsData = argsString.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        else {
            return ToolCallCompletionResult(buffer: toolCallBuffer, id: toolCallId, content: extractedContent)
        }

        var content = extractedContent

        // Notify about tool call request (for proper flow)
        if let onToolCallRequested {
            await MainActor.run {
                onToolCallRequested(toolCallId, toolName, arguments)
            }
        }
        // Legacy support: still execute inline if old callback provided
        else if let onToolCall {
            let result = await onToolCall(toolCallId, toolName, arguments)
            let toolOutput = "\n\n[Tool: \(toolName)]\n\(result)\n"
            content = (content ?? "") + toolOutput
        }

        // Clear buffer for next tool call
        return ToolCallCompletionResult(buffer: [:], id: "", content: content)
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
            Task { @MainActor in
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .debug,
                    message: "🧩 Received structured content array",
                    metadata: meta
                )
            }

            var segments: [String] = []
            for (index, part) in contentArray.enumerated() {
                guard let type = part["type"] as? String else {
                    let meta = mergedMetadata(metadata, additions: ["source": source, "index": "\(index)"])
                    Task { @MainActor in
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .debug,
                            message: "⚠️ Structured content part missing type",
                            metadata: meta
                        )
                    }
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
                Task { @MainActor in
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .debug,
                        message: "⚠️ Structured content part missing text",
                        metadata: meta
                    )
                }
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
            Task { @MainActor in
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .debug,
                    message: "⚠️ Unsupported content payload",
                    metadata: meta
                )
            }
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
