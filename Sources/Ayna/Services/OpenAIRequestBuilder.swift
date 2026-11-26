import Foundation
import os

struct ToolCallInfo: @unchecked Sendable {
    let id: String
    let name: String
    let arguments: [String: Any]
}

struct RequestBuilderToolDefinitions: @unchecked Sendable {
    static let none = RequestBuilderToolDefinitions(nil)

    let value: [[String: Any]]?

    init(_ value: [[String: Any]]?) {
        self.value = value
    }
}

enum RequestBuilderAttachmentResolver {
    typealias AttachmentDataLoader = @Sendable (String) async -> Data?

    static func resolvingImageAttachmentData(
        in messages: [Message],
        attachmentDataLoader: AttachmentDataLoader? = nil
    ) async throws -> [Message] {
        var resolvedMessages = messages

        for messageIndex in resolvedMessages.indices {
            try Task.checkCancellation()
            guard var attachments = resolvedMessages[messageIndex].attachments else { continue }

            var didUpdateAttachments = false
            for attachmentIndex in attachments.indices {
                try Task.checkCancellation()
                guard attachments[attachmentIndex].mimeType.starts(with: "image/"),
                      attachments[attachmentIndex].data == nil,
                      let localPath = attachments[attachmentIndex].localPath
                else {
                    continue
                }

                if let attachmentDataLoader {
                    attachments[attachmentIndex].data = await attachmentDataLoader(localPath)
                } else {
                    attachments[attachmentIndex].data = await attachments[attachmentIndex].loadContent()
                }
                try Task.checkCancellation()
                didUpdateAttachments = true
            }

            if didUpdateAttachments {
                resolvedMessages[messageIndex].attachments = attachments
            }
        }

        return resolvedMessages
    }
}

enum OpenAIRequestBuilder {
    static func buildMessagePayload(from message: Message) -> [String: Any] {
        var payload: [String: Any] = ["role": message.role.rawValue]

        if message.role == .tool {
            payload["content"] = message.content
            if let toolCalls = message.toolCalls, let firstToolCall = toolCalls.first {
                payload["tool_call_id"] = firstToolCall.id
            }
            return payload
        }

        if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            if !message.content.isEmpty {
                payload["content"] = message.content
            } else {
                payload["content"] = ""
            }

            let toolCallsArray = toolCalls.compactMap { toolCall -> [String: Any]? in
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

        if let attachments = message.attachments, !attachments.isEmpty {
            var contentArray: [[String: Any]] = []

            if !message.content.isEmpty {
                contentArray.append([
                    "type": "text",
                    "text": message.content
                ])
            }

            for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                if let data = attachment.data {
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
            payload["content"] = message.content
        }

        return payload
    }

    static func buildChatCompletionsBody(
        messages: [Message],
        model: String,
        stream: Bool,
        tools: [[String: Any]]? = nil,
        supportsParallelToolCalls: Bool = true
    ) -> [String: Any] {
        let sanitizedMessages = ToolTranscriptSanitizer.sanitize(messages)

        var toolResponseIds = Set<String>()
        for message in sanitizedMessages {
            if message.role == .tool, let toolCallId = message.toolCalls?.first?.id {
                toolResponseIds.insert(toolCallId)
            }
        }

        var filteredMessages: [Message] = []
        for (index, message) in sanitizedMessages.enumerated() {
            if message.role == .tool {
                guard let toolCallId = message.toolCalls?.first?.id else {
                    DiagnosticsLogger.log(
                        .aiService,
                        level: .info,
                        message: "⚠️ Skipping tool message without tool_call_id",
                        metadata: ["index": "\(index)"]
                    )
                    continue
                }

                if index == 0 {
                    DiagnosticsLogger.log(
                        .aiService,
                        level: .info,
                        message: "⚠️ Skipping orphaned/mismatched tool message",
                        metadata: ["index": "\(index)", "toolCallId": toolCallId]
                    )
                } else {
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
                    if foundAssistant {
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
                let validToolCalls = toolCalls.filter { toolResponseIds.contains($0.id) }

                if validToolCalls.isEmpty {
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
                    filteredMessages.append(message)
                }
            } else {
                filteredMessages.append(message)
            }
        }

        let messagePayloads = filteredMessages
            .filter { message in
                message.role != .assistant ||
                    !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !(message.toolCalls?.isEmpty ?? true)
            }
            .map { buildMessagePayload(from: $0) }

        var body: [String: Any] = [
            "messages": messagePayloads,
            "model": model,
            "stream": stream
        ]

        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
            if supportsParallelToolCalls {
                body["parallel_tool_calls"] = false
            }
        }

        return body
    }

    static func buildResponsesInput(from messages: [Message]) -> [[String: Any]] {
        let sanitizedMessages = ToolTranscriptSanitizer.sanitize(messages)
        var inputArray: [[String: Any]] = []
        var messageIndex = 0

        while messageIndex < sanitizedMessages.count {
            let message = sanitizedMessages[messageIndex]

            if message.role == .system {
                messageIndex += 1
                continue
            }

            if message.role == .tool {
                messageIndex += 1
                continue
            }

            if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                if !message.content.isEmpty {
                    inputArray.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            ["type": "output_text", "text": message.content]
                        ]
                    ])
                }

                var resultByCallID: [String: Message] = [:]
                var nextIndex = messageIndex + 1
                while nextIndex < sanitizedMessages.count, sanitizedMessages[nextIndex].role == .tool {
                    let resultMessage = sanitizedMessages[nextIndex]
                    if let callID = resultMessage.toolCalls?.first?.id,
                       resultByCallID[callID] == nil
                    {
                        resultByCallID[callID] = resultMessage
                    }
                    nextIndex += 1
                }

                var validCalls: [MCPToolCall] = []
                var seenCallIDs: Set<String> = []
                for toolCall in toolCalls
                    where resultByCallID[toolCall.id] != nil && seenCallIDs.insert(toolCall.id).inserted
                {
                    var argumentsDict: [String: Any] = [:]
                    for (key, anyCodable) in toolCall.arguments {
                        argumentsDict[key] = anyCodable.value
                    }
                    let argumentsString: String = if let data = try? JSONSerialization.data(
                        withJSONObject: argumentsDict
                    ), let string = String(data: data, encoding: .utf8) {
                        string
                    } else {
                        "{}"
                    }
                    inputArray.append([
                        "type": "function_call",
                        "call_id": toolCall.id,
                        "name": toolCall.toolName,
                        "arguments": argumentsString
                    ])
                    validCalls.append(toolCall)
                }

                for toolCall in validCalls {
                    guard let resultMessage = resultByCallID[toolCall.id] else { continue }
                    inputArray.append([
                        "type": "function_call_output",
                        "call_id": toolCall.id,
                        "output": resultMessage.content
                    ])
                }

                messageIndex = nextIndex
                continue
            }

            var messageItem: [String: Any] = [
                "type": "message",
                "role": message.role.rawValue
            ]
            var contentArray: [[String: Any]] = []

            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let contentType = message.role == .user ? "input_text" : "output_text"
                contentArray.append([
                    "type": contentType,
                    "text": message.content
                ])
            }

