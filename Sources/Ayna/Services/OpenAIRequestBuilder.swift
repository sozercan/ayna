import Foundation
import os

/// Represents a tool call from the model.
/// Note: Uses @unchecked Sendable because arguments are copied on init and
/// the struct is immutable, making it effectively thread-safe.
struct ToolCallInfo: @unchecked Sendable {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// Builder for constructing OpenAI API requests.
///
/// Handles:
/// - Chat Completions API message payloads
/// - Responses API input/output formats
/// - Request header configuration
/// - Authentication (Bearer token, Azure api-key)
@MainActor
enum OpenAIRequestBuilder {
    // MARK: - Chat Completions API

    /// Build a message payload for the Chat Completions API.
    ///
    /// Handles:
    /// - Tool role messages (tool results)
    /// - Assistant messages with tool calls
    /// - Multimodal content (text + images)
    /// - Simple text content
    ///
    /// - Parameter message: The message to convert
    /// - Returns: Dictionary suitable for JSON serialization
    static func buildMessagePayload(from message: Message) -> [String: Any] {
        var payload: [String: Any] = ["role": message.role.rawValue]

        #if !os(watchOS)
            // Handle tool role messages (tool results)
            if message.role == .tool {
                payload["content"] = message.content
                // Tool messages need tool_call_id from the assistant's tool call
                if let toolCalls = message.toolCalls, let firstToolCall = toolCalls.first {
                    payload["tool_call_id"] = firstToolCall.id
                }
                return payload
            }

            // Handle assistant messages with tool calls
            if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                // Assistant message that made tool calls
                if !message.content.isEmpty {
                    payload["content"] = message.content
                } else {
                    payload["content"] = "" // Empty content when only tool calls
                }

                // Add tool_calls array
                let toolCallsArray = toolCalls.compactMap { toolCall -> [String: Any]? in
                    // Convert AnyCodable arguments to JSON string safely
                    var argumentsDict: [String: Any] = [:]
                    for (key, anyCodable) in toolCall.arguments {
                        argumentsDict[key] = anyCodable.value
                    }

                    guard let argumentsJSON = try? JSONSerialization.data(withJSONObject: argumentsDict, options: []),
                          let argumentsString = String(data: argumentsJSON, encoding: .utf8)
                    else {
                        DiagnosticsLogger.log(
                            .aiService,
                            level: .error,
                            message: "Failed to encode arguments for tool call",
                            metadata: ["tool": toolCall.toolName]
                        )
                        return nil
                    }

                    return [
                        "id": toolCall.id,
                        "type": "function",
                        "function": [
                            "name": toolCall.toolName,
                            "arguments": argumentsString
                        ]
                    ]
                }

                if !toolCallsArray.isEmpty {
                    payload["tool_calls"] = toolCallsArray
                }
                return payload
            }
        #endif

