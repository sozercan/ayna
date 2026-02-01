//
//  AnthropicRequestBuilder.swift
//  ayna
//
//  Created on 1/30/26.
//

import Foundation
import os

/// Configuration for Anthropic API requests
struct AnthropicRequestConfig: Sendable {
    let model: String
    let apiKey: String
    let customEndpoint: String?
    let maxTokens: Int
    let budgetTokens: Int?
    let betaHeaders: [String]
    let isAzureEndpoint: Bool

    init(
        model: String,
        apiKey: String,
        customEndpoint: String? = nil,
        maxTokens: Int = 4096,
        budgetTokens: Int? = nil,
        betaHeaders: [String] = []
    ) {
        self.model = model
        self.apiKey = apiKey
        self.customEndpoint = customEndpoint
        self.maxTokens = maxTokens
        self.budgetTokens = budgetTokens
        self.betaHeaders = betaHeaders
        // Detect Azure endpoints by URL pattern
        isAzureEndpoint = customEndpoint?.contains(".azure.com") == true ||
            customEndpoint?.contains("azure.") == true
    }
}

/// Builder for constructing Anthropic API requests.
///
/// Handles:
/// - Message format conversion (OpenAI -> Anthropic)
/// - System prompt extraction
/// - Tool conversion (function -> input_schema)
/// - Image attachment conversion with validation
/// - Required headers and authentication
@MainActor
enum AnthropicRequestBuilder {
    // MARK: - Constants

    /// Maximum number of images per request
    static let maxImagesPerRequest = 20

    /// Maximum image size in bytes (3.75 MB)
    static let maxImageSizeBytes = 3_932_160

    /// Supported image MIME types
    static let supportedImageTypes = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    /// Current stable API version
    static let apiVersion = "2023-06-01"

    // MARK: - Public API

    /// Create a configured URLRequest for the Anthropic Messages API.
    ///
    /// - Parameters:
    ///   - url: The API endpoint URL
    ///   - messages: Messages to include
    ///   - config: Request configuration
    ///   - stream: Whether to stream the response
    ///   - tools: Optional tool definitions (OpenAI format)
    /// - Returns: Configured URLRequest
    /// - Throws: `AynaError` if validation fails
    static func createMessagesRequest(
        url: URL,
        messages: [Message],
        config: AnthropicRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        configureHeaders(&request, config: config)

        let body = try buildMessagesBody(
            messages: messages,
            config: config,
            stream: stream,
            tools: tools
        )

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw AynaError.encodingFailed(detail: "Failed to encode request body")
        }

