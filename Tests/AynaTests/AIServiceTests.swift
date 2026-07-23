@testable import Ayna
import Foundation
import Testing

extension AIServiceGlobalStateTests {
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
            },
            streamRetryDelayOperation: @escaping @Sendable (Int, Date?) async -> Void = { attempt, retryAfterDate in
                await AIRetryPolicy.wait(for: attempt, retryAfterDate: retryAfterDate)
            }
        ) -> AIService {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let service = AIService(
                urlSession: session,
                anthropicProviderFactory: anthropicProviderFactory,
                streamRetryDelayOperation: streamRetryDelayOperation
            )
            service.customModels = ["gpt-4o"]
            service.selectedModel = "gpt-4o"
            return service
        }

        fileprivate nonisolated static func bodyString(from request: URLRequest) -> String {
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

        @Test
        func `versioned stream task storage preserves a newer replacement`() {
            var store = VersionedTaskStore<String, Int>()
            let firstVersion = UUID()
            let secondVersion = UUID()

            store.set(1, forKey: "model", version: firstVersion)
            store.set(2, forKey: "model", version: secondVersion)

            #expect(store.removeValue(forKey: "model", matching: firstVersion) == nil)
            #expect(store.value(forKey: "model") == 2)
            #expect(store.removeValue(forKey: "model", matching: secondVersion) == 2)
            #expect(store.value(forKey: "model") == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func `replacing a gated multi-model request prevents the stale prompt from launching`() async throws {
            let service = makeService()
            let model = "github-gated-model"
            let token = "github-token-\(UUID().uuidString)"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .githubModels
            service.modelAPIKeys[model] = token

            let gateKey = GitHubOAuthService.rateLimitKey(forAccessToken: token)
            try await GitHubModelsRequestGate.shared.acquire(key: gateKey)
            let requestBodies = RequestBodyCollector()
            MockURLProtocol.requestHandler = { request in
                requestBodies.append(Self.bodyString(from: request))
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let body = Data(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8
                )
                return (response, body)
            }

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "stale prompt")],
                models: [model],
                requestOwnerID: UUID(),
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, _ in }
            )
            for _ in 0 ..< 1000
                where await GitHubModelsRequestGate.shared.waiterCount(for: gateKey) < 1
            {
                await Task.yield()
            }

            let completion = TestCallbackWaiter()
            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "current prompt")],
                models: [model],
                requestOwnerID: UUID(),
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: { completion.signal() },
                onError: { _, error in
                    Issue.record("Unexpected multi-model error: \(error)")
                    completion.signal()
                }
            )
            for _ in 0 ..< 1000
                where await GitHubModelsRequestGate.shared.waiterCount(for: gateKey) < 2
            {
                await Task.yield()
            }

            await GitHubModelsRequestGate.shared.release(key: gateKey)
            await completion.wait()

            #expect(requestBodies.values.count == 1)
            #expect(requestBodies.values.first?.contains("current prompt") == true)
            #expect(requestBodies.values.first?.contains("stale prompt") == false)
            service.cancelCurrentRequest()
        }

        @Test(.timeLimit(.minutes(1)))
        func `replacing a stream during retry releases the GitHub gate`() async {
            let retryGate = StreamRetryGate()
            let service = makeService(
                streamRetryDelayOperation: { _, _ in
                    await retryGate.wait()
                }
            )
            let model = "github-retry-model"
            let token = "github-retry-token-\(UUID().uuidString)"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .githubModels
            service.modelAPIKeys[model] = token

            let responder = RetryingRequestResponder()
            MockURLProtocol.requestHandler = { request in
                responder.response(for: request)
            }

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "stale retry prompt")],
                models: [model],
                requestOwnerID: UUID(),
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, _ in }
            )
            await retryGate.waitUntilStarted()

            let completion = TestCallbackWaiter()
            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "current retry prompt")],
                models: [model],
                requestOwnerID: UUID(),
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: { completion.signal() },
                onError: { _, error in
                    Issue.record("Unexpected replacement request error: \(error)")
                    completion.signal()
                }
            )
            let gateKey = GitHubOAuthService.rateLimitKey(forAccessToken: token)
            for _ in 0 ..< 1000
                where await GitHubModelsRequestGate.shared.waiterCount(for: gateKey) < 1
            {
                await Task.yield()
            }

            await retryGate.release()
            await completion.wait()

            #expect(responder.requestCount == 2)
            #expect(responder.requestBodies.last?.contains("current retry prompt") == true)
            service.cancelCurrentRequest()
        }

        @Test(.timeLimit(.minutes(1)))
        func `send message without API key throws error`() async {
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

        @Test(.timeLimit(.minutes(1)))
        func `send message adds authorization header and payload`() async throws {
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
            let callbackWaiter = TestCallbackWaiter()

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
                        callbackWaiter.signal()
                    },
                    onError: { error in
                        Issue.record("Unexpected error: \(error)")
                        callbackWaiter.signal()
                    },
                    onToolCall: nil,
                    onToolCallRequested: nil,
                    onReasoning: nil
                )

                await callbackWaiter.wait()
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
            let userMessage = try #require(messages.first { message in
                message["role"] as? String == Message.Role.user.rawValue
            })
            let content = try #require(userMessage["content"] as? String)

            #expect(content == "Hi")
            #expect(receivedChunk.value == "Hello")
        }

        @Test(.timeLimit(.minutes(1)))
        func `background title request is not cancelled by foreground request`() async {
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
            let titleWaiter = TestCallbackWaiter()
            let chatWaiter = TestCallbackWaiter()

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
                            titleWaiter.signal()
                        },
                        onError: { error in
                            Issue.record("Unexpected title error: \(error)")
                            titleWaiter.signal()
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
                            chatWaiter.signal()
                        },
                        onError: { error in
                            Issue.record("Unexpected chat error: \(error)")
                            chatWaiter.signal()
                        },
                        onToolCall: nil,
                        onToolCallRequested: nil,
                        onReasoning: nil
                    )

                    await titleWaiter.wait()
                    await chatWaiter.wait()
                }
            }

            #expect(titleChunk.value == "Generated Title")
            #expect(chatChunk.value == "Chat Response")
        }

        @Test
        func `untracked Anthropic request does not replace current request`() async throws {
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

        @Test
        func `anthropic multi-model requests remain independently tracked`() {
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

            #expect(!providers.contains { !$0.isCancelled })
        }

        @Test(.timeLimit(.minutes(1)))
        func `send message parses structured content response`() async {
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
            let callbackWaiter = TestCallbackWaiter()

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
                        callbackWaiter.signal()
                    },
                    onError: { error in
                        Issue.record("Unexpected error: \(error)")
                        callbackWaiter.signal()
                    },
                    onToolCall: nil,
                    onToolCallRequested: nil,
                    onReasoning: nil
                )

                await callbackWaiter.wait()
            }
        }

        @Test
        func `gitHub Models rate limit tracking is per token`() throws {
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

        @Test
        func `gitHub Models retry after is per token`() throws {
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

        @Test(.timeLimit(.minutes(1)))
        func `anthropic model routes to Anthropic provider`() async {
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
            let callbackWaiter = TestCallbackWaiter()

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
                        callbackWaiter.signal()
                    },
                    onError: { error in
                        Issue.record("Unexpected error: \(error)")
                        callbackWaiter.signal()
                    },
                    onToolCall: nil,
                    onToolCallRequested: nil,
                    onReasoning: nil
                )

                await callbackWaiter.wait()
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

        @Test(.timeLimit(.minutes(1)))
        func `anthropic model without API key returns missing key error`() async {
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

        @Test(.timeLimit(.minutes(1)))
        func `anthropic HTTP 401 error returns API key error`() async {
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
            let callbackWaiter = TestCallbackWaiter()

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
                        callbackWaiter.signal()
                    },
                    onError: { error in
                        receivedErrorHolder.error = error
                        errorReceived()
                        callbackWaiter.signal()
                    },
                    onToolCall: nil,
                    onToolCallRequested: nil,
                    onReasoning: nil
                )

                await callbackWaiter.wait()
            }

            #expect(receivedErrorHolder.error != nil)
            let errorMessage = (receivedErrorHolder.error as? AynaError)?.errorDescription ?? receivedErrorHolder.error?.localizedDescription ?? ""
            #expect(errorMessage.lowercased().contains("anthropic") || errorMessage.lowercased().contains("key"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `anthropic response with thinking content delivers to reasoning callback`() async {
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
            let callbackWaiter = TestCallbackWaiter()

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
                        callbackWaiter.signal()
                    },
                    onError: { error in
                        Issue.record("Unexpected error: \(error)")
                        callbackWaiter.signal()
                    },
                    onToolCall: nil,
                    onToolCallRequested: nil,
                    onReasoning: { reasoning in
                        receivedReasoning.value += reasoning
                    }
                )

                await callbackWaiter.wait()
            }

            #expect(receivedChunks.value == "Here is my answer.")
            #expect(receivedReasoning.value == "Let me think about this...")
        }
    }

    @Suite("AIService Concurrency Tests", .serialized)
    @MainActor
    struct AIServiceConcurrencyTests {
        @Test
        func `nil-owned tracked requests are treated as distinct owners`() async throws {
            let factory = ControllableAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in factory.makeProvider() }
            )
            let model = "claude-nil-owner-test"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-test"
            let cancellation = TestCallbackWaiter()

            service.sendMessage(
                messages: [Message(role: .user, content: "First nil owner")],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    if error is CancellationError {
                        cancellation.signal()
                    }
                }
            )
            let firstProvider = try #require(factory.providers.first)

            service.sendMessage(
                messages: [Message(role: .user, content: "Second nil owner")],
                model: model,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            await cancellation.wait()

            #expect(firstProvider.isCancelled)
            #expect(factory.providers.count == 2)
            service.cancelCurrentRequest()
        }

        @Test
        func `replacing a tracked single-model owner emits cancellation`() async throws {
            let factory = ControllableAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in factory.makeProvider() }
            )
            let model = "claude-owner-test"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-test"
            let cancellation = TestCallbackWaiter()

            service.sendMessage(
                messages: [Message(role: .user, content: "First owner")],
                model: model,
                requestOwnerID: UUID(),
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    if error is CancellationError {
                        cancellation.signal()
                    }
                }
            )
            let firstProvider = try #require(factory.providers.first)

            service.sendMessage(
                messages: [Message(role: .user, content: "Second owner")],
                model: model,
                requestOwnerID: UUID(),
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            await cancellation.wait()

            #expect(firstProvider.isCancelled)
            #expect(factory.providers.count == 2)
            service.cancelCurrentRequest()
        }

        @Test
        func `cancelling a multi-model Anthropic request completes its child`() async throws {
            let factory = ControllableAnthropicProviderFactory()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let service = AIService(
                urlSession: URLSession(configuration: config),
                anthropicProviderFactory: { _ in factory.makeProvider() }
            )
            let model = "claude-cancel-test"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-test"
            let cancellation = TestCallbackWaiter()

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Cancel me")],
                models: [model],
                requestOwnerID: UUID(),
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, error in
                    if error is CancellationError {
                        cancellation.signal()
                    }
                }
            )
            for _ in 0 ..< 1000 where factory.providers.isEmpty {
                await Task.yield()
            }
            let provider = try #require(factory.providers.first)

            service.cancelCurrentRequest()
            await cancellation.wait()

            #expect(provider.isCancelled)
        }
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

private final class RequestBodyCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []

    var values: [String] {
        lock.withLock { bodies }
    }

    func append(_ body: String) {
        lock.withLock {
            bodies.append(body)
        }
    }
}

private actor StreamRetryGate {
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}

private final class RetryingRequestResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var bodies: [String] = []

    var requestCount: Int {
        lock.withLock { count }
    }

    var requestBodies: [String] {
        lock.withLock { bodies }
    }

    func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let attempt = lock.withLock { () -> Int in
            count += 1
            bodies.append(AIServiceGlobalStateTests.AIServiceTests.bodyString(from: request))
            return count
        }
        let statusCode = attempt == 1 ? 500 : 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        if attempt == 1 {
            return (response, Data(#"{"error":{"message":"temporary 500"}}"#.utf8))
        }
        return (
            response,
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8)
        )
    }
}