        // Check if message has attachments (multimodal content)
        if let attachments = message.attachments, !attachments.isEmpty {
            var contentArray: [[String: Any]] = []

            // Add text content if present
            if !message.content.isEmpty {
                contentArray.append([
                    "type": "text",
                    "text": message.content
                ])
            }

            // Add image attachments
            for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                if let data = attachment.content {
                    let base64Image = data.base64EncodedString()
                    contentArray.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(attachment.mimeType);base64,\(base64Image)"
                        ],
                    ])
                }
            }

            payload["content"] = contentArray
        } else {
            // Simple text content
            payload["content"] = message.content
        }

        return payload
    }

    /// Build a chat completions request body.
    ///
    /// - Parameters:
    ///   - messages: Messages to include
    ///   - model: Model identifier
    ///   - stream: Whether to stream the response
    ///   - tools: Optional tool definitions
    /// - Returns: Dictionary suitable for JSON serialization
    static func buildChatCompletionsBody(
        messages: [Message],
        model: String,
        stream: Bool,
        tools: [[String: Any]]? = nil
    ) -> [String: Any] {
        #if !os(watchOS)
            // Build a set of valid tool_call_ids that have matching tool responses
            // First, collect all tool messages and their tool_call_ids
            var toolResponseIds = Set<String>()
            for message in messages {
                if message.role == .tool, let toolCallId = message.toolCalls?.first?.id {
                    toolResponseIds.insert(toolCallId)
                }
            }

            // Now filter messages:
            // 1. Keep all non-tool, non-assistant messages
            // 2. For assistant messages with tool_calls, only keep tool_calls that have matching responses
            // 3. For tool messages, only keep if preceding assistant has the matching tool_call
            var filteredMessages: [Message] = []
            for (index, message) in messages.enumerated() {
                if message.role == .tool {
                    // Get the tool_call_id from this tool message
                    guard let toolCallId = message.toolCalls?.first?.id else {
                        DiagnosticsLogger.log(
                            .aiService,
                            level: .info,
                            message: "⚠️ Skipping tool message without tool_call_id",
                            metadata: ["index": "\(index)"]
                        )
                        continue
                    }

                    // Check if the preceding message is an assistant with matching tool_call
                    if index > 0 {
                        let prevMessage = messages[index - 1]
                        if prevMessage.role == .assistant,
                           let toolCalls = prevMessage.toolCalls,
                           toolCalls.contains(where: { $0.id == toolCallId })
                        {
                            // Valid tool message with matching ID - keep it
                            filteredMessages.append(message)
                        } else {
                            DiagnosticsLogger.log(
                                .aiService,
                                level: .info,
                                message: "⚠️ Skipping orphaned/mismatched tool message",
                                metadata: ["index": "\(index)", "toolCallId": toolCallId]
                            )
                        }
                    }
                } else if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    // For assistant messages with tool_calls, filter to only those with matching tool responses
                    let validToolCalls = toolCalls.filter { toolResponseIds.contains($0.id) }

                    if validToolCalls.isEmpty {
                        // No valid tool calls - add assistant without tool_calls
                        var modifiedMessage = message
                        modifiedMessage.toolCalls = nil
                        filteredMessages.append(modifiedMessage)
                        DiagnosticsLogger.log(
                            .aiService,
                            level: .info,
                            message: "⚠️ Stripped orphaned tool_calls from assistant message",
                            metadata: [
                                "index": "\(index)",
                                "originalToolCallCount": "\(toolCalls.count)"
                            ]
                        )
                    } else if validToolCalls.count < toolCalls.count {
                        // Some tool calls are orphaned - keep only valid ones
                        var modifiedMessage = message
                        modifiedMessage.toolCalls = validToolCalls
                        filteredMessages.append(modifiedMessage)
                        DiagnosticsLogger.log(
                            .aiService,
                            level: .info,
                            message: "⚠️ Filtered some orphaned tool_calls from assistant",
                            metadata: [
                                "index": "\(index)",
                                "kept": "\(validToolCalls.count)",
                                "removed": "\(toolCalls.count - validToolCalls.count)"
                            ]
                        )
                    } else {
                        // All tool calls have matching responses - keep as-is
                        filteredMessages.append(message)
                    }
                } else {
                    filteredMessages.append(message)
                }
            }

            let messagePayloads: [[String: Any]] = filteredMessages.map { buildMessagePayload(from: $0) }
        #else
            // watchOS: No tool support, just pass messages through
            let messagePayloads: [[String: Any]] = messages.map { buildMessagePayload(from: $0) }
        #endif

        var body: [String: Any] = [
            "messages": messagePayloads,
            "model": model,
            "stream": stream
        ]

        // Add tools if provided
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        return body
    }

    // MARK: - Responses API

    /// Build input array for the Responses API.
    ///
    /// The Responses API uses a different format than Chat Completions:
    /// - Messages are wrapped in `type: "message"` objects
    /// - Content types are `input_text`/`output_text` instead of just `text`
    /// - Images use `input_image` type
    /// - System messages are skipped
    /// - Tool results use `function_call_output` type (not "tool" role)
    /// - Assistant tool calls use `function_call` type in output
    ///
    /// - Parameter messages: Messages to convert
    /// - Returns: Array of input items for the Responses API
    static func buildResponsesInput(from messages: [Message]) -> [[String: Any]] {
        var inputArray: [[String: Any]] = []

        for message in messages {
            // Skip system messages - Responses API handles them differently
            if message.role == .system {
                continue
            }

            #if !os(watchOS)
                // Handle tool result messages - convert to function_call_output
                if message.role == .tool {
                    if let toolCalls = message.toolCalls, let firstToolCall = toolCalls.first {
                        let outputItem: [String: Any] = [
                            "type": "function_call_output",
                            "call_id": firstToolCall.id,
                            "output": message.content
                        ]
                        inputArray.append(outputItem)
                    }
                    continue
                }

                // Handle assistant messages with tool calls
                if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    // First add any text content as a message
                    if !message.content.isEmpty {
                        let messageItem: [String: Any] = [
                            "type": "message",
                            "role": "assistant",
                            "content": [
                                ["type": "output_text", "text": message.content]
                            ]
                        ]
                        inputArray.append(messageItem)
                    }

                    // Then add each tool call as a function_call item
                    for toolCall in toolCalls {
                        // Convert AnyCodable arguments to JSON string
                        var argumentsDict: [String: Any] = [:]
                        for (key, anyCodable) in toolCall.arguments {
                            argumentsDict[key] = anyCodable.value
                        }

                        let argumentsString: String = if let argsData = try? JSONSerialization.data(withJSONObject: argumentsDict),
                                                         let argsStr = String(data: argsData, encoding: .utf8)
                        {
                            argsStr
                        } else {
                            "{}"
                        }

                        let functionCallItem: [String: Any] = [
                            "type": "function_call",
                            "call_id": toolCall.id,
                            "name": toolCall.toolName,
                            "arguments": argumentsString
                        ]
                        inputArray.append(functionCallItem)
                    }
                    continue
                }
            #endif

            var messageItem: [String: Any] = [
                "type": "message",
                "role": message.role.rawValue
            ]

            var contentArray: [[String: Any]] = []

            if !message.content.isEmpty {
                let contentType = message.role == .user ? "input_text" : "output_text"
                contentArray.append([
                    "type": contentType,
                    "text": message.content
                ])
            }

            // Add image attachments for user messages
            if let attachments = message.attachments, !attachments.isEmpty, message.role == .user {
                for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                    if let data = attachment.content {
                        let base64Data = data.base64EncodedString()
                        contentArray.append([
                            "type": "input_image",
                            "image_url": "data:\(attachment.mimeType);base64,\(base64Data)",
                        ])
                    }
                }
            }

            messageItem["content"] = contentArray
            inputArray.append(messageItem)
        }

        return inputArray
    }

    /// Convert tools from Chat Completions format to Responses API format.
    ///
    /// Chat Completions: `{"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}`
    /// Responses API: `{"type": "function", "name": "...", "description": "...", "parameters": {...}}`
    ///
    /// - Parameter tools: Tools in Chat Completions format
    /// - Returns: Tools in Responses API format
    static func convertToolsToResponsesFormat(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            // Check if it's already in Responses format (has top-level "name")
            if tool["name"] != nil {
                return tool
            }

            // Convert from Chat Completions format
            guard let functionDict = tool["function"] as? [String: Any],
                  let name = functionDict["name"] as? String
            else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "❌ Invalid tool format - missing function.name",
                    metadata: ["tool": "\(tool)"]
                )
                return nil
            }

            var responsesTool: [String: Any] = [
                "type": "function",
                "name": name
            ]

            if let description = functionDict["description"] as? String {
                responsesTool["description"] = description
            }

            if let parameters = functionDict["parameters"] {
                responsesTool["parameters"] = parameters
            }

            return responsesTool
        }
    }

    /// Build the Responses API request body.
    ///
    /// - Parameters:
    ///   - model: Model identifier
    ///   - messages: Messages to include
    ///   - tools: Optional tool definitions (OpenAI Chat Completions format - will be converted)
    /// - Returns: Dictionary suitable for JSON serialization
    static func buildResponsesBody(
        model: String,
        messages: [Message],
        tools: [[String: Any]]? = nil
    ) -> [String: Any] {
        let inputArray = buildResponsesInput(from: messages)

        var body: [String: Any] = [
            "model": model,
            "input": inputArray,
            "reasoning": ["summary": "auto"],
            "text": ["verbosity": "medium"]
        ]

        // Add tools if provided (convert from Chat Completions format to Responses format)
        if let tools, !tools.isEmpty {
            let responsesTools = convertToolsToResponsesFormat(tools)
            if !responsesTools.isEmpty {
                body["tools"] = responsesTools
                body["tool_choice"] = "auto"

                DiagnosticsLogger.log(
                    .aiService,
                    level: .debug,
                    message: "🔧 Converted tools to Responses API format",
                    metadata: ["count": "\(responsesTools.count)"]
                )
            }
        }

        return body
    }

    /// Result from parsing Responses API output
    struct ResponsesOutputResult {
        let hasToolCalls: Bool
        let toolCalls: [ToolCallInfo]
    }

    /// Deliver output from the Responses API to callbacks.
    ///
    /// Parses the output array and calls appropriate callbacks for:
    /// - Reasoning summaries (delivered to `onReasoning`)
    /// - Message content (delivered to `onChunk`)
    /// - Tool calls (delivered to `onToolCallRequested`)
    ///
    /// - Parameters:
    ///   - outputArray: The output array from the API response
    ///   - onChunk: Callback for content chunks
    ///   - onReasoning: Optional callback for reasoning summaries
    ///   - onToolCallRequested: Optional callback when a tool call is requested
    /// - Returns: Result indicating if tool calls were found
    static func deliverResponsesOutput(
        _ outputArray: [[String: Any]],
        onChunk: @escaping (String) -> Void,
        onReasoning: ((String) -> Void)?,
        onToolCallRequested: ((String, String, [String: Any]) -> Void)? = nil
    ) -> ResponsesOutputResult {
        var toolCalls: [ToolCallInfo] = []

        for outputItem in outputArray {
            let itemType = outputItem["type"] as? String

            if itemType == "reasoning" {
                if let summaryArray = outputItem["summary"] as? [[String: Any]],
                   let onReasoning
                {
                    for summaryPart in summaryArray {
                        if let type = summaryPart["type"] as? String,
                           type == "summary_text",
                           let text = summaryPart["text"] as? String
                        {
                            onReasoning(text)
                        }
                    }
                }
            } else if itemType == "message",
                      let content = outputItem["content"] as? [[String: Any]]
            {
                for contentPart in content {
                    if let type = contentPart["type"] as? String,
                       type == "output_text",
                       let text = contentPart["text"] as? String
                    {
                        onChunk(text)
                    }
                }
            } else if itemType == "function_call" {
                // Handle tool/function calls from Responses API
                guard let callId = outputItem["call_id"] as? String ?? outputItem["id"] as? String,
                      let name = outputItem["name"] as? String
                else {
                    DiagnosticsLogger.log(
                        .aiService,
                        level: .error,
                        message: "❌ Responses API function_call missing id or name",
                        metadata: ["outputItem": "\(outputItem)"]
                    )
                    continue
                }

                // Parse arguments - can be string or dict
                var arguments: [String: Any] = [:]
                if let argsString = outputItem["arguments"] as? String,
                   let argsData = argsString.data(using: .utf8),
                   let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    arguments = argsDict
                } else if let argsDict = outputItem["arguments"] as? [String: Any] {
                    arguments = argsDict
                }

                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔧 Responses API: Tool call requested",
                    metadata: ["tool": name, "callId": callId]
                )

                toolCalls.append(ToolCallInfo(id: callId, name: name, arguments: arguments))
                onToolCallRequested?(callId, name, arguments)
            }
        }

        return ResponsesOutputResult(hasToolCalls: !toolCalls.isEmpty, toolCalls: toolCalls)
    }

    // MARK: - Request Configuration

    /// Configure a URLRequest with standard headers and authentication.
    ///
    /// - Parameters:
    ///   - request: The request to configure (inout)
    ///   - apiKey: API key for authentication
    ///   - isAzure: Whether this is an Azure endpoint
    ///   - isGitHubModels: Whether this is a GitHub Models endpoint
    static func configureRequest(
        _ request: inout URLRequest,
        apiKey: String,
        isAzure: Bool,
        isGitHubModels: Bool = false
    ) {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard !apiKey.isEmpty else { return }

        if isAzure {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else if isGitHubModels {
            // GitHub Models uses Bearer token with GitHub OAuth token
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Create a configured URLRequest for the Chat Completions API.
    ///
    /// - Parameters:
    ///   - url: The API endpoint URL
    ///   - messages: Messages to include
    ///   - model: Model identifier
    ///   - stream: Whether to stream the response
    ///   - tools: Optional tool definitions
    ///   - apiKey: API key for authentication
    ///   - isAzure: Whether this is an Azure endpoint
    ///   - isGitHubModels: Whether this is a GitHub Models endpoint
    /// - Returns: Configured URLRequest, or nil if body encoding fails
    static func createChatCompletionsRequest(
        url: URL,
        messages: [Message],
        model: String,
        stream: Bool,
        tools: [[String: Any]]? = nil,
        apiKey: String,
        isAzure: Bool,
        isGitHubModels: Bool = false
    ) -> URLRequest? {
        var request = URLRequest(url: url)
        configureRequest(&request, apiKey: apiKey, isAzure: isAzure, isGitHubModels: isGitHubModels)

        let body = buildChatCompletionsBody(
            messages: messages,
            model: model,
            stream: stream,
            tools: tools
        )

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        request.httpBody = bodyData
        return request
    }

    /// Create a configured URLRequest for the Responses API.
    ///
    /// - Parameters:
    ///   - url: The API endpoint URL
    ///   - messages: Messages to include
    ///   - model: Model identifier
    ///   - tools: Optional tool definitions
    ///   - apiKey: API key for authentication
    ///   - isAzure: Whether this is an Azure endpoint
    /// - Returns: Configured URLRequest, or nil if body encoding fails
    static func createResponsesRequest(
        url: URL,
        messages: [Message],
        model: String,
        tools: [[String: Any]]? = nil,
        apiKey: String,
        isAzure: Bool
    ) -> URLRequest? {
        var request = URLRequest(url: url)
        configureRequest(&request, apiKey: apiKey, isAzure: isAzure)

        let body = buildResponsesBody(model: model, messages: messages, tools: tools)

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Failed to encode Responses API body",
                metadata: ["model": model]
            )
            return nil
        }

        request.httpBody = bodyData
        return request
    }

    // MARK: - Memory Context Injection

    /// Builds a complete message array with memory context injected.
    ///
    /// Context is injected in this order (following ChatGPT's pattern):
    /// 1. System prompt (existing)
    /// 2. Session metadata (ephemeral)
    /// 3. User memory facts (persistent)
    /// 4. Recent conversations summary (computed)
    /// 5. Current conversation history (existing)
    /// 6. Latest user message
    ///
    /// - Parameters:
    ///   - systemPrompt: The system prompt for this conversation
    ///   - memoryContext: Memory context from MemoryContextProvider
    ///   - conversationHistory: The current conversation's message history
    /// - Returns: Array of messages ready for API request
    static func buildMessagesWithMemory(
        systemPrompt: String?,
        memoryContext: MemoryContext,
        conversationHistory: [Message]
    ) -> [Message] {
        var messages: [Message] = []

        // [0] System prompt (existing pattern)
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(Message(role: .system, content: systemPrompt))
        }

        // Only inject memory context if available
        guard memoryContext.hasContent else {
            messages.append(contentsOf: conversationHistory)
            return messages
        }

        // [1] Session metadata (ephemeral)
        if let sessionMetadata = memoryContext.sessionMetadata {
            messages.append(Message(role: .system, content: sessionMetadata))
        }

        // [2] User memory facts (persistent)
        if let userMemory = memoryContext.userMemory {
            messages.append(Message(role: .system, content: userMemory))
        }

        // [3] Recent conversations summary (computed)
        if let summaries = memoryContext.conversationSummaries {
            messages.append(Message(role: .system, content: summaries))
        }

        // [4-5] Current conversation history + latest message (existing)
        messages.append(contentsOf: conversationHistory)

        return messages
    }

    /// Estimates the token count for messages (rough approximation: 4 chars ≈ 1 token).
    ///
    /// - Note: This approximation works reasonably well for English text but significantly
    ///   underestimates token counts for CJK languages (Chinese, Japanese, Korean) where
    ///   1-2 characters typically equal 1 token. For production use with multilingual content,
    ///   consider using a proper tokenizer like tiktoken.
    static func estimateTokenCount(for messages: [Message]) -> Int {
        messages.reduce(0) { total, message in
            total + (message.content.count / 4) + 4 // +4 for role/message overhead
        }
    }
}
