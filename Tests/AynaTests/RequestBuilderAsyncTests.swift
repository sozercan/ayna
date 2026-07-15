@testable import Ayna
import Foundation
import Testing

@Suite("Request Builder Async Tests")
@MainActor
struct RequestBuilderAsyncTests {
    @Test
    func `async request builder resolves local-path image data off the synchronous payload path`() async throws {
        let imageData = Self.pngData(byteCount: 4096)
        let attachment = Message.FileAttachment(
            fileName: "local.png",
            mimeType: "image/png",
            data: nil,
            localPath: "benchmark-local-image"
        )
        let message = Message(role: .user, content: "Describe this local image.", attachments: [attachment])

        let maybeRequest = try await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
            url: #require(URL(string: "https://api.openai.com/v1/chat/completions")),
            messages: [message],
            model: "gpt-4o",
            stream: true,
            apiKey: "test-key",
            isAzure: false,
            attachmentDataLoader: { path in
                path == "benchmark-local-image" ? imageData : nil
            }
        )

        let request = try #require(maybeRequest)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payloadMessages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(payloadMessages.first?["content"] as? [[String: Any]])
        let imageBlock = try #require(content.first { $0["type"] as? String == "image_url" })
        let imageURL = try #require((imageBlock["image_url"] as? [String: Any])?["url"] as? String)

