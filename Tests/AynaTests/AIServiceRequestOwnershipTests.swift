@testable import Ayna
import Foundation
import Testing

extension AIServiceGlobalStateTests {
    @Suite("AIService Request Ownership Tests", .tags(.networking, .async), .serialized)
    @MainActor
    struct AIServiceRequestOwnershipTests {
        private let defaults: UserDefaults

        init() {
            guard let suite = UserDefaults(suiteName: "AIServiceRequestOwnershipTests") else {
                fatalError("Failed to create UserDefaults suite for AIServiceRequestOwnershipTests")
            }
            defaults = suite
            defaults.removePersistentDomain(forName: "AIServiceRequestOwnershipTests")
            AppPreferences.use(defaults)
            AIService.keychain = InMemoryKeychainStorage()
        }

        @Test(.timeLimit(.minutes(1)))
        func `anthropic completion releases ownership before callback starts replacement`() async throws {
            let factory = TerminalAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in
                    factory.makeProvider()
                }
            )
            let model = "claude-terminal-ownership"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-unit-test"
            let firstOwner = UUID()
            let secondOwner = UUID()
            let cancellationCounter = TerminalCallbackCounter()
            let secondStarted = TestCallbackWaiter()

            service.sendMessage(
                messages: [Message(role: .user, content: "First request")],
                model: model,
                requestOwnerID: firstOwner,
                onChunk: { _ in },
                onComplete: {
                    MainActor.assumeIsolated {
                        service.sendMessage(
                            messages: [Message(role: .user, content: "Replacement request")],
                            model: model,
                            requestOwnerID: secondOwner,
                            onChunk: { _ in },
                            onComplete: {},
                            onError: { _ in }
                        )
                        secondStarted.signal()
                    }
                },
                onError: { error in
                    if error is CancellationError {
                        cancellationCounter.increment()
                    }
                }
            )
            let firstProvider = try #require(factory.providers.first)

            firstProvider.complete()
            await secondStarted.wait()

