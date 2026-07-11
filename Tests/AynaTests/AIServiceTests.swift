@testable import Ayna
import Foundation
import Testing

// swiftlint:disable type_body_length
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

    private func makeService() -> AIService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = AIService(urlSession: session)
        service.customModels = ["gpt-4o"]
        service.selectedModel = "gpt-4o"
        return service
    }

    @Test("Request flights reject stale cleanup")
    func requestFlightsRejectStaleCleanup() {
        var flight = RequestFlight<String>()
        let firstID = RequestFlightID()
        let secondID = RequestFlightID()

        #expect(flight.install("first", id: firstID) == nil)
        #expect(flight.install("second", id: secondID) == "first")
        let staleClearSucceeded = flight.clear(ifOwnedBy: firstID)
        #expect(!staleClearSucceeded)
        #expect(flight.owns(secondID))
    }

    @Test("Taking a request flight detaches its owner and handle")
    func takingRequestFlightDetachesOwnerAndHandle() {
        var flight = RequestFlight<String>()
        let flightID = RequestFlightID()
        flight.install("handle", id: flightID)

        let handle = flight.take()

        #expect(handle == "handle")
        #expect(!flight.isActive)
        #expect(!flight.owns(flightID))
    }

    @Test("Stale stream cleanup preserves the replacement cancellation handle", .timeLimit(.minutes(1)))
    func staleStreamCleanupPreservesReplacementCancellationHandle() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let staleCleanupProcessed = FlightTestSignal()
        let service = AIService(
            urlSession: URLSession(configuration: config),
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .streamCancellation, !ownsFlight {
                    staleCleanupProcessed.signal()
                }
            }
        )
        let models = ["stream-first", "stream-second"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }

        service.sendMessage(
            messages: [Message(role: .user, content: "First")],
            model: models[0],
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let first = await server.exchange(at: 0)
        first.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        service.sendMessage(
            messages: [Message(role: .user, content: "Second")],
            model: models[1],
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let second = await server.exchange(at: 1)
        second.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        let firstStopped = await first.waitUntilStopped()
        let staleCleanupObserved = await staleCleanupProcessed.wait(timeout: .seconds(2))
        #expect(firstStopped)
        #expect(staleCleanupObserved)

        service.cancelCurrentRequest()
        let replacementStopped = await second.waitUntilStopped()
        #expect(replacementStopped)
    }

    @Test("URLSession cancellation uses stream cancellation cleanup", .timeLimit(.minutes(1)))
    func urlSessionCancellationUsesStreamCancellationCleanup() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let cancellationProcessed = FlightTestSignal()
        let clearedOwnedFlight = FlightTestBox<Bool?>(nil)
        let service = AIService(
            urlSession: URLSession(configuration: config),
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .streamCancellation {
                    clearedOwnedFlight.value = ownsFlight
                    cancellationProcessed.signal()
                }
            }
        )
        let model = "cancelled-stream"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"
        let errors = FlightTestBox(0)

        service.sendMessage(
            messages: [Message(role: .user, content: "Cancel")],
            model: model,
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in errors.value += 1 }
        )
        let exchange = await server.exchange(at: 0)
        exchange.fail(URLError(.cancelled))

        let observedCancellation = await cancellationProcessed.wait(timeout: .seconds(2))
        #expect(observedCancellation)
        #expect(clearedOwnedFlight.value == true)
        #expect(errors.value == 0)
    }

    @Test("Stream tool result is discarded after ownership changes", .timeLimit(.minutes(1)))
    func streamToolResultIsDiscardedAfterOwnershipChanges() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let toolStarted = FlightTestSignal()
        let releaseTool = FlightTestSignal()
        let staleParserStopped = FlightTestSignal()
        let service = AIService(
            urlSession: URLSession(configuration: config),
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .streamCancellation, !ownsFlight {
                    staleParserStopped.signal()
                }
            }
        )
        let models = ["tool-stream", "tool-replacement"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }
        let staleChunks = FlightTestBox("")
        let staleCompleted = FlightTestBox(false)

        service.sendMessage(
            messages: [Message(role: .user, content: "Tool")],
            model: models[0],
            stream: true,
            onChunk: { staleChunks.value += $0 },
            onComplete: { staleCompleted.value = true },
            onError: { _ in },
            onToolCall: { _, _, _ in
                toolStarted.signal()
                await releaseTool.wait()
                return "stale tool result"
            }
        )
        let first = await server.exchange(at: 0)
        first.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        first.send(Data(
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"test_tool","arguments":"{}"}}]}}]}"#.utf8
        ))
        first.send(Data("\n".utf8))
        first.send(Data(#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#.utf8))
        first.send(Data("\n".utf8))
        let didStartTool = await toolStarted.wait(timeout: .seconds(2))
        #expect(didStartTool)

        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: models[1],
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let replacement = await server.exchange(at: 1)
        replacement.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        releaseTool.signal()
        let stoppedStaleParser = await staleParserStopped.wait(timeout: .seconds(2))
        #expect(stoppedStaleParser)
        #expect(staleChunks.value.isEmpty)
        #expect(!staleCompleted.value)

        service.cancelCurrentRequest()
        let replacementStopped = await replacement.waitUntilStopped()
        #expect(replacementStopped)
    }

    @Test("Per-model multi stream terminal leaves the foreground stream owned", .timeLimit(.minutes(1)))
    func perModelMultiStreamTerminalLeavesForegroundStreamOwned() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let models = ["foreground-stream", "multi-stream"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }

        service.sendMessage(
            messages: [Message(role: .user, content: "Foreground")],
            model: models[0],
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let foreground = await server.exchange(at: 0)
        foreground.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        let multiCompleted = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Multi")],
            model: models[1],
            stream: true,
            isMultiModelRequest: true,
            onChunk: { _ in },
            onComplete: { multiCompleted.signal() },
            onError: { _ in }
        )
        let multi = await server.exchange(at: 1)
        multi.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        multi.send(Data("data: [DONE]\n\n".utf8))
        multi.finish()

        let didComplete = await multiCompleted.wait(timeout: .seconds(2))
        #expect(didComplete)

        service.cancelCurrentRequest()
        let foregroundStopped = await foreground.waitUntilStopped()
        #expect(foregroundStopped)
    }

    @Test("Stream retry rechecks ownership after waiting", .timeLimit(.minutes(1)))
    func streamRetryRechecksOwnershipAfterWaiting() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let retryStarted = FlightTestSignal()
        let releaseRetry = FlightTestSignal()
        let staleRetryRejected = FlightTestSignal()
        let service = AIService(
            urlSession: URLSession(configuration: config),
            retryDelay: { _, _ in
                retryStarted.signal()
                await releaseRetry.wait()
            },
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .streamRetry, !ownsFlight {
                    staleRetryRejected.signal()
                }
            }
        )
        let models = ["retry-first", "retry-replacement"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }

        service.sendMessage(
            messages: [Message(role: .user, content: "First")],
            model: models[0],
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let first = await server.exchange(at: 0)
        first.fail(URLError(.networkConnectionLost))
        let didStartRetry = await retryStarted.wait(timeout: .seconds(2))
        #expect(didStartRetry)

        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: models[1],
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let replacement = await server.exchange(at: 1)
        replacement.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        releaseRetry.signal()
        let rejectedStaleRetry = await staleRetryRejected.wait(timeout: .seconds(2))
        #expect(rejectedStaleRetry)
        #expect(server.requestCount == 2)

        service.cancelCurrentRequest()
        let replacementStopped = await replacement.waitUntilStopped()
        #expect(replacementStopped)
    }

    @Test(
        "Stale data completion is suppressed and preserves the replacement handle",
        arguments: DataFlightVariant.allCases
    )
    func staleDataCompletionIsSuppressed(variant: DataFlightVariant) async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let staleCallbackProcessed = FlightTestSignal()
        let service = AIService(
            urlSession: URLSession(configuration: config),
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .dataCallback, !ownsFlight {
                    staleCallbackProcessed.signal()
                }
            }
        )
        let model = variant.model
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"
        service.modelEndpointTypes[model] = variant.endpointType

        let staleChunks = FlightTestBox("")
        let staleCompleted = FlightTestBox(false)
        service.sendMessage(
            messages: [Message(role: .user, content: "First")],
            model: model,
            stream: false,
            onChunk: { staleChunks.value += $0 },
            onComplete: { staleCompleted.value = true },
            onError: { _ in }
        )
        let first = await server.exchange(at: 0)
        first.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        first.send(variant.responseData)
        first.finish()

        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: model,
            stream: false,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let replacement = await server.exchange(at: 1)

        let rejectedStaleCallback = await staleCallbackProcessed.wait(timeout: .seconds(2))
        #expect(rejectedStaleCallback)
        #expect(staleChunks.value.isEmpty)
        #expect(!staleCompleted.value)

        service.cancelCurrentRequest()
        let replacementStopped = await replacement.waitUntilStopped()
        #expect(replacementStopped)
    }

    @Test(
        "Data retry rechecks ownership after waiting",
        arguments: DataFlightVariant.allCases
    )
    func dataRetryRechecksOwnershipAfterWaiting(variant: DataFlightVariant) async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let retryStarted = FlightTestSignal()
        let releaseRetry = FlightTestSignal()
        let staleRetryRejected = FlightTestSignal()
        let service = AIService(
            urlSession: URLSession(configuration: config),
            retryDelay: { _, _ in
                retryStarted.signal()
                await releaseRetry.wait()
            },
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .dataRetry, !ownsFlight {
                    staleRetryRejected.signal()
                }
            }
        )
        let model = variant.model
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"
        service.modelEndpointTypes[model] = variant.endpointType

        service.sendMessage(
            messages: [Message(role: .user, content: "First")],
            model: model,
            stream: false,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let first = await server.exchange(at: 0)
        first.fail(URLError(.networkConnectionLost))
        let didStartRetry = await retryStarted.wait(timeout: .seconds(2))
        #expect(didStartRetry)

        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: model,
            stream: false,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )
        let replacement = await server.exchange(at: 1)

        releaseRetry.signal()
        let rejectedStaleRetry = await staleRetryRejected.wait(timeout: .seconds(2))
        #expect(rejectedStaleRetry)
        #expect(server.requestCount == 2)

        service.cancelCurrentRequest()
        let replacementStopped = await replacement.waitUntilStopped()
        #expect(replacementStopped)
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

    @Test("Stale Anthropic callbacks cannot clear or deliver into a replacement", .timeLimit(.minutes(1)))
    func staleAnthropicCallbacksCannotClearOrDeliverIntoReplacement() async throws {
        let factory = FlightTestAnthropicProviderFactory()
        let staleTerminalProcessed = FlightTestSignal()
        let service = AIService(
            anthropicProviderFactory: { _ in factory.makeProvider() },
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .anthropicTerminal, !ownsFlight {
                    staleTerminalProcessed.signal()
                }
            }
        )
        let model = "claude-flight"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .anthropic
        service.modelAPIKeys[model] = "sk-ant-unit-test"

        let staleChunks = FlightTestBox("")
        let staleReasoning = FlightTestBox("")
        let staleTools = FlightTestBox([String]())
        let staleCompleted = FlightTestBox(false)
        let staleErrors = FlightTestBox(0)
        service.sendMessage(
            messages: [Message(role: .user, content: "First")],
            model: model,
            stream: true,
            onChunk: { staleChunks.value += $0 },
            onComplete: { staleCompleted.value = true },
            onError: { _ in staleErrors.value += 1 },
            onToolCallRequested: { _, name, _ in staleTools.update { $0.append(name) } },
            onReasoning: { staleReasoning.value += $0 }
        )

        let currentChunk = FlightTestBox("")
        let currentChunkReceived = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: model,
            stream: true,
            onChunk: {
                currentChunk.value += $0
                currentChunkReceived.signal()
            },
            onComplete: {},
            onError: { _ in }
        )

        #expect(factory.providers.count == 2)
        let stale = try #require(factory.providers.first)
        let current = try #require(factory.providers.last)
        stale.emitChunk("stale chunk")
        stale.emitReasoning("stale reasoning")
        stale.emitToolRequest(name: "stale_tool")
        stale.complete()
        stale.fail(URLError(.badServerResponse))

        let rejectedStaleTerminal = await staleTerminalProcessed.wait(timeout: .seconds(2))
        #expect(rejectedStaleTerminal)
        current.emitChunk("current chunk")
        let deliveredCurrentChunk = await currentChunkReceived.wait(timeout: .seconds(2))
        #expect(deliveredCurrentChunk)
        #expect(staleChunks.value.isEmpty)
        #expect(staleReasoning.value.isEmpty)
        #expect(staleTools.value.isEmpty)
        #expect(!staleCompleted.value)
        #expect(staleErrors.value == 0)
        #expect(currentChunk.value == "current chunk")

        service.cancelCurrentRequest()
        #expect(current.isCancelled)
    }

    @Test("Anthropic foreground and per-model multi handles remain independent", .timeLimit(.minutes(1)))
    func anthropicForegroundAndPerModelMultiHandlesRemainIndependent() async {
        let factory = FlightTestAnthropicProviderFactory()
        let service = AIService(anthropicProviderFactory: { _ in factory.makeProvider() })
        let models = ["claude-foreground", "claude-multi-a", "claude-multi-b"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-unit-test"
        }

        service.sendMessage(
            messages: [Message(role: .user, content: "Foreground")],
            model: models[0],
            stream: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )

        let firstMultiCompleted = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Multi A")],
            model: models[1],
            stream: true,
            isMultiModelRequest: true,
            onChunk: { _ in },
            onComplete: { firstMultiCompleted.signal() },
            onError: { _ in }
        )
        service.sendMessage(
            messages: [Message(role: .user, content: "Multi B")],
            model: models[2],
            stream: true,
            isMultiModelRequest: true,
            onChunk: { _ in },
            onComplete: {},
            onError: { _ in }
        )

        #expect(factory.providers.count == 3)
        let foreground = factory.providers[0]
        let completedMulti = factory.providers[1]
        let activeMulti = factory.providers[2]
        completedMulti.complete()
        let didCompleteMulti = await firstMultiCompleted.wait(timeout: .seconds(2))
        #expect(didCompleteMulti)

        service.cancelCurrentRequest()
        #expect(foreground.isCancelled)
        #expect(activeMulti.isCancelled)
        #expect(!completedMulti.isCancelled)
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

// swiftlint:enable type_body_length

enum DataFlightVariant: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case chatCompletions
    case responses

    var model: String {
        switch self {
        case .chatCompletions:
            "data-chat"
        case .responses:
            "data-responses"
        }
    }

    var endpointType: APIEndpointType {
        switch self {
        case .chatCompletions:
            .chatCompletions
        case .responses:
            .responses
        }
    }

    var responseData: Data {
        switch self {
        case .chatCompletions:
            Data("{\"choices\":[{\"message\":{\"content\":\"stale\"}}]}".utf8)
        case .responses:
            Data("{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"stale\"}]}]}".utf8)
        }
    }

    var testDescription: String {
        rawValue
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

final class ResultHolder: @unchecked Sendable {
    var value = ""
}

final class DataHolder: @unchecked Sendable {
    var value = Data()
}

final class ErrorHolder: @unchecked Sendable {
    var error: Error?
}
