@testable import Ayna
import Foundation
import Testing

// swiftformat:disable swiftTestingTestCaseNames

extension AIServiceTests {
    @Test("A lone short streaming chunk is delivered before the terminal event", .timeLimit(.minutes(1)))
    func loneShortStreamingChunkDeliveredBeforeTerminalEvent() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let model = "short-stream-chunk"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"

        let received = FlightTestBox("")
        let chunkDelivered = FlightTestSignal()
        let request = service.sendMessage(
            messages: [Message(role: .user, content: "Stream")],
            model: model,
            stream: true,
            onChunk: {
                received.value += $0
                chunkDelivered.signal()
            },
            onComplete: {},
            onError: { error in Issue.record("Unexpected error: \(error)") }
        )

        let exchange = await server.exchange(at: 0)
        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        exchange.send(Data("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n".utf8))

        #expect(await chunkDelivered.wait(timeout: .seconds(1)))
        #expect(received.value == "x")

        request.cancel()
        #expect(await exchange.waitUntilStopped(timeout: .seconds(1)))
    }

    @Test("A final SSE record without a newline is delivered", .timeLimit(.minutes(1)))
    func finalSSERecordWithoutNewlineIsDelivered() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let model = "unterminated-final-sse"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"

        let received = FlightTestBox("")
        let completed = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Stream")],
            model: model,
            stream: true,
            onChunk: { received.value += $0 },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") }
        )

        let exchange = await server.exchange(at: 0)
        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        exchange.send(Data("data: {\"choices\":[{\"delta\":{\"content\":\"tail\"}}]}".utf8))
        exchange.finish()

        #expect(await completed.wait(timeout: .seconds(1)))
        #expect(received.value == "tail")
    }

    @Test("Cancelling an owned streaming request stops callbacks", .timeLimit(.minutes(1)))
    func cancellingOwnedStreamingRequestStopsCallbacks() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let model = "owned-stream"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"

        let callbackReceived = FlightTestSignal()
        let request = service.sendMessage(
            messages: [Message(role: .user, content: "Cancel me")],
            model: model,
            stream: true,
            onChunk: { _ in callbackReceived.signal() },
            onComplete: { callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() }
        )

        let exchange = await server.exchange(at: 0)
        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        request.cancel()

        #expect(await exchange.waitUntilStopped(timeout: .seconds(1)))
        exchange.send(Data("data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\n".utf8))
        exchange.finish()
        #expect(await !(callbackReceived.wait(timeout: .milliseconds(100))))
    }

    @Test("A stale streaming handle cannot cancel its replacement", .timeLimit(.minutes(1)))
    func staleStreamingHandleCannotCancelReplacement() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let models = ["stale-stream", "replacement-stream"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }

        let staleCallbacks = FlightTestSignal()
        let staleRequest = service.sendMessage(
            messages: [Message(role: .user, content: "Stale")],
            model: models[0],
            stream: true,
            onChunk: { _ in staleCallbacks.signal() },
            onComplete: { staleCallbacks.signal() },
            onError: { _ in staleCallbacks.signal() }
        )
        let staleExchange = await server.exchange(at: 0)
        staleExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        let replacementChunk = FlightTestBox("")
        let replacementComplete = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: models[1],
            stream: true,
            onChunk: { replacementChunk.value += $0 },
            onComplete: { replacementComplete.signal() },
            onError: { _ in }
        )
        let replacementExchange = await server.exchange(at: 1)
        replacementExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        #expect(await staleExchange.waitUntilStopped(timeout: .seconds(1)))
        staleRequest.cancel()
        #expect(!replacementExchange.isStopped)

        replacementExchange.send(
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"replacement\"}}]}\n\n".utf8)
        )
        replacementExchange.send(Data("data: [DONE]\n\n".utf8))
        replacementExchange.finish()

        #expect(await replacementComplete.wait(timeout: .seconds(1)))
        #expect(replacementChunk.value == "replacement")
        #expect(await !(staleCallbacks.wait(timeout: .milliseconds(100))))
    }

    @Test("Synchronous simulator replacement fences stale and late callbacks")
    func synchronousSimulatorReplacementFencesStaleAndLateCallbacks() throws {
        let replacementCallbacks = FlightTestBox<AIServiceResponseSimulationCallbacks?>(nil)
        let service = AIService(responseSimulator: { messages, callbacks in
            let content = messages.last(where: { $0.role == .user })?.content
            if content == "First" {
                callbacks.onChunk("first")
                callbacks.onComplete()
                callbacks.onChunk("late-first")
            } else {
                replacementCallbacks.value = callbacks
            }
        })

        let firstChunks = FlightTestBox<[String]>([])
        let firstCompleted = FlightTestBox(false)
        let replacementChunks = FlightTestBox<[String]>([])
        let replacementCompleted = FlightTestBox(false)

        let staleRequest = service.sendMessage(
            messages: [Message(role: .user, content: "First")],
            model: "simulator-model",
            onChunk: { chunk in
                firstChunks.update { $0.append(chunk) }
                _ = MainActor.assumeIsolated {
                    service.sendMessage(
                        messages: [Message(role: .user, content: "Replacement")],
                        model: "simulator-model",
                        onChunk: { chunk in replacementChunks.update { $0.append(chunk) } },
                        onComplete: { replacementCompleted.value = true },
                        onError: { _ in }
                    )
                }
            },
            onComplete: { firstCompleted.value = true },
            onError: { _ in }
        )

        staleRequest.cancel()
        let callbacks = try #require(replacementCallbacks.value)
        callbacks.onChunk("replacement")
        callbacks.onComplete()

        #expect(firstChunks.value == ["first"])
        #expect(!firstCompleted.value)
        #expect(replacementChunks.value == ["replacement"])
        #expect(replacementCompleted.value)
    }

    @Test("Cancelling an owned Responses API request suppresses callbacks", .timeLimit(.minutes(1)))
    func cancellingOwnedResponsesAPIRequestSuppressesCallbacks() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let model = "owned-responses"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"
        service.modelEndpointTypes[model] = .responses

        let callbackReceived = FlightTestSignal()
        let request = service.sendMessage(
            messages: [Message(role: .user, content: "Cancel responses")],
            model: model,
            onChunk: { _ in callbackReceived.signal() },
            onComplete: { callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() }
        )

        let exchange = await server.exchange(at: 0)
        request.cancel()
        #expect(await exchange.waitUntilStopped(timeout: .seconds(1)))

        exchange.sendResponse(statusCode: 200)
        exchange.send(Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"late"}]}]}"#.utf8))
        exchange.finish()
        #expect(await !(callbackReceived.wait(timeout: .milliseconds(100))))
    }

    @Test("The original handle owns a non-stream retry", .timeLimit(.minutes(1)))
    func originalHandleOwnsNonStreamRetry() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let retryStarted = FlightTestSignal()
        let releaseRetry = FlightTestSignal()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(
            urlSession: URLSession(configuration: config),
            retryDelay: { _, _ in
                retryStarted.signal()
                await releaseRetry.wait()
            }
        )
        let model = "owned-retry"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"

        let callbackReceived = FlightTestSignal()
        let request = service.sendMessage(
            messages: [Message(role: .user, content: "Retry")],
            model: model,
            stream: false,
            onChunk: { _ in callbackReceived.signal() },
            onComplete: { callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() }
        )

        let firstExchange = await server.exchange(at: 0)
        firstExchange.fail(URLError(.networkConnectionLost))
        await retryStarted.wait()
        releaseRetry.signal()

        let retryExchange = await server.exchange(at: 1)
        request.cancel()
        #expect(await retryExchange.waitUntilStopped(timeout: .seconds(1)))
        #expect(await !(callbackReceived.wait(timeout: .milliseconds(100))))
    }

    @Test("Cancelling a non-stream request cancels and fences legacy tool execution", .timeLimit(.minutes(1)))
    func cancellingNonStreamRequestCancelsAndFencesLegacyToolExecution() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let model = "owned-nonstream-tool"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"

        let toolStarted = FlightTestSignal()
        let releaseTool = FlightTestSignal()
        let toolReturned = FlightTestSignal()
        let toolWasCancelled = FlightTestBox(false)
        let callbackReceived = FlightTestSignal()
        let request = service.sendMessage(
            messages: [Message(role: .user, content: "Run tool")],
            model: model,
            stream: false,
            onChunk: { _ in callbackReceived.signal() },
            onComplete: { callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() },
            onToolCall: { _, _, _ in
                toolStarted.signal()
                await releaseTool.wait()
                toolWasCancelled.value = Task.isCancelled
                toolReturned.signal()
                return "late tool result"
            }
        )

        let exchange = await server.exchange(at: 0)
        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(legacyToolCallResponseData)
        exchange.finish()
        #expect(await toolStarted.wait(timeout: .seconds(1)))

        request.cancel()
        releaseTool.signal()

        #expect(await toolReturned.wait(timeout: .seconds(1)))
        #expect(toolWasCancelled.value)
        #expect(await !(callbackReceived.wait(timeout: .milliseconds(100))))
    }

    @Test("Replacing a non-stream tool request cancels and fences stale callbacks", .timeLimit(.minutes(1)))
    func replacingNonStreamToolRequestCancelsAndFencesStaleCallbacks() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let models = ["stale-nonstream-tool", "replacement-nonstream"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }

        let toolStarted = FlightTestSignal()
        let releaseTool = FlightTestSignal()
        let toolReturned = FlightTestSignal()
        let toolWasCancelled = FlightTestBox(false)
        let staleChunks = FlightTestBox<[String]>([])
        let staleCompleted = FlightTestBox(false)
        service.sendMessage(
            messages: [Message(role: .user, content: "Stale tool")],
            model: models[0],
            stream: false,
            onChunk: { chunk in staleChunks.update { $0.append(chunk) } },
            onComplete: { staleCompleted.value = true },
            onError: { _ in },
            onToolCall: { _, _, _ in
                toolStarted.signal()
                await releaseTool.wait()
                toolWasCancelled.value = Task.isCancelled
                toolReturned.signal()
                return "stale tool result"
            }
        )

        let staleExchange = await server.exchange(at: 0)
        staleExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        staleExchange.send(legacyToolCallResponseData)
        staleExchange.finish()
        #expect(await toolStarted.wait(timeout: .seconds(1)))

        let replacementChunks = FlightTestBox<[String]>([])
        let replacementComplete = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: models[1],
            stream: false,
            onChunk: { chunk in replacementChunks.update { $0.append(chunk) } },
            onComplete: { replacementComplete.signal() },
            onError: { error in Issue.record("Unexpected replacement error: \(error)") }
        )
        let replacementExchange = await server.exchange(at: 1)
        replacementExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        replacementExchange.send(Data("{\"choices\":[{\"message\":{\"content\":\"replacement\"}}]}".utf8))
        replacementExchange.finish()

        #expect(await replacementComplete.wait(timeout: .seconds(1)))
        releaseTool.signal()
        #expect(await toolReturned.wait(timeout: .seconds(1)))
        #expect(toolWasCancelled.value)
        #expect(staleChunks.value.isEmpty)
        #expect(!staleCompleted.value)
        #expect(replacementChunks.value == ["replacement"])
    }

    @Test("Anthropic handles cancel and fence only their owned request", .timeLimit(.minutes(1)))
    func anthropicHandlesCancelAndFenceOnlyOwnedRequest() async throws {
        let factory = FlightTestAnthropicProviderFactory()
        let service = AIService(anthropicProviderFactory: { _ in factory.makeProvider() })
        let model = "owned-anthropic"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .anthropic
        service.modelAPIKeys[model] = "sk-ant-unit-test"

        let staleCallbacks = FlightTestSignal()
        let staleRequest = service.sendMessage(
            messages: [Message(role: .user, content: "First")],
            model: model,
            onChunk: { _ in staleCallbacks.signal() },
            onComplete: { staleCallbacks.signal() },
            onError: { _ in staleCallbacks.signal() }
        )
        let staleProvider = try #require(factory.providers.first)

        staleRequest.cancel()
        #expect(staleProvider.isCancelled)
        staleProvider.emitChunk("late")
        staleProvider.complete()
        #expect(await !(staleCallbacks.wait(timeout: .milliseconds(100))))

        let replacementChunk = FlightTestBox("")
        let replacementComplete = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Replacement")],
            model: model,
            onChunk: { replacementChunk.value += $0 },
            onComplete: { replacementComplete.signal() },
            onError: { _ in }
        )
        let replacementProvider = try #require(factory.providers.last)

        staleRequest.cancel()
        #expect(!replacementProvider.isCancelled)
        replacementProvider.emitChunk("replacement")
        replacementProvider.complete()

        #expect(await replacementComplete.wait(timeout: .seconds(1)))
        #expect(replacementChunk.value == "replacement")
    }

    #if !os(watchOS)
        @Test("Apple Intelligence handles cancel and fence only their owned request", .timeLimit(.minutes(1)))
        func appleIntelligenceHandlesCancelAndFenceOnlyOwnedRequest() async throws {
            let appleService = FlightTestAppleIntelligenceService()
            let service = AIService(appleIntelligenceService: appleService)
            let model = "owned-apple"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .appleIntelligence

            let staleCallbacks = FlightTestSignal()
            let staleRequest = service.sendMessage(
                messages: [Message(role: .user, content: "First")],
                model: model,
                onChunk: { _ in staleCallbacks.signal() },
                onComplete: { staleCallbacks.signal() },
                onError: { _ in staleCallbacks.signal() }
            )
            let staleAppleRequest = try #require(await appleService.request(at: 0))

            staleRequest.cancel()
            #expect(await staleAppleRequest.cancelled.wait(timeout: .seconds(1)))
            staleAppleRequest.emitChunk("late")
            staleAppleRequest.complete()
            #expect(await !(staleCallbacks.wait(timeout: .milliseconds(100))))

            let replacementChunk = FlightTestBox("")
            let replacementComplete = FlightTestSignal()
            service.sendMessage(
                messages: [Message(role: .user, content: "Replacement")],
                model: model,
                onChunk: { replacementChunk.value += $0 },
                onComplete: { replacementComplete.signal() },
                onError: { _ in }
            )
            let replacementAppleRequest = try #require(await appleService.request(at: 1))

            staleRequest.cancel()
            #expect(!replacementAppleRequest.cancelled.isSignaled)
            replacementAppleRequest.emitChunk("replacement")
            replacementAppleRequest.complete()

            #expect(await replacementComplete.wait(timeout: .seconds(1)))
            #expect(replacementChunk.value == "replacement")
        }
    #endif

    private var legacyToolCallResponseData: Data {
        Data(
            #"{"choices":[{"message":{"tool_calls":[{"id":"tool-call","function":{"name":"test_tool","arguments":"{}"}}]}}]}"#.utf8
        )
    }
}
