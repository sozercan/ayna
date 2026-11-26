import Foundation
import os

enum AnthropicOutputLimits {
    static let streamingDefault = 64000
    static let nonStreamingDefault = 16000

    static let cutoffNotice = "\n\n*[Response cut off: the model reached its output limit.]*"

    static func defaultMaxTokens(model: String, stream: Bool) -> Int {
        let requested = stream ? streamingDefault : nonStreamingDefault
        return min(requested, outputCap(for: model) ?? requested)
    }

    private static func outputCap(for model: String) -> Int? {
        let model = model.lowercased()
        if model.contains("claude-3-7") || model.contains("claude-3.7") { return 64000 }
        if model.contains("claude-3-5") || model.contains("claude-3.5") { return 8192 }
        if model.contains("claude-3") { return 4096 }
        if model.contains("claude-opus-4-0") || model.contains("claude-opus-4-1")
            || model.contains("claude-opus-4-2025") || model.contains("claude-4-opus")
        {
            return 32000
        }
        return nil
    }
}

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
        isAzureEndpoint = customEndpoint?.contains(".azure.com") == true ||
            customEndpoint?.contains("azure.") == true
    }
}

enum AnthropicRequestBuilder {
    static let maxImagesPerRequest = ChatDraftContent.maximumImageCount

    static let maxImageSizeBytes = 3_932_160

    static let supportedImageTypes = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    static let apiVersion = "2023-06-01"

    static func createMessagesRequestAsync(
        url: URL,
        messages: [Message],
        config: AnthropicRequestConfig,
        stream: Bool,
        tools: RequestBuilderToolDefinitions = .none,
        attachmentDataLoader: RequestBuilderAttachmentResolver.AttachmentDataLoader? = nil
    ) async throws -> URLRequest {
        let resolvedMessages = try await RequestBuilderAttachmentResolver.resolvingImageAttachmentData(
            in: messages,
            attachmentDataLoader: attachmentDataLoader
        )
        let buildTask = Task.detached(priority: .userInitiated) {
            try createMessagesRequest(
                url: url,
                messages: resolvedMessages,
                config: config,
                stream: stream,
                tools: tools.value
            )
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let request = try await buildTask.value
            try Task.checkCancellation()
            return request
        } onCancel: {
            buildTask.cancel()
        }
    }

    static func createMessagesRequest(
        url: URL,
        messages: [Message],
        config: AnthropicRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?
    ) throws -> URLRequest {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        configureHeaders(&request, config: config)

        let body = try buildMessagesBody(
            messages: messages,
            config: config,
            stream: stream,
            tools: tools
        )

        try Task.checkCancellation()
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw AynaError.encodingFailed(detail: "Failed to encode request body")
        }
        try Task.checkCancellation()