            #expect(factory.providers.count == 2)
            #expect(cancellationCounter.value == 0)
            #expect(!firstProvider.isCancelled)
            service.cancelCurrentRequest()
        }

        @Test(.timeLimit(.minutes(1)))
        func `replaced Anthropic request suppresses queued progress callbacks`() async throws {
            let factory = TerminalAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in
                    factory.makeProvider()
                }
            )
            let model = "claude-progress-ownership"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-unit-test"
            let staleText = LockedStringAccumulator()
            let staleReasoning = LockedStringAccumulator()
            let staleToolCalls = TerminalCallbackCounter()

            service.sendMessage(
                messages: [Message(role: .user, content: "First request")],
                model: model,
                requestOwnerID: UUID(),
                onChunk: { staleText.append($0) },
                onComplete: {},
                onError: { _ in },
                onToolCallRequested: { _, _, _ in staleToolCalls.increment() },
                onReasoning: { staleReasoning.append($0) }
            )
            let firstProvider = try #require(factory.providers.first)
            firstProvider.emitChunk("stale chunk")
            firstProvider.emitReasoning("stale reasoning")
            firstProvider.emitToolCall()

            service.sendMessage(
                messages: [Message(role: .user, content: "Replacement request")],
                model: model,
                requestOwnerID: UUID(),
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            for _ in 0 ..< 20 {
                await Task.yield()
            }

            #expect(firstProvider.isCancelled)
            #expect(staleText.value.isEmpty)
            #expect(staleReasoning.value.isEmpty)
            #expect(staleToolCalls.value == 0)
            service.cancelCurrentRequest()
        }

        @Test(.timeLimit(.minutes(1)))
        func `request build failure releases ownership before the next request`() async {
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                requestBuildOverride: { _ in nil }
            )
            let model = "gpt-build-failure-ownership"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
            let firstOwner = UUID()
            let secondOwner = UUID()
            let firstFailure = TestCallbackWaiter()
            let secondFailure = TestCallbackWaiter()
            let staleCancellationCounter = TerminalCallbackCounter()

            service.sendMessage(
                messages: [Message(role: .user, content: "First invalid request")],
                model: model,
                requestOwnerID: firstOwner,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    if error is CancellationError {
                        staleCancellationCounter.increment()
                    } else {
                        firstFailure.signal()
                    }
                }
            )
            await firstFailure.wait()

            service.sendMessage(
                messages: [Message(role: .user, content: "Second invalid request")],
                model: model,
                requestOwnerID: secondOwner,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    if !(error is CancellationError) {
                        secondFailure.signal()
                    }
                }
            )
            await secondFailure.wait()

            #expect(staleCancellationCounter.value == 0)
        }

        @Test(.timeLimit(.minutes(1)))
        func `same owner replacement cancels work from another provider family`() async throws {
            let factory = TerminalAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in
                    factory.makeProvider()
                },
                requestBuildOverride: { _ in nil }
            )
            let anthropicModel = "claude-same-owner"
            let openAIModel = "gpt-same-owner"
            let owner = UUID()
            service.customModels = [anthropicModel, openAIModel]
            service.modelProviders[anthropicModel] = .anthropic
            service.modelProviders[openAIModel] = .openai
            service.modelAPIKeys[anthropicModel] = "sk-ant-unit-test"
            service.modelAPIKeys[openAIModel] = "sk-unit-test"
            let replacementFailed = TestCallbackWaiter()

            service.sendMessage(
                messages: [Message(role: .user, content: "Anthropic")],
                model: anthropicModel,
                requestOwnerID: owner,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            let anthropicProvider = try #require(factory.providers.first)

            service.sendMessage(
                messages: [Message(role: .user, content: "OpenAI replacement")],
                model: openAIModel,
                requestOwnerID: owner,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    if !(error is CancellationError) {
                        replacementFailed.signal()
                    }
                }
            )
            await replacementFailed.wait()

            #expect(anthropicProvider.isCancelled)
        }

        @Test(.timeLimit(.minutes(1)))
        func `missing Anthropic model key does not retain tracked ownership`() async throws {
            let factory = TerminalAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in
                    factory.makeProvider()
                }
            )
            let missingKeyModel = "claude-missing-exact-key"
            let configuredModel = "claude-configured-exact-key"
            service.customModels = [missingKeyModel, configuredModel]
            service.modelProviders[missingKeyModel] = .anthropic
            service.modelProviders[configuredModel] = .anthropic
            service.modelAPIKeys[configuredModel] = "sk-ant-unit-test"
            let initialFailure = TestCallbackWaiter()
            let staleCancellationCounter = TerminalCallbackCounter()

            service.sendMessage(
                messages: [Message(role: .user, content: "Missing key")],
                model: missingKeyModel,
                requestOwnerID: UUID(),
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    if error is CancellationError {
                        staleCancellationCounter.increment()
                    } else {
                        initialFailure.signal()
                    }
                }
            )
            await initialFailure.wait()

            let configuredOwner = UUID()
            service.sendMessage(
                messages: [Message(role: .user, content: "Configured key")],
                model: configuredModel,
                requestOwnerID: configuredOwner,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )

            #expect(staleCancellationCounter.value == 0)
            #expect(factory.providers.count == 1)
            let provider = try #require(factory.providers.first)
            service.cancelCurrentRequest(ifOwnedBy: configuredOwner)
            #expect(provider.isCancelled)
        }

        @Test(.timeLimit(.minutes(1)))
        func `reentrant cancellation replacement keeps the newest request`() throws {
            let factory = TerminalAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in
                    factory.makeProvider()
                }
            )
            let model = "claude-reentrant-ownership"
            let firstOwner = UUID()
            let outerReplacementOwner = UUID()
            let reentrantOwner = UUID()
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-unit-test"
            let outerCancellationCounter = TerminalCallbackCounter()

            service.sendMessage(
                messages: [Message(role: .user, content: "Original request")],
                model: model,
                requestOwnerID: firstOwner,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    guard error is CancellationError else { return }
                    MainActor.assumeIsolated {
                        service.sendMessage(
                            messages: [Message(role: .user, content: "Reentrant request")],
                            model: model,
                            requestOwnerID: reentrantOwner,
                            onChunk: { _ in },
                            onComplete: {},
                            onError: { _ in }
                        )
                    }
                }
            )
            let originalProvider = try #require(factory.providers.first)

            service.sendMessage(
                messages: [Message(role: .user, content: "Outer replacement")],
                model: model,
                requestOwnerID: outerReplacementOwner,
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    if error is CancellationError {
                        outerCancellationCounter.increment()
                    }
                }
            )

            #expect(factory.providers.count == 2)
            #expect(originalProvider.isCancelled)
            #expect(outerCancellationCounter.value == 1)
            let reentrantProvider = try #require(factory.providers.last)
            #expect(!reentrantProvider.isCancelled)

            service.cancelCurrentRequest(ifOwnedBy: outerReplacementOwner)
            #expect(!reentrantProvider.isCancelled)
            service.cancelCurrentRequest(ifOwnedBy: reentrantOwner)
            #expect(reentrantProvider.isCancelled)
        }

        @Test(.timeLimit(.minutes(1)))
        func `stolen provisional multi model ownership cancels every model`() throws {
            let factory = TerminalAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in
                    factory.makeProvider()
                }
            )
            let models = ["claude-provisional-a", "claude-provisional-b"]
            let provisionalOwner = UUID()
            let reentrantOwner = UUID()
            for model in models {
                service.customModels.append(model)
                service.modelProviders[model] = .anthropic
                service.modelAPIKeys[model] = "sk-ant-unit-test"
            }
            service.selectedModel = models[0]
            let cancelledModels = LockedStringSet()

            service.sendMessage(
                messages: [Message(role: .user, content: "Original request")],
                model: models[0],
                requestOwnerID: UUID(),
                onChunk: { _ in },
                onComplete: {},
                onError: { error in
                    guard error is CancellationError else { return }
                    MainActor.assumeIsolated {
                        service.sendMessage(
                            messages: [Message(role: .user, content: "Reentrant request")],
                            model: models[0],
                            requestOwnerID: reentrantOwner,
                            onChunk: { _ in },
                            onComplete: {},
                            onError: { _ in }
                        )
                    }
                }
            )
            let originalProvider = try #require(factory.providers.first)

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Provisional request")],
                models: models,
                requestOwnerID: provisionalOwner,
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { model, error in
                    if error is CancellationError {
                        cancelledModels.insert(model)
                    }
                }
            )

            #expect(originalProvider.isCancelled)
            #expect(cancelledModels.value == Set(models))
            #expect(factory.providers.count == 2)
            let reentrantProvider = try #require(factory.providers.last)
            #expect(!reentrantProvider.isCancelled)
            service.cancelCurrentRequest(ifOwnedBy: provisionalOwner)
            #expect(!reentrantProvider.isCancelled)
            service.cancelCurrentRequest(ifOwnedBy: reentrantOwner)
            #expect(reentrantProvider.isCancelled)
        }

        @Test(.timeLimit(.minutes(1)))
        func `multi model cancellation callback replacement survives teardown`() async throws {
            let factory = TerminalAnthropicProviderFactory()
            let service = AIService(
                urlSession: URLSession(configuration: .ephemeral),
                anthropicProviderFactory: { _ in
                    factory.makeProvider()
                }
            )
            let model = "claude-multi-model-reentrant"
            let replacementOwner = UUID()
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .anthropic
            service.modelAPIKeys[model] = "sk-ant-unit-test"

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Original multi-model request")],
                models: [model],
                requestOwnerID: UUID(),
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, error in
                    guard error is CancellationError else { return }
                    MainActor.assumeIsolated {
                        service.sendMessage(
                            messages: [Message(role: .user, content: "Replacement request")],
                            model: model,
                            requestOwnerID: replacementOwner,
                            onChunk: { _ in },
                            onComplete: {},
                            onError: { _ in }
                        )
                    }
                }
            )
            for _ in 0 ..< 1000 where factory.providers.isEmpty {
                await Task.yield()
            }
            let originalProvider = try #require(factory.providers.first)

            service.cancelCurrentRequest()

            #expect(factory.providers.count == 2)
            #expect(originalProvider.isCancelled)
            let replacementProvider = try #require(factory.providers.last)
            #expect(!replacementProvider.isCancelled)
            service.cancelCurrentRequest(ifOwnedBy: replacementOwner)
            #expect(replacementProvider.isCancelled)
        }

        #if !os(watchOS)
            @Test
            func `apple Intelligence ephemeral requests use distinct session keys`() {
                let firstRequestID = UUID()
                let secondRequestID = UUID()
                let conversationId = UUID()

                let firstEphemeralKey = AIService.appleIntelligenceSessionKey(
                    conversationId: nil,
                    requestID: firstRequestID
                )
                let secondEphemeralKey = AIService.appleIntelligenceSessionKey(
                    conversationId: nil,
                    requestID: secondRequestID
                )
                let persistentKey = AIService.appleIntelligenceSessionKey(
                    conversationId: conversationId,
                    requestID: firstRequestID
                )

                #expect(firstEphemeralKey != secondEphemeralKey)
                #expect(persistentKey == conversationId.uuidString)
            }
        #endif

        @Test(.timeLimit(.minutes(1)))
        func `responses retry preserves tracked ownership`() async {
            RetryingResponsesURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RetryingResponsesURLProtocol.self]
            let service = AIService(
                urlSession: URLSession(configuration: configuration),
                streamRetryDelayOperation: { _, _ in }
            )
            let model = "gpt-responses-retry"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelEndpointTypes[model] = .responses
            service.modelAPIKeys[model] = "sk-unit-test"
            let completion = TestCallbackWaiter()
            let cancellationCounter = TerminalCallbackCounter()
            let receivedText = LockedStringAccumulator()

            service.sendMessage(
                messages: [Message(role: .user, content: "Retry this response")],
                model: model,
                stream: false,
                requestOwnerID: UUID(),
                onChunk: { chunk in
                    receivedText.append(chunk)
                },
                onComplete: {
                    completion.signal()
                },
                onError: { error in
                    if error is CancellationError {
                        cancellationCounter.increment()
                    }
                }
            )
            await completion.wait()

            #expect(RetryingResponsesURLProtocol.requestCount == 2)
            #expect(receivedText.value == "retried")
            #expect(cancellationCounter.value == 0)
        }

        @Test(.timeLimit(.minutes(1)))
        func `multi model Responses children retain ownership until all complete`() async {
            MultiResponsesURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MultiResponsesURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            let models = ["gpt-responses-a", "gpt-responses-b"]
            for model in models {
                service.customModels.append(model)
                service.modelProviders[model] = .openai
                service.modelEndpointTypes[model] = .responses
                service.modelAPIKeys[model] = "sk-unit-test"
            }
            let completedModels = LockedStringSet()
            let allComplete = TestCallbackWaiter()

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Compare")],
                models: models,
                requestOwnerID: UUID(),
                onChunk: { _, _ in },
                onModelComplete: { completedModels.insert($0) },
                onAllComplete: { allComplete.signal() },
                onError: { _, _ in }
            )
            await allComplete.wait()

            #expect(completedModels.value == Set(models))
            #expect(MultiResponsesURLProtocol.requestCount == models.count)
            #expect(!MultiResponsesURLProtocol.requestsContainTools)
        }

        @Test(.timeLimit(.minutes(1)))
        func `same owner multi model Responses replacement suppresses remaining stale output`() async {
            ReentrantMultiResponsesURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReentrantMultiResponsesURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            let model = "gpt-responses-reentrant"
            let owner = UUID()
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelEndpointTypes[model] = .responses
            service.modelAPIKeys[model] = "sk-unit-test"
            let receivedText = LockedStringAccumulator()
            let replacementStarted = TerminalCallbackCounter()
            let replacementComplete = TestCallbackWaiter()

            service.sendToMultipleModels(
                messages: [Message(role: .user, content: "Original")],
                models: [model],
                requestOwnerID: owner,
                onChunk: { _, chunk in
                    receivedText.append(chunk)
                    guard chunk == "old-1", replacementStarted.value == 0 else { return }
                    replacementStarted.increment()
                    MainActor.assumeIsolated {
                        service.sendToMultipleModels(
                            messages: [Message(role: .user, content: "Replacement")],
                            models: [model],
                            requestOwnerID: owner,
                            onChunk: { _, replacementChunk in
                                receivedText.append(replacementChunk)
                            },
                            onModelComplete: { _ in },
                            onAllComplete: { replacementComplete.signal() },
                            onError: { _, error in
                                if !(error is CancellationError) {
                                    Issue.record("Unexpected replacement error: \(error)")
                                }
                            }
                        )
                    }
                },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, _ in }
            )
            await replacementComplete.wait()
            await Task.yield()

            #expect(receivedText.value == "old-1new")
            #expect(ReentrantMultiResponsesURLProtocol.requestCount == 2)
        }

        @Test(.timeLimit(.minutes(1)))
        func `stream cancellation from a final chunk suppresses stale completion`() async {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TerminalStreamURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            let model = "gpt-stream-terminal-ownership"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
            let cancellation = TestCallbackWaiter()
            let chunkCounter = TerminalCallbackCounter()
            let completionCounter = TerminalCallbackCounter()

            service.sendMessage(
                messages: [Message(role: .user, content: "Cancel from final chunk")],
                model: model,
                requestOwnerID: UUID(),
                onChunk: { _ in
                    chunkCounter.increment()
                    MainActor.assumeIsolated {
                        service.cancelCurrentRequest()
                    }
                },
                onComplete: {
                    completionCounter.increment()
                },
                onError: { error in
                    if error is CancellationError {
                        cancellation.signal()
                    }
                }
            )
            await cancellation.wait()
            await Task.yield()

            #expect(chunkCounter.value == 1)
            #expect(completionCounter.value == 0)
        }

        @Test(.timeLimit(.minutes(1)))
        func `untracked stream completion preserves foreground cancellation ownership`() async {
            let probe = ConcurrentRequestProbe()
            ConcurrentOwnershipURLProtocol.probe = probe
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ConcurrentOwnershipURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            let foregroundModel = "gpt-foreground-owner"
            let backgroundModel = "gpt-background-untracked"
            service.customModels = [foregroundModel, backgroundModel]
            service.modelProviders[foregroundModel] = .openai
            service.modelProviders[backgroundModel] = .openai
            service.modelAPIKeys[foregroundModel] = "sk-unit-test"
            service.modelAPIKeys[backgroundModel] = "sk-unit-test"
            service.modelEndpoints[foregroundModel] = "https://foreground.test/v1/chat/completions"
            service.modelEndpoints[backgroundModel] = "https://background.test/v1/chat/completions"
            let foregroundOwner = UUID()
            let backgroundCompleted = TestCallbackWaiter()

            service.sendMessage(
                messages: [Message(role: .user, content: "Foreground")],
                model: foregroundModel,
                stream: false,
                requestOwnerID: foregroundOwner,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in }
            )
            await probe.waitForForegroundStart()

            service.sendMessage(
                messages: [Message(role: .user, content: "Background")],
                model: backgroundModel,
                stream: true,
                tracksCurrentRequest: false,
                onChunk: { _ in },
                onComplete: {
                    backgroundCompleted.signal()
                },
                onError: { _ in }
            )
            await backgroundCompleted.wait()

            service.cancelCurrentRequest(ifOwnedBy: foregroundOwner)
            await probe.waitForForegroundStop()
        }
    }
}

