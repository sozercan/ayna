@testable import Ayna
import Foundation
import Testing

@Suite("Request Builder Performance Benchmarks", .tags(.slow), .serialized)
struct RequestBuilderPerformanceBenchmarkTests {
    private static let openAIURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

    @Test(.timeLimit(.minutes(1)))
    func `openAI async builder constructs large text chat request`() async throws {
        let messages = Self.largeTextMessages(messageCount: 240, repeatedWordsPerMessage: 240)

        let start = CFAbsoluteTimeGetCurrent()
        let maybeRequest = await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
            url: Self.openAIURL,
            messages: messages,
            model: "gpt-4o",
            stream: true,
            apiKey: "test-key",
            isAzure: false
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let request = try #require(maybeRequest)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payloadMessages = try #require(body["messages"] as? [[String: Any]])

        print("BENCH request_builder.openai.chat.large_text.async seconds=\(elapsed) bytes=\(bodyData.count) messages=\(payloadMessages.count)")
        #expect(payloadMessages.count == messages.count)
        #expect(body["stream"] as? Bool == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `openAI async builder constructs large tools chat request`() async throws {
        let messages = [Message(role: .user, content: "Use the right tool for this request.")]
        let tools = Self.largeToolDefinitions(toolCount: 120, propertyCount: 18)

        let start = CFAbsoluteTimeGetCurrent()
        let maybeRequest = await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
            url: Self.openAIURL,
            messages: messages,
            model: "gpt-4o",
            stream: true,
            tools: RequestBuilderToolDefinitions(tools),
            apiKey: "test-key",
            isAzure: false
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let request = try #require(maybeRequest)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payloadTools = try #require(body["tools"] as? [[String: Any]])

        print("BENCH request_builder.openai.chat.large_tools.async seconds=\(elapsed) bytes=\(bodyData.count) tools=\(payloadTools.count)")
        #expect(payloadTools.count == tools.count)
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["parallel_tool_calls"] as? Bool == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `openAI async builder constructs image chat request`() async throws {
        let attachments = Self.imageAttachments(count: 4, bytesPerImage: 768 * 1024)
        let messages = [
            Message(
                role: .user,
                content: "Describe these images in detail.",
                attachments: attachments
            )
        ]

        let start = CFAbsoluteTimeGetCurrent()
        let maybeRequest = await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
            url: Self.openAIURL,
            messages: messages,
            model: "gpt-4o",
            stream: true,
            apiKey: "test-key",
            isAzure: false
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let request = try #require(maybeRequest)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payloadMessages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(payloadMessages.first?["content"] as? [[String: Any]])

        print("BENCH request_builder.openai.chat.images.async seconds=\(elapsed) bytes=\(bodyData.count) images=\(attachments.count)")
        #expect(content.count == attachments.count + 1)
        #expect(content.count(where: { $0["type"] as? String == "image_url" }) == attachments.count)
    }

    @Test(.timeLimit(.minutes(1)))
    func `openAI async builder constructs Responses request with large text tools and images`() async throws {
        let attachments = Self.imageAttachments(count: 2, bytesPerImage: 512 * 1024)
        var messages = Self.largeTextMessages(messageCount: 80, repeatedWordsPerMessage: 160)
        messages.append(
            Message(
                role: .user,
                content: "Now compare these screenshots.",
                attachments: attachments
            )
        )
        let tools = Self.largeToolDefinitions(toolCount: 80, propertyCount: 12)

        let start = CFAbsoluteTimeGetCurrent()
        let maybeRequest = await OpenAIRequestBuilder.createResponsesRequestAsync(
            url: Self.responsesURL,
            messages: messages,
            model: "gpt-4.1",
            tools: RequestBuilderToolDefinitions(tools),
            apiKey: "test-key",
            isAzure: false
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let request = try #require(maybeRequest)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let input = try #require(body["input"] as? [[String: Any]])
        let payloadTools = try #require(body["tools"] as? [[String: Any]])

        print("BENCH request_builder.openai.responses.mixed.async seconds=\(elapsed) bytes=\(bodyData.count) input=\(input.count) tools=\(payloadTools.count)")
        #expect(input.count == messages.count)
        #expect(payloadTools.count == tools.count)
        #expect(body["parallel_tool_calls"] as? Bool == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `anthropic async builder constructs image and tools request`() async throws {
        let attachments = Self.imageAttachments(count: 3, bytesPerImage: 768 * 1024)
        let messages = [
            Message(role: .system, content: "You are concise."),
            Message(
                role: .user,
                content: "Summarize visual differences.",
                attachments: attachments
            )
        ]
        let tools = Self.largeToolDefinitions(toolCount: 60, propertyCount: 10)
        let config = AnthropicRequestConfig(model: "claude-sonnet-4-20250514", apiKey: "test-key")

        let start = CFAbsoluteTimeGetCurrent()
        let request = try await AnthropicRequestBuilder.createMessagesRequestAsync(
            url: Self.anthropicURL,
            messages: messages,
            config: config,
            stream: true,
            tools: RequestBuilderToolDefinitions(tools)
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payloadMessages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(payloadMessages.first?["content"] as? [[String: Any]])
        let payloadTools = try #require(body["tools"] as? [[String: Any]])

        print("BENCH request_builder.anthropic.messages.images_tools.async seconds=\(elapsed) bytes=\(bodyData.count) images=\(attachments.count) tools=\(payloadTools.count)")
        #expect(body["system"] as? String == "You are concise.")
        #expect(content.count(where: { $0["type"] as? String == "image" }) == attachments.count)
        #expect(payloadTools.count == tools.count)
        let toolChoice = try #require(body["tool_choice"] as? [String: Any])
        #expect(toolChoice["disable_parallel_tool_use"] as? Bool == true)
    }

    private static func largeTextMessages(messageCount: Int, repeatedWordsPerMessage: Int) -> [Message] {
        (0 ..< messageCount).map { index in
            let role: Message.Role = index.isMultiple(of: 2) ? .user : .assistant
            let repeatedText = (0 ..< repeatedWordsPerMessage)
                .map { "message_\(index)_token_\($0)" }
                .joined(separator: " ")
            return Message(role: role, content: repeatedText)
        }
    }

    private static func largeToolDefinitions(toolCount: Int, propertyCount: Int) -> [[String: Any]] {
        (0 ..< toolCount).map { toolIndex in
            var properties: [String: Any] = [:]
            var required: [String] = []

            for propertyIndex in 0 ..< propertyCount {
                let name = "field_\(propertyIndex)"
                required.append(name)
                properties[name] = [
                    "type": propertyIndex.isMultiple(of: 3) ? "number" : "string",
                    "description": "Property \(propertyIndex) for benchmark tool \(toolIndex)",
                    "enum": ["alpha", "beta", "gamma", "delta"]
                ]
            }

            return [
                "type": "function",
                "function": [
                    "name": "benchmark_tool_\(toolIndex)",
                    "description": "Synthetic benchmark tool \(toolIndex) with a moderately large schema.",
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": required,
                        "additionalProperties": false
                    ]
                ]
            ]
        }
    }

    private static func imageAttachments(count: Int, bytesPerImage: Int) -> [Message.FileAttachment] {
        (0 ..< count).map { index in
            Message.FileAttachment(
                fileName: "benchmark_\(index).png",
                mimeType: "image/png",
                data: pngData(byteCount: bytesPerImage)
            )
        }
    }

    private static func pngData(byteCount: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        if byteCount > data.count {
            data.append(Data(repeating: 0xAB, count: byteCount - data.count))
        }
        return data
    }
}