        request.httpBody = bodyData
        return request
    }

    static func configureHeaders(_ request: inout URLRequest, config: AnthropicRequestConfig) {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        if !config.betaHeaders.isEmpty, !config.isAzureEndpoint {
            let betaValue = config.betaHeaders.joined(separator: ",")
            request.setValue(betaValue, forHTTPHeaderField: "anthropic-beta")
        }
    }

    static func buildMessagesBody(
        messages: [Message],
        config: AnthropicRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?
    ) throws -> [String: Any] {
        try Task.checkCancellation()
        let (systemPrompt, anthropicMessages) = try extractSystemAndConvertMessages(messages)

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "messages": anthropicMessages,
            "stream": stream
        ]

        if let system = systemPrompt, !system.isEmpty {
            body["system"] = system
        }

        if let budgetTokens = config.budgetTokens, budgetTokens >= 1024 {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": budgetTokens
            ]
        }

        if let tools, !tools.isEmpty {
            try Task.checkCancellation()
            body["tools"] = convertToolsToAnthropicFormat(tools)
            body["tool_choice"] = [
                "type": "auto",
                "disable_parallel_tool_use": true
            ]
        }

        try Task.checkCancellation()
        return body
    }

    static func extractSystemAndConvertMessages(
        _ messages: [Message]
    ) throws -> (systemPrompt: String?, messages: [[String: Any]]) {
        let sanitizedMessages = ToolTranscriptSanitizer.sanitize(messages)
        var systemPrompt: String?
        var anthropicMessages: [[String: Any]] = []
        var imageCount = 0

        var toolResponseIds = Set<String>()
        for message in sanitizedMessages {
            try Task.checkCancellation()
            if message.role == .tool, let toolCallId = message.toolCalls?.first?.id {
                toolResponseIds.insert(toolCallId)
            }
        }

        for (index, message) in sanitizedMessages.enumerated() {
            try Task.checkCancellation()
            if message.role == .system {
                if systemPrompt == nil {
                    systemPrompt = message.content
                } else {
                    systemPrompt = (systemPrompt ?? "") + "\n\n" + message.content
                }
                continue
            }

            if message.role == .tool {
                guard let toolCallId = message.toolCalls?.first?.id else {
                    continue
                }

                if index == 0 {
                    continue
                }
                var foundAssistant = false
                for prevIdx in stride(from: index - 1, through: 0, by: -1) {
                    let prevMessage = sanitizedMessages[prevIdx]
                    if prevMessage.role == .assistant {
                        if let toolCalls = prevMessage.toolCalls,
                           toolCalls.contains(where: { $0.id == toolCallId })
                        {
                            foundAssistant = true
                        }
                        break
                    } else if prevMessage.role == .tool {
                        continue
                    } else {
                        break
                    }
                }
                if !foundAssistant {
                    continue
                }

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

            if message.role == .assistant,
               message.toolCalls?.isEmpty ?? true,
               message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                continue
            }

            if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let validToolCalls = toolCalls.filter { toolResponseIds.contains($0.id) }

                if validToolCalls.isEmpty {
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
            }

            let (converted, msgImageCount) = try convertMessage(message)
            imageCount += msgImageCount

            if imageCount > maxImagesPerRequest {
                throw AynaError.apiError(message: "Too many images: maximum \(maxImagesPerRequest) images per request")
            }

            anthropicMessages.append(converted)
        }

        return (systemPrompt, anthropicMessages)
    }

    static func convertMessage(_ message: Message) throws -> (converted: [String: Any], imageCount: Int) {
        try Task.checkCancellation()
        var payload: [String: Any] = [:]
        var imageCount = 0

        let role = switch message.role {
        case .user:
            "user"
        case .assistant:
            "assistant"
        case .system, .tool:
            "user"
        }
        payload["role"] = role

        if let attachments = message.attachments, !attachments.isEmpty, message.role == .user {
            var contentArray: [[String: Any]] = []

            for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                try Task.checkCancellation()
                guard let data = attachment.data else { continue }

                let imageBlock = try validateAndBuildImageBlock(data: data, fileName: attachment.fileName)
                try Task.checkCancellation()
                contentArray.append(imageBlock)
                imageCount += 1
            }

            if !message.content.isEmpty {
                contentArray.append([
                    "type": "text",
                    "text": message.content
                ])
            }

            payload["content"] = contentArray
        } else {
            payload["content"] = message.content
        }

        if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            var contentArray: [[String: Any]] = []

            if !message.content.isEmpty {
                contentArray.append([
                    "type": "text",
                    "text": message.content
                ])
            }

            for toolCall in toolCalls {
                try Task.checkCancellation()
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

        try Task.checkCancellation()
        return (payload, imageCount)
    }

    static func validateAndBuildImageBlock(data: Data, fileName _: String?) throws -> [String: Any] {
        try Task.checkCancellation()
        if let validationError = imageValidationError(data: data) {
            throw AynaError.apiError(message: validationError)
        }
        guard let type = detectImageMediaType(data: data) else {
            throw AynaError.apiError(message: "Unsupported image format. Supported: JPEG, PNG, GIF, WebP")
        }

        try Task.checkCancellation()
        let encodedData = data.base64EncodedString()
        try Task.checkCancellation()

        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": type,
                "data": encodedData
            ]
        ]
    }

    static func imageValidationError(data: Data) -> String? {
        if data.count > maxImageSizeBytes {
            let sizeMB = Double(data.count) / 1_048_576.0
            return "Image too large: \(String(format: "%.1f", sizeMB)) MB (max 3.75 MB)"
        }
        guard detectImageMediaType(data: data) != nil else {
            return "Unsupported image format. Supported: JPEG, PNG, GIF, WebP"
        }
        return nil
    }

    static func detectImageMediaType(data: Data) -> String? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }

        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }

        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "image/gif"
        }

        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50
        {
            return "image/webp"
        }

        return nil
    }

    static func convertToolsToAnthropicFormat(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            guard !Task.isCancelled else { return nil }
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
                anthropicTool["input_schema"] = ["type": "object", "properties": [:]]
            }

            return anthropicTool
        }
    }

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