        request.httpBody = bodyData
        return request
    }

    /// Configure request headers for Anthropic API.
    ///
    /// - Parameters:
    ///   - request: The request to configure (inout)
    ///   - config: Request configuration
    static func configureHeaders(_ request: inout URLRequest, config: AnthropicRequestConfig) {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Use x-api-key for all Anthropic endpoints (both standard and Azure Foundry)
        // Both platforms require anthropic-version header
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        // Add beta headers if any (only for non-Azure endpoints)
        if !config.betaHeaders.isEmpty, !config.isAzureEndpoint {
            let betaValue = config.betaHeaders.joined(separator: ",")
            request.setValue(betaValue, forHTTPHeaderField: "anthropic-beta")
        }
    }

    /// Build the request body for the Messages API.
    ///
    /// - Parameters:
    ///   - messages: Messages to include
    ///   - config: Request configuration
    ///   - stream: Whether to stream the response
    ///   - tools: Optional tool definitions
    /// - Returns: Dictionary suitable for JSON serialization
    /// - Throws: `AynaError` if validation fails
    static func buildMessagesBody(
        messages: [Message],
        config: AnthropicRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?
    ) throws -> [String: Any] {
        // Extract system prompt and convert remaining messages
        let (systemPrompt, anthropicMessages) = try extractSystemAndConvertMessages(messages)

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "messages": anthropicMessages,
            "stream": stream
        ]

        // Add system prompt at top level if present
        if let system = systemPrompt, !system.isEmpty {
            body["system"] = system
        }

        // Add extended thinking if budget_tokens is configured
        if let budgetTokens = config.budgetTokens, budgetTokens >= 1024 {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": budgetTokens
            ]
        }

        // Convert and add tools if provided
        if let tools, !tools.isEmpty {
            body["tools"] = convertToolsToAnthropicFormat(tools)
            body["tool_choice"] = ["type": "auto"]
        }

        return body
    }

    // MARK: - Message Conversion

    /// Extract system prompt and convert messages to Anthropic format.
    ///
    /// - Parameter messages: Original messages
    /// - Returns: Tuple of (system prompt, converted messages)
    /// - Throws: `AynaError` if validation fails
    static func extractSystemAndConvertMessages(
        _ messages: [Message]
    ) throws -> (systemPrompt: String?, messages: [[String: Any]]) {
        var systemPrompt: String?
        var anthropicMessages: [[String: Any]] = []
        var imageCount = 0

        #if !os(watchOS)
            // Build a set of valid tool_call_ids that have matching tool responses
            var toolResponseIds = Set<String>()
            for message in messages {
                if message.role == .tool, let toolCallId = message.toolCalls?.first?.id {
                    toolResponseIds.insert(toolCallId)
                }
            }
        #endif

        for (index, message) in messages.enumerated() {
            // Extract system prompt (don't include in messages array)
            if message.role == .system {
                if systemPrompt == nil {
                    systemPrompt = message.content
                } else {
                    // Concatenate multiple system messages
                    systemPrompt = (systemPrompt ?? "") + "\n\n" + message.content
                }
                continue
            }

            #if !os(watchOS)
                // Handle tool result messages - convert to Anthropic's tool_result format
                if message.role == .tool {
                    guard let toolCallId = message.toolCalls?.first?.id else {
                        // Skip tool messages without tool_call_id
                        continue
                    }

                    // Verify the preceding message is an assistant with matching tool_call
                    if index > 0 {
                        let prevMessage = messages[index - 1]
                        guard prevMessage.role == .assistant,
                              let toolCalls = prevMessage.toolCalls,
                              toolCalls.contains(where: { $0.id == toolCallId })
                        else {
                            // Orphaned tool message - skip it
                            continue
                        }
                    }

                    // Convert to Anthropic tool_result format (user role with tool_result content)
                    let toolResultBlock = buildToolResultContent(
                        toolUseId: toolCallId,
                        content: message.content
                    )
                    anthropicMessages.append([
                        "role": "user",
                        "content": [toolResultBlock]
                    ])
                    continue
                }

                // For assistant messages with tool_calls, filter to only those with matching tool responses
                if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    let validToolCalls = toolCalls.filter { toolResponseIds.contains($0.id) }

                    if validToolCalls.isEmpty {
                        // No valid tool calls - add assistant without tool_calls
                        var modifiedMessage = message
                        modifiedMessage.toolCalls = nil
                        let (converted, msgImageCount) = try convertMessage(modifiedMessage)
                        imageCount += msgImageCount
                        if imageCount > maxImagesPerRequest {
                            throw AynaError.apiError(
                                message: "Too many images: maximum \(maxImagesPerRequest) images per request"
                            )
                        }
                        anthropicMessages.append(converted)
                        continue
                    } else if validToolCalls.count < toolCalls.count {
                        // Some tool calls are orphaned - keep only valid ones
                        var modifiedMessage = message
                        modifiedMessage.toolCalls = validToolCalls
                        let (converted, msgImageCount) = try convertMessage(modifiedMessage)
                        imageCount += msgImageCount
                        if imageCount > maxImagesPerRequest {
                            throw AynaError.apiError(
                                message: "Too many images: maximum \(maxImagesPerRequest) images per request"
                            )
                        }
                        anthropicMessages.append(converted)
                        continue
                    }
                    // All tool calls have matching responses - fall through to normal conversion
                }
            #endif

            // Convert message
            let (converted, msgImageCount) = try convertMessage(message)
            imageCount += msgImageCount

            // Validate image count
            if imageCount > maxImagesPerRequest {
                throw AynaError.apiError(message: "Too many images: maximum \(maxImagesPerRequest) images per request")
            }

            anthropicMessages.append(converted)
        }

        return (systemPrompt, anthropicMessages)
    }

    /// Convert a single message to Anthropic format.
    ///
    /// - Parameter message: Message to convert
    /// - Returns: Tuple of (converted message, image count in this message)
    /// - Throws: `AynaError` if validation fails
    static func convertMessage(_ message: Message) throws -> (converted: [String: Any], imageCount: Int) {
        var payload: [String: Any] = [:]
        var imageCount = 0

        // Map role
        let role = switch message.role {
        case .user:
            "user"
        case .assistant:
            "assistant"
        case .system, .tool:
            // These should be handled elsewhere
            "user"
        }
        payload["role"] = role

        // Check for attachments
        if let attachments = message.attachments, !attachments.isEmpty, message.role == .user {
            // Build content array with text and images
            var contentArray: [[String: Any]] = []

            // Add images first
            for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                guard let data = attachment.content else { continue }

                // Validate image
                let imageBlock = try validateAndBuildImageBlock(data: data, fileName: attachment.fileName)
                contentArray.append(imageBlock)
                imageCount += 1
            }

            // Add text content
            if !message.content.isEmpty {
                contentArray.append([
                    "type": "text",
                    "text": message.content
                ])
            }

            payload["content"] = contentArray
        } else {
            // Simple text content
            payload["content"] = message.content
        }

        #if !os(watchOS)
            // Handle assistant messages with tool calls
            if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                var contentArray: [[String: Any]] = []

                // Add text content if present
                if !message.content.isEmpty {
                    contentArray.append([
                        "type": "text",
                        "text": message.content
                    ])
                }

                // Add tool use blocks
                for toolCall in toolCalls {
                    var argumentsDict: [String: Any] = [:]
                    for (key, anyCodable) in toolCall.arguments {
                        argumentsDict[key] = anyCodable.value
                    }

                    contentArray.append([
                        "type": "tool_use",
                        "id": toolCall.id,
                        "name": toolCall.toolName,
                        "input": argumentsDict
                    ])
                }

                payload["content"] = contentArray
            }
        #endif

        return (payload, imageCount)
    }

    // MARK: - Image Validation

    /// Validate image data and build an Anthropic image content block.
    ///
    /// - Parameters:
    ///   - data: Raw image data
    ///   - fileName: Optional file name for error messages
    /// - Returns: Image content block dictionary
    /// - Throws: `AynaError` if validation fails
    static func validateAndBuildImageBlock(data: Data, fileName _: String?) throws -> [String: Any] {
        // Check size
        if data.count > maxImageSizeBytes {
            let sizeMB = Double(data.count) / 1_048_576.0
            throw AynaError.apiError(message: "Image too large: \(String(format: "%.1f", sizeMB)) MB (max 3.75 MB)")
        }

        // Detect media type from magic bytes
        let mediaType = detectImageMediaType(data: data)
        guard let type = mediaType else {
            throw AynaError.apiError(message: "Unsupported image format. Supported: JPEG, PNG, GIF, WebP")
        }

        // Build image block
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": type,
                "data": data.base64EncodedString()
            ]
        ]
    }

    /// Detect image media type from magic bytes.
    ///
    /// - Parameter data: Image data
    /// - Returns: MIME type string or nil if not recognized
    static func detectImageMediaType(data: Data) -> String? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        // JPEG: FF D8 FF
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }

        // PNG: 89 50 4E 47
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }

        // GIF: 47 49 46 38
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "image/gif"
        }

        // WebP: 52 49 46 46 ... 57 45 42 50 (RIFF....WEBP)
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50
        {
            return "image/webp"
        }

        return nil
    }

    // MARK: - Tool Conversion

    /// Convert OpenAI tool format to Anthropic format.
    ///
    /// OpenAI: `{type: function, function: {name, description, parameters}}`
    /// Anthropic: `{name, description, input_schema}`
    ///
    /// - Parameter tools: Tools in OpenAI format
    /// - Returns: Tools in Anthropic format
    static func convertToolsToAnthropicFormat(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            guard let type = tool["type"] as? String, type == "function",
                  let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String
            else {
                return nil
            }

            var anthropicTool: [String: Any] = ["name": name]

            if let description = function["description"] as? String {
                anthropicTool["description"] = description
            }

            if let parameters = function["parameters"] as? [String: Any] {
                anthropicTool["input_schema"] = parameters
            } else {
                // Default to empty object schema if no parameters
                anthropicTool["input_schema"] = ["type": "object", "properties": [:]]
            }

            return anthropicTool
        }
    }

    // MARK: - Tool Result Building

    /// Build a tool result message for continuing after tool execution.
    ///
    /// - Parameters:
    ///   - toolUseId: The ID of the tool_use block being responded to
    ///   - content: The tool execution result
    ///   - isError: Whether the result represents an error
    /// - Returns: Message content block for the tool result
    static func buildToolResultContent(
        toolUseId: String,
        content: String,
        isError: Bool = false
    ) -> [String: Any] {
        var block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": content
        ]

        if isError {
            block["is_error"] = true
        }

        return block
    }
}