        #expect(imageURL.hasPrefix("data:image/png;base64,"))
        #expect(imageURL.contains(imageData.base64EncodedString()))
    }

    @Test
    func `cancelling OpenAI attachment resolution stops request construction`() async throws {
        let message = Self.messageWithLocalImage(path: "slow-openai-image")
        let url = try #require(URL(string: "https://api.openai.com/v1/chat/completions"))
        let imageData = Self.pngData(byteCount: 4096)

        let loaderGate = RequestBuilderAttachmentLoaderGate(data: imageData)
        let buildTask = Task {
            await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
                url: url,
                messages: [message],
                model: "gpt-4o",
                stream: true,
                apiKey: "test-key",
                isAzure: false,
                attachmentDataLoader: { _ in
                    await loaderGate.load()
                }
            )
        }

        await loaderGate.waitUntilStarted()
        buildTask.cancel()
        await loaderGate.release()

        #expect(await buildTask.value == nil)
    }

    @Test
    func `gitHub Models chat request omits unsupported parallel tool calls option`() async throws {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "lookup",
                "description": "Look up a value",
                "parameters": ["type": "object", "properties": [:]]
            ]
        ]]
        let url = try #require(URL(string: "https://models.github.ai/inference/chat/completions"))
        let request = try #require(await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
            url: url,
            messages: [Message(role: .user, content: "Use the lookup tool")],
            model: "openai/gpt-4o",
            stream: true,
            tools: RequestBuilderToolDefinitions(tools),
            apiKey: "github-token",
            isAzure: false,
            isGitHubModels: true
        ))
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        #expect(body["tools"] != nil)
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["parallel_tool_calls"] == nil)
    }

    @Test
    func `custom chat endpoint omits parallel tool calls option`() async throws {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "lookup",
                "parameters": ["type": "object", "properties": [:]]
            ]
        ]]
        let url = try #require(URL(string: "https://example.com/v1/chat/completions"))
        let request = try #require(await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
            url: url,
            messages: [Message(role: .user, content: "Use the lookup tool")],
            model: "custom-model",
            stream: true,
            tools: RequestBuilderToolDefinitions(tools),
            apiKey: "",
            isAzure: false,
            supportsParallelToolCalls: false
        ))
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        #expect(body["tools"] != nil)
        #expect(body["parallel_tool_calls"] == nil)
    }

    @Test
    func `cancelling Responses attachment resolution stops request construction`() async throws {
        let message = Self.messageWithLocalImage(path: "slow-responses-image")
        let url = try #require(URL(string: "https://api.openai.com/v1/responses"))
        let imageData = Self.pngData(byteCount: 4096)

        let loaderGate = RequestBuilderAttachmentLoaderGate(data: imageData)
        let buildTask = Task {
            await OpenAIRequestBuilder.createResponsesRequestAsync(
                url: url,
                messages: [message],
                model: "gpt-4o",
                apiKey: "test-key",
                isAzure: false,
                attachmentDataLoader: { _ in
                    await loaderGate.load()
                }
            )
        }

        await loaderGate.waitUntilStarted()
        buildTask.cancel()
        await loaderGate.release()

        #expect(await buildTask.value == nil)
    }

    @Test
    func `custom Responses endpoint omits parallel tool calls option`() async throws {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "lookup",
                "parameters": ["type": "object", "properties": [:]]
            ]
        ]]
        let url = try #require(URL(string: "https://example.com/v1/responses"))
        let request = try #require(await OpenAIRequestBuilder.createResponsesRequestAsync(
            url: url,
            messages: [Message(role: .user, content: "Use the lookup tool")],
            model: "custom-model",
            tools: RequestBuilderToolDefinitions(tools),
            apiKey: "",
            isAzure: false,
            supportsParallelToolCalls: false
        ))
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        #expect(body["tools"] != nil)
        #expect(body["parallel_tool_calls"] == nil)
    }

    @Test
    func `cancelling Anthropic attachment resolution stops request construction`() async throws {
        let message = Self.messageWithLocalImage(path: "slow-anthropic-image")
        let config = AnthropicRequestConfig(model: "claude-test", apiKey: "test-key")
        let url = try #require(URL(string: "https://api.anthropic.com/v1/messages"))
        let imageData = Self.pngData(byteCount: 4096)

        let loaderGate = RequestBuilderAttachmentLoaderGate(data: imageData)
        let buildTask = Task {
            try await AnthropicRequestBuilder.createMessagesRequestAsync(
                url: url,
                messages: [message],
                config: config,
                stream: true,
                attachmentDataLoader: { _ in
                    await loaderGate.load()
                }
            )
        }

        await loaderGate.waitUntilStarted()
        buildTask.cancel()
        await loaderGate.release()

        await #expect(throws: CancellationError.self) {
            try await buildTask.value
        }
    }

    @Test
    func `cancelled synchronous request builders exit at checkpoints`() async throws {
        let message = Message(role: .user, content: String(repeating: "payload", count: 10000))
        let openAIURL = try #require(URL(string: "https://api.openai.com/v1/responses"))
        let anthropicURL = try #require(URL(string: "https://api.anthropic.com/v1/messages"))
        let anthropicConfig = AnthropicRequestConfig(model: "claude-test", apiKey: "test-key")

        let openAIRequest = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return OpenAIRequestBuilder.createResponsesRequest(
                url: openAIURL,
                messages: [message],
                model: "gpt-4o",
                apiKey: "test-key",
                isAzure: false
            )
        }.value

        let anthropicRequest = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try? AnthropicRequestBuilder.createMessagesRequest(
                url: anthropicURL,
                messages: [message],
                config: anthropicConfig,
                stream: true,
                tools: nil
            )
        }.value

        #expect(openAIRequest == nil)
        #expect(anthropicRequest == nil)
    }

    private static func messageWithLocalImage(path: String) -> Message {
        let attachment = Message.FileAttachment(
            fileName: "local.png",
            mimeType: "image/png",
            data: nil,
            localPath: path
        )
        return Message(role: .user, content: "Describe this local image.", attachments: [attachment])
    }

    private static func pngData(byteCount: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        if byteCount > data.count {
            data.append(Data(repeating: 0xCD, count: byteCount - data.count))
        }
        return data
    }
}

private actor RequestBuilderAttachmentLoaderGate {
    private let data: Data
    private var hasStarted = false
    private var isReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(data: Data) {
        self.data = data
    }

    func load() async -> Data? {
        hasStarted = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        return data
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}
