@testable import Ayna
import Foundation
import Testing

@Suite("AIService Tests", .tags(.networking, .async), .serialized)
@MainActor
struct AIServiceTests {
    private var defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: "AIServiceTests") else {
            fatalError("Failed to create UserDefaults suite for AIServiceTests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "AIServiceTests")
        defaults.synchronize()
        AppPreferences.use(defaults)

        // Use in-memory keychain to avoid touching the real Keychain in tests
        AIService.keychain = InMemoryKeychainStorage()
        GitHubOAuthService.keychain = InMemoryKeychainStorage()
        MockURLProtocol.reset()
    }

    private func makeService(
        anthropicProviderFactory: @escaping @MainActor (URLSession) -> any AIProviderProtocol = {
            AnthropicProvider(urlSession: $0)
        }
    ) -> AIService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = AIService(
            urlSession: session,
            anthropicProviderFactory: anthropicProviderFactory
        )
        service.customModels = ["gpt-4o"]
        service.selectedModel = "gpt-4o"
        return service
    }

    private static func bodyString(from request: URLRequest) -> String {
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            stream.close()
            bodyData = data
        }

        guard let bodyData else { return "" }
        return String(data: bodyData, encoding: .utf8) ?? ""
    }

    @Test("Send message without API key throws error", .timeLimit(.minutes(1)))
    func sendMessageWithoutAPIKeyThrowsError() async {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = ""

        await confirmation("onError called") { errorReceived in
            service.sendMessage(
                messages: [Message(role: .user, content: "Ping")],
                model: nil,
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { _ in
                    Issue.record("Did not expect chunks when API key is missing")
                },
                onComplete: {
                    Issue.record("Completion should not fire when API key is missing")
                },
                onError: { error in
                    guard case AynaError.missingAPIKey = error else {
                        Issue.record("Unexpected error: \(error)")
                        return
                    }
                    errorReceived()
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            // Give time for async callback
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("Send message adds authorization header and payload", .timeLimit(.minutes(1)))
    func sendMessageAddsAuthorizationHeaderAndPayload() async throws {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = "sk-unit-test"

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"choices":[{"message":{"content":"Hello"}}]}
                """.utf8
            )
            return (response, body)
        }

        let receivedChunk = ResultHolder()

        await confirmation("Request completes") { completed in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hi")],
                model: nil,
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { chunk in
                    receivedChunk.value = chunk
                },
                onComplete: {
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            // Give time for async callback
            try? await Task.sleep(for: .milliseconds(500))
        }

        let request = try #require(MockURLProtocol.lastRequest)

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-unit-test")

        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            stream.close()
            bodyData = data
        }

        let body = try #require(bodyData)
        let json = try #require(try? JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["stream"] as? Bool == false)

        let messages = try #require(json["messages"] as? [[String: Any]])
        let firstMessage = try #require(messages.first)
        let content = try #require(firstMessage["content"] as? String)

        #expect(content == "Hi")
        #expect(receivedChunk.value == "Hello")
    }

    @Test("Background title request is not cancelled by foreground request", .timeLimit(.minutes(1)))
    func backgroundTitleRequestIsNotCancelledByForegroundRequest() async {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = "sk-unit-test"

        MockURLProtocol.requestHandler = { request in
            let body = Self.bodyString(from: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let content = body.contains("Generate a very short title") ? "Generated Title" : "Chat Response"
            let responseBody = Data(#"{"choices":[{"message":{"content":"\#(content)"}}]}"#.utf8)
            return (response, responseBody)
        }

        let titleChunk = ResultHolder()
        let chatChunk = ResultHolder()

        await confirmation("background title request completes") { titleCompleted in
            await confirmation("foreground request completes") { chatCompleted in
                service.sendMessage(
                    messages: [Message(role: .user, content: "Generate a very short title")],
                    model: nil,
                    temperature: nil,
                    stream: false,
                    tools: nil,
                    conversationId: nil,
                    tracksCurrentRequest: false,
                    onChunk: { chunk in
                        titleChunk.value += chunk
                    },
                    onComplete: {
                        titleCompleted()
                    },
                    onError: { error in
                        Issue.record("Unexpected title error: \(error)")
                    },
                    onToolCall: nil,
                    onToolCallRequested: nil,
                    onReasoning: nil
                )

                service.sendMessage(
                    messages: [Message(role: .user, content: "Real chat request")],
                    model: nil,
                    temperature: nil,
                    stream: false,
                    tools: nil,
                    conversationId: nil,
                    onChunk: { chunk in
                        chatChunk.value += chunk
                    },
                    onComplete: {
                        chatCompleted()
                    },
                    onError: { error in
                        Issue.record("Unexpected chat error: \(error)")
                    },
                    onToolCall: nil,
                    onToolCallRequested: nil,
                    onReasoning: nil
                )

                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        #expect(titleChunk.value == "Generated Title")
        #expect(chatChunk.value == "Chat Response")
    }

    @Test("Untracked Anthropic request does not replace current request")
    func untrackedAnthropicRequestDoesNotReplaceCurrentRequest() async throws {
        let factory = ControllableAnthropicProviderFactory()
        let service = makeService { _ in
            factory.makeProvider()
        }
        let model = "claude-test"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .anthropic
        service.modelAPIKeys[model] = "sk-ant-unit-test"

        service.sendMessage(
            messages: [Message(role: .user, content: "Foreground chat")],
            model: model,
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        service.sendMessage(
            messages: [Message(role: .user, content: "Background title")],
            model: model,
            stream: false,
            tracksCurrentRequest: false,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )

        let providers = factory.providers
        #expect(providers.count == 2)

        let foregroundProvider = try #require(providers.first)
        let backgroundProvider = try #require(providers.last)
        backgroundProvider.complete()
        await Task.yield()

        service.cancelCurrentRequest()

        #expect(foregroundProvider.isCancelled)
        #expect(!backgroundProvider.isCancelled)
    }

    @Test("Anthropic multi-model requests remain independently tracked")
    func anthropicMultiModelRequestsRemainIndependentlyTracked() throws {
        let factory = ControllableAnthropicProviderFactory()
        let service = makeService { _ in
            factory.makeProvider()
        }
        let models = ["claude-a", "claude-b"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-unit-test"
            service.sendMessage(
                messages: [Message(role: .user, content: "Compare")],
                model: model,
                stream: true,
                isMultiModelRequest: true,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
        }

        let providers = factory.providers
        #expect(providers.count == models.count)
        #expect(providers.allSatisfy { !$0.isCancelled })

        service.cancelCurrentRequest()

        #expect(providers.allSatisfy { $0.isCancelled })
    }

    @Test("Send message parses structured content response", .timeLimit(.minutes(1)))
    func sendMessageParsesStructuredContentResponse() async {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = "sk-unit-test"

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"choices":[{"message":{"content":[{"type":"text","text":"Structured hello"}]}}]}
                """.utf8
            )
            return (response, body)
        }

        let receivedChunk = ResultHolder()

        await confirmation("Structured response parsed") { completed in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hello")],
                model: nil,
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { chunk in
                    receivedChunk.value += chunk
                },
                onComplete: {
                    #expect(receivedChunk.value == "Structured hello")
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            // Give time for async callback
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test("GitHub Models rate limit tracking is per token")
    func gitHubModelsRateLimitTrackingIsPerToken() throws {
        let oauth = GitHubOAuthService()

        let url = try #require(URL(string: "https://models.github.ai/inference/chat/completions"))
        let now = Date()

        let responseA = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "X-RateLimit-Limit": "100",
                "X-RateLimit-Remaining": "10",
                "X-RateLimit-Reset": "\(Int(now.addingTimeInterval(60).timeIntervalSince1970))",
                "X-RateLimit-Resource": "ai-inference"
            ]
        ))

        let responseB = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "X-RateLimit-Limit": "100",
                "X-RateLimit-Remaining": "3",
                "X-RateLimit-Reset": "\(Int(now.addingTimeInterval(120).timeIntervalSince1970))",
                "X-RateLimit-Resource": "ai-inference"
            ]
        ))

        oauth.updateRateLimit(from: responseA, forAccessToken: "token-A")
        oauth.updateRateLimit(from: responseB, forAccessToken: "token-B")

        #expect(oauth.rateLimitInfo(forAccessToken: "token-A")?.remaining == 10)
        #expect(oauth.rateLimitInfo(forAccessToken: "token-B")?.remaining == 3)
    }

    @Test("GitHub Models retry after is per token")
    func gitHubModelsRetryAfterIsPerToken() throws {
        let oauth = GitHubOAuthService()

        let url = try #require(URL(string: "https://models.github.ai/inference/chat/completions"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: [
                "Retry-After": "60"
            ]
        ))

        oauth.updateRetryAfter(from: response, forAccessToken: "token-A")

        #expect(oauth.retryAfterDate(forAccessToken: "token-A") != nil)
        #expect(oauth.retryAfterDate(forAccessToken: "token-B") == nil)

        oauth.clearRetryAfter(forAccessToken: "token-A")
        #expect(oauth.retryAfterDate(forAccessToken: "token-A") == nil)
    }

    // MARK: - Anthropic Integration Tests

    private func makeAnthropicService() -> AIService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = AIService(urlSession: session)
        service.customModels = ["claude-sonnet-4-20250514"]
        service.selectedModel = "claude-sonnet-4-20250514"
        service.modelProviders["claude-sonnet-4-20250514"] = .anthropic
        return service
    }

    @Test("Anthropic model routes to Anthropic provider", .timeLimit(.minutes(1)))
    func anthropicModelRoutesToAnthropicProvider() async {
        let service = makeAnthropicService()
        service.modelAPIKeys["claude-sonnet-4-20250514"] = "sk-ant-test-key"

        let responseBody = """
        {
            "id": "msg_123",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hello from Claude!"}],
            "stop_reason": "end_turn"
        }
        """

        var capturedRequest: URLRequest?

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let receivedChunk = ResultHolder()

        await confirmation("Anthropic response received") { completed in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hello")],
                model: "claude-sonnet-4-20250514",
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { chunk in
                    receivedChunk.value += chunk
                },
                onComplete: {
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        // Verify request went to Anthropic endpoint
        if let request = capturedRequest {
            #expect(request.url?.host == "api.anthropic.com")
            #expect(request.url?.path == "/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        }

        #expect(receivedChunk.value == "Hello from Claude!")
    }

    @Test("Anthropic model without API key returns missing key error", .timeLimit(.minutes(1)))
    func anthropicModelWithoutAPIKeyReturnsMissingKeyError() async {
        let service = makeAnthropicService()
        service.modelAPIKeys["claude-sonnet-4-20250514"] = ""

        await confirmation("onError called") { errorReceived in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hello")],
                model: "claude-sonnet-4-20250514",
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { _ in
                    Issue.record("Did not expect chunks when API key is missing")
                },
                onComplete: {
                    Issue.record("Completion should not fire when API key is missing")
                },
                onError: { error in
                    guard case AynaError.missingAPIKey = error else {
                        Issue.record("Unexpected error: \(error)")
                        return
                    }
                    errorReceived()
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("Anthropic HTTP 401 error returns API key error", .timeLimit(.minutes(1)))
    func anthropicHTTP401ErrorReturnsAPIKeyError() async {
        let service = makeAnthropicService()
        service.modelAPIKeys["claude-sonnet-4-20250514"] = "sk-ant-invalid-key"

        let errorBody = """
        {"type": "error", "error": {"type": "authentication_error", "message": "Invalid API key"}}
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(errorBody.utf8))
        }

        let receivedErrorHolder = ErrorHolder()

        await confirmation("Error received") { errorReceived in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hello")],
                model: "claude-sonnet-4-20250514",
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { _ in },
                onComplete: {
                    Issue.record("Should not complete on 401 error")
                },
                onError: { error in
                    receivedErrorHolder.error = error
                    errorReceived()
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedErrorHolder.error != nil)
        let errorMessage = (receivedErrorHolder.error as? AynaError)?.errorDescription ?? receivedErrorHolder.error?.localizedDescription ?? ""
        #expect(errorMessage.lowercased().contains("anthropic") || errorMessage.lowercased().contains("key"))
    }

    @Test("Anthropic response with thinking content delivers to reasoning callback", .timeLimit(.minutes(1)))
    func anthropicResponseWithThinkingContentDeliversToReasoningCallback() async {
        let service = makeAnthropicService()
        service.modelAPIKeys["claude-sonnet-4-20250514"] = "sk-ant-test-key"

        let responseBody = """
        {
            "id": "msg_123",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Let me think about this..."},
                {"type": "text", "text": "Here is my answer."}
            ],
            "stop_reason": "end_turn"
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let receivedChunks = ResultHolder()
        let receivedReasoning = ResultHolder()

        await confirmation("Response completes") { completed in
            service.sendMessage(
                messages: [Message(role: .user, content: "Think about this")],
                model: "claude-sonnet-4-20250514",
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { chunk in
                    receivedChunks.value += chunk
                },
                onComplete: {
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: { reasoning in
                    receivedReasoning.value += reasoning
                }
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedChunks.value == "Here is my answer.")
        #expect(receivedReasoning.value == "Let me think about this...")
    }

    @Test("Custom OpenAI-compatible endpoint can send without API key", .timeLimit(.minutes(1)))
    func customOpenAICompatibleEndpointCanSendWithoutAPIKey() async throws {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = ""
        service.modelEndpoints["gpt-4o"] = "https://proxy.example.com"

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"choices":[{"message":{"content":"Hello from proxy"}}]}
                """.utf8
            )
            return (response, body)
        }

        let receivedChunk = ResultHolder()

        #expect(service.isModelConfigured("gpt-4o") == true)

        await confirmation("Custom endpoint request completes") { completed in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hi")],
                model: "gpt-4o",
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { chunk in
                    receivedChunk.value += chunk
                },
                onComplete: {
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.absoluteString == "https://proxy.example.com/v1/chat/completions")
        #expect(receivedChunk.value == "Hello from proxy")
    }

    @Test("Custom OpenAI-compatible image endpoint can send without API key", .timeLimit(.minutes(1)))
    func customOpenAICompatibleImageEndpointCanSendWithoutAPIKey() async throws {
        let service = makeService()
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelAPIKeys["image-model"] = ""
        service.modelEndpoints["image-model"] = "https://proxy.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"data":[{"b64_json":"aW1hZ2U="}]}
                """.utf8
            )
            return (response, body)
        }

        let imageData = DataHolder()

        #expect(service.isModelConfigured("image-model") == true)

        await confirmation("Custom image endpoint request completes") { completed in
            service.generateImage(
                prompt: "a glass sphere",
                model: "image-model",
                onComplete: { data in
                    imageData.value = data
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                }
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.absoluteString == "https://proxy.example.com/v1/images/generations")
        #expect(imageData.value == Data("image".utf8))
    }

}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        requestHandler = nil
        lastRequest = nil
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0, userInfo: [NSLocalizedDescriptionKey: "Handler not set"]))
            return
        }

        do {
            let (response, data) = try handler(request)
            MockURLProtocol.lastRequest = request
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class ControllableAnthropicProviderFactory {
    private(set) var providers: [ControllableAnthropicProvider] = []

    func makeProvider() -> any AIProviderProtocol {
        let provider = ControllableAnthropicProvider()
        providers.append(provider)
        return provider
    }
}

@MainActor
private final class ControllableAnthropicProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .anthropic
    let requiresAPIKey = true
    private(set) var isCancelled = false
    private var callbacks: AIProviderStreamCallbacks?

    func sendMessage(
        messages _: [Message],
        config _: AIProviderRequestConfig,
        stream _: Bool,
        tools _: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    ) {
        self.callbacks = callbacks
    }

    func cancelRequest() {
        isCancelled = true
    }

    func complete() {
        callbacks?.onComplete()
    }
}

final class ResultHolder: @unchecked Sendable {
    var value = ""
}

final class DataHolder: @unchecked Sendable {
    var value = Data()
}

final class ErrorHolder: @unchecked Sendable {
    var error: Error?
}
