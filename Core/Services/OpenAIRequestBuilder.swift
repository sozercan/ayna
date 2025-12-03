import Foundation
import os

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
                            .openAIService,
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
                            .openAIService,
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
                                .openAIService,
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
                            .openAIService,
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
                            .openAIService,
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

    /// Build the Responses API request body.
    ///
    /// - Parameters:
    ///   - model: Model identifier
    ///   - messages: Messages to include
    /// - Returns: Dictionary suitable for JSON serialization
    static func buildResponsesBody(model: String, messages: [Message]) -> [String: Any] {
        let inputArray = buildResponsesInput(from: messages)

        return [
            "model": model,
            "input": inputArray,
            "reasoning": ["summary": "auto"],
            "text": ["verbosity": "medium"]
        ]
    }

    /// Deliver output from the Responses API to callbacks.
    ///
    /// Parses the output array and calls appropriate callbacks for:
    /// - Reasoning summaries (delivered to `onReasoning`)
    /// - Message content (delivered to `onChunk`)
    ///
    /// - Parameters:
    ///   - outputArray: The output array from the API response
    ///   - onChunk: Callback for content chunks
    ///   - onReasoning: Optional callback for reasoning summaries
    static func deliverResponsesOutput(
        _ outputArray: [[String: Any]],
        onChunk: @escaping (String) -> Void,
        onReasoning: ((String) -> Void)?
    ) {
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
            }
        }
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
    ///   - apiKey: API key for authentication
    ///   - isAzure: Whether this is an Azure endpoint
    /// - Returns: Configured URLRequest, or nil if body encoding fails
    static func createResponsesRequest(
        url: URL,
        messages: [Message],
        model: String,
        apiKey: String,
        isAzure: Bool
    ) -> URLRequest? {
        var request = URLRequest(url: url)
        configureRequest(&request, apiKey: apiKey, isAzure: isAzure)

        let body = buildResponsesBody(model: model, messages: messages)

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "❌ Failed to encode Responses API body",
                metadata: ["model": model]
            )
            return nil
        }

        request.httpBody = bodyData
        return request
    }
}