            if let attachments = message.attachments, !attachments.isEmpty, message.role == .user {
                for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                    if let data = attachment.data {
                        contentArray.append([
                            "type": "input_image",
                            "image_url": "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
                        ])
                    }
                }
            }

            guard !contentArray.isEmpty else {
                messageIndex += 1
                continue
            }

            messageItem["content"] = contentArray
            inputArray.append(messageItem)
            messageIndex += 1
        }

        return inputArray
    }

    static func convertToolsToResponsesFormat(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            if tool["name"] != nil {
                return tool
            }

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

    static func buildResponsesBody(
        model: String,
        messages: [Message],
        tools: [[String: Any]]? = nil,
        supportsParallelToolCalls: Bool = true
    ) -> [String: Any] {
        let inputArray = buildResponsesInput(from: messages)

        var body: [String: Any] = [
            "model": model,
            "input": inputArray,
            "reasoning": ["summary": "auto"],
            "text": ["verbosity": "medium"]
        ]

        let instructions = messages
            .filter { $0.role == .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.content)
            .joined(separator: "\n\n")
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }

        if let tools, !tools.isEmpty {
            let responsesTools = convertToolsToResponsesFormat(tools)
            if !responsesTools.isEmpty {
                body["tools"] = responsesTools
                body["tool_choice"] = "auto"
                if supportsParallelToolCalls {
                    body["parallel_tool_calls"] = false
                }

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

    struct ResponsesOutputResult {
        let hasToolCalls: Bool
        let toolCalls: [ToolCallInfo]
    }

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

    static func configureRequest(
        _ request: inout URLRequest,
        apiKey: String,
        isAzure: Bool
    ) {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard !apiKey.isEmpty else { return }

        if isAzure {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    static func createChatCompletionsRequestAsync(
        url: URL,
        messages: [Message],
        model: String,
        stream: Bool,
        tools: RequestBuilderToolDefinitions = .none,
        apiKey: String,
        isAzure: Bool,
        supportsParallelToolCalls: Bool = true,
        attachmentDataLoader: RequestBuilderAttachmentResolver.AttachmentDataLoader? = nil
    ) async -> URLRequest? {
        let resolvedMessages: [Message]
        do {
            resolvedMessages = try await RequestBuilderAttachmentResolver.resolvingImageAttachmentData(
                in: messages,
                attachmentDataLoader: attachmentDataLoader
            )
        } catch {
            return nil
        }

        let buildTask = Task.detached(priority: .userInitiated) {
            createChatCompletionsRequest(
                url: url,
                messages: resolvedMessages,
                model: model,
                stream: stream,
                tools: tools.value,
                apiKey: apiKey,
                isAzure: isAzure,
                supportsParallelToolCalls: supportsParallelToolCalls
            )
        }

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                buildTask.cancel()
                return nil
            }
            let request = await buildTask.value
            return Task.isCancelled ? nil : request
        } onCancel: {
            buildTask.cancel()
        }
    }

    static func createChatCompletionsRequest(
        url: URL,
        messages: [Message],
        model: String,
        stream: Bool,
        tools: [[String: Any]]? = nil,
        apiKey: String,
        isAzure: Bool,
        supportsParallelToolCalls: Bool = true
    ) -> URLRequest? {
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        configureRequest(&request, apiKey: apiKey, isAzure: isAzure)

        let body = buildChatCompletionsBody(
            messages: messages,
            model: model,
            stream: stream,
            tools: tools,
            supportsParallelToolCalls: supportsParallelToolCalls
        )

        guard !Task.isCancelled else { return nil }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        request.httpBody = bodyData
        return request
    }

    static func createResponsesRequestAsync(
        url: URL,
        messages: [Message],
        model: String,
        tools: RequestBuilderToolDefinitions = .none,
        apiKey: String,
        isAzure: Bool,
        supportsParallelToolCalls: Bool = true,
        attachmentDataLoader: RequestBuilderAttachmentResolver.AttachmentDataLoader? = nil
    ) async -> URLRequest? {
        let resolvedMessages: [Message]
        do {
            resolvedMessages = try await RequestBuilderAttachmentResolver.resolvingImageAttachmentData(
                in: messages,
                attachmentDataLoader: attachmentDataLoader
            )
        } catch {
            return nil
        }

        let buildTask = Task.detached(priority: .userInitiated) {
            createResponsesRequest(
                url: url,
                messages: resolvedMessages,
                model: model,
                tools: tools.value,
                apiKey: apiKey,
                isAzure: isAzure,
                supportsParallelToolCalls: supportsParallelToolCalls
            )
        }

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                buildTask.cancel()
                return nil
            }
            let request = await buildTask.value
            return Task.isCancelled ? nil : request
        } onCancel: {
            buildTask.cancel()
        }
    }

    static func createResponsesRequest(
        url: URL,
        messages: [Message],
        model: String,
        tools: [[String: Any]]? = nil,
        apiKey: String,
        isAzure: Bool,
        supportsParallelToolCalls: Bool = true
    ) -> URLRequest? {
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        configureRequest(&request, apiKey: apiKey, isAzure: isAzure)

        let body = buildResponsesBody(
            model: model,
            messages: messages,
            tools: tools,
            supportsParallelToolCalls: supportsParallelToolCalls
        )

        guard !Task.isCancelled else { return nil }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Failed to encode Responses API body",
                metadata: ["model": model]
            )
            return nil
        }
        guard !Task.isCancelled else { return nil }

        request.httpBody = bodyData
        return request
    }

    static func buildMessagesWithMemory(
        systemPrompt: String?,
        memoryContext: MemoryContext,
        conversationHistory: [Message]
    ) -> [Message] {
        var messages: [Message] = []

        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(Message(role: .system, content: systemPrompt))
        }

        guard memoryContext.hasContent else {
            messages.append(contentsOf: conversationHistory)
            return messages
        }

        if let sessionMetadata = memoryContext.sessionMetadata {
            messages.append(Message(role: .system, content: sessionMetadata))
        }

        if let userMemory = memoryContext.userMemory {
            messages.append(Message(role: .system, content: userMemory))
        }

        if let summaries = memoryContext.conversationSummaries {
            messages.append(Message(role: .system, content: summaries))
        }

        messages.append(contentsOf: conversationHistory)

        return messages
    }
}