@MainActor
private final class TerminalAnthropicProviderFactory {
    private(set) var providers: [TerminalAnthropicProvider] = []

    func makeProvider() -> any AIProviderProtocol {
        let provider = TerminalAnthropicProvider()
        providers.append(provider)
        return provider
    }
}

@MainActor
private final class TerminalAnthropicProvider: AIProviderProtocol, @unchecked Sendable {
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

    func emitChunk(_ chunk: String) {
        callbacks?.onChunk(chunk)
    }

    func emitReasoning(_ reasoning: String) {
        callbacks?.onReasoning?(reasoning)
    }

    func emitToolCall() {
        callbacks?.onToolCallRequested?("call-stale", "web_search", ["query": "stale"])
    }
}

private final class TerminalCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private final class LockedStringAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    var value: String {
        lock.withLock { text }
    }

    func append(_ chunk: String) {
        lock.withLock {
            text += chunk
        }
    }
}

private final class RetryingResponsesURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset() {
        lock.withLock {
            count = 0
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let attempt = Self.lock.withLock { () -> Int in
            Self.count += 1
            return Self.count
        }
        if attempt == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data(
            #"{"output":[{"type":"message","content":[{"type":"output_text","text":"retried"}]}]}"#.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MultiResponsesURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0
    private nonisolated(unsafe) static var containsTools = false

    static var requestCount: Int {
        lock.withLock { count }
    }

    static var requestsContainTools: Bool {
        lock.withLock { containsTools }
    }

    static func reset() {
        lock.withLock {
            count = 0
            containsTools = false
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestContainsTools = request.httpBody.flatMap { data in
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }?["tools"] != nil
        Self.lock.withLock {
            Self.count += 1
            Self.containsTools = Self.containsTools || requestContainsTools
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data(
            #"{"output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ReentrantMultiResponsesURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset() {
        lock.withLock { count = 0 }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestNumber = Self.lock.withLock { () -> Int in
            Self.count += 1
            return Self.count
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = if requestNumber == 1 {
            #"{"output":[{"type":"message","content":[{"type":"output_text","text":"old-1"},{"type":"output_text","text":"old-2"}]}]}"#
        } else {
            #"{"output":[{"type":"message","content":[{"type":"output_text","text":"new"}]}]}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LockedStringSet: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<String> = []

    var value: Set<String> {
        lock.withLock { storage }
    }

    func insert(_ value: String) {
        _ = lock.withLock { storage.insert(value) }
    }
}

private final class TerminalStreamURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let data = Data(
            """
            data: {"choices":[{"delta":{"content":"done"}}]}

            data: [DONE]

            """.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ConcurrentRequestProbe: @unchecked Sendable {
    private let foregroundStarted = TestCallbackWaiter()
    private let foregroundStopped = TestCallbackWaiter()

    func signalForegroundStart() {
        foregroundStarted.signal()
    }

    func waitForForegroundStart() async {
        await foregroundStarted.wait()
    }

    func signalForegroundStop() {
        foregroundStopped.signal()
    }

    func waitForForegroundStop() async {
        await foregroundStopped.wait()
    }
}

private final class ConcurrentOwnershipURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var probe: ConcurrentRequestProbe?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if request.url?.host == "foreground.test" {
            Self.probe?.signalForegroundStart()
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let data = Data("data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\ndata: [DONE]\n\n".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if request.url?.host == "foreground.test" {
            Self.probe?.signalForegroundStop()
        }
    }
}
