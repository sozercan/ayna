@testable import Ayna
import Foundation
import Testing

#if os(iOS)
    @Suite("IOSChatViewModel Streaming Coalescing Tests", .tags(.viewModel, .async), .serialized)
    @MainActor
    struct IOSChatViewModelStreamingCoalescingTests {
        private struct Fixture {
            let viewModel: IOSChatViewModel
            let manager: ConversationManager
            let conversationId: UUID
            let messageId: UUID
            let responseGroupId: UUID
            let model: String
            let messageIds: [String: UUID]
        }

        private let defaults: UserDefaults

        init() {
            guard let suite = UserDefaults(suiteName: "IOSChatViewModelStreamingCoalescingTests") else {
                fatalError("Failed to create UserDefaults suite for tests")
            }
            defaults = suite
            defaults.removePersistentDomain(forName: "IOSChatViewModelStreamingCoalescingTests")
            AppPreferences.use(defaults)
            defaults.set(false, forKey: "autoGenerateTitle")
            AIService.keychain = InMemoryKeychainStorage()
        }

        @Test(.timeLimit(.minutes(1)))
        func `multi-model chunks wait for coalescing interval before mutating conversation`() async throws {
            let fixture = try await makeFixture()

            fixture.viewModel.processMultiModelChunk(
                model: fixture.model,
                chunk: "Hel",
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId
            )
            fixture.viewModel.processMultiModelChunk(
                model: fixture.model,
                chunk: "lo",
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId
            )

            #expect(fixture.manager.conversations.first?.messages.first?.content == "")
            #expect(fixture.viewModel.messageContentRevision == 0)

            try await Task.sleep(for: .milliseconds(120))

            #expect(fixture.manager.conversations.first?.messages.first?.content == "Hello")
            #expect(fixture.manager.conversations.first?.messages.last?.content == "")
            #expect(fixture.viewModel.messageContentRevision == 1)
        }

        @Test(.timeLimit(.minutes(1)))
        func `model completion flushes pending chunks immediately`() async throws {
            let fixture = try await makeFixture()

            fixture.viewModel.processMultiModelChunk(
                model: fixture.model,
                chunk: "Done",
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId
            )
            #expect(fixture.manager.conversations.first?.messages.first?.content == "")

            fixture.viewModel.processMultiModelCompletion(
                model: fixture.model,
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId,
                responseGroupId: fixture.responseGroupId
            )

            #expect(fixture.manager.conversations.first?.messages.first?.content == "Done")
            #expect(fixture.manager.conversations.first?.responseGroups.first?.responses.first?.status == .completed)
            #expect(fixture.viewModel.messageContentRevision == 1)
        }

        @Test
        func `ordered callback queue preserves stream event order`() async {
            let queue = OrderedMainActorEventQueue()
            var events: [String] = []

            queue.enqueue { events.append("chunk") }
            queue.enqueue { events.append("complete") }
            await queue.waitForAll()

            #expect(events == ["chunk", "complete"])
        }

        @Test
        func `tool request state remains pending after the UI label clears`() {
            let state = StreamingRequestCallbackState()

            state.markToolCallRequested()

            #expect(state.hasPendingToolCall)
            #expect(!state.isFinalized)
        }

        @Test
        func `finalized tool request cannot remain pending`() {
            let state = StreamingRequestCallbackState()

            state.markToolCallRequested()
            state.markFinalized()
            state.markToolCallRequested()

            #expect(state.isFinalized)
            #expect(!state.hasPendingToolCall)
        }

        @Test
        func `multiple tool calls are retained for one processing batch`() throws {
            let state = StreamingRequestCallbackState()
            state.enqueueToolCall(
                StreamingToolCall(id: "call-1", name: "web_search", arguments: ["query": "first"])
            )
            state.enqueueToolCall(
                StreamingToolCall(id: "call-2", name: "web_search", arguments: ["query": "second"])
            )

            let toolCalls = try #require(state.beginToolCallProcessing())

            #expect(toolCalls.map(\.id) == ["call-1", "call-2"])
            #expect(state.hasPendingToolCall)
            state.finishToolCallProcessing()
            #expect(!state.hasPendingToolCall)
        }

        @Test
        func `in-flight tool calls remain available for cancellation finalization`() throws {
            let state = StreamingRequestCallbackState()
            state.enqueueToolCall(
                StreamingToolCall(id: "call-1", name: "web_search", arguments: ["query": "test"])
            )

            let processingToolCalls = try #require(state.beginToolCallProcessing())
            let terminalToolCalls = state.takePendingToolCalls()

            #expect(processingToolCalls.map(\.id) == ["call-1"])
            #expect(terminalToolCalls.map(\.id) == ["call-1"])
            #expect(!state.hasPendingToolCall)
        }

        @Test
        func `cancelling multi-model generation finalizes streaming response entries`() async throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let store = TestHelpers.makeTestStore(directory: directory, keychain: InMemoryKeychainStorage())
            let manager = ConversationManager(
                store: store,
                saveDebounceDuration: .milliseconds(0),
                searchIndexWarmupEnabled: false
            )
            _ = await manager.loadingTask?.value
            let conversation = TestHelpers.sampleConversation(title: "Cancellation")
            manager.conversations = [conversation]

            let service = AIService(urlSession: URLSession(configuration: .ephemeral))
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: service
            )
            viewModel.selectedModels = ["model-a", "model-b"]
            viewModel.messageText = "Cancel this request"

            viewModel.sendMessage()
            let responseGroup = try #require(manager.conversations.first?.responseGroups.last)
            let responseGroupId = responseGroup.id
            let firstResponse = try #require(responseGroup.responses.first)
            #expect(responseGroup.responses.allSatisfy { $0.status == .streaming })
            viewModel.processMultiModelChunk(
                model: firstResponse.modelName,
                chunk: "buffered partial",
                messageIds: [firstResponse.modelName: firstResponse.id],
                conversationId: conversation.id
            )

            viewModel.cancelGeneration()
            let responseGroupAfterCancel = try #require(manager.conversations.first?.getResponseGroup(responseGroupId))
            let messageAfterCancel = try #require(
                manager.conversations.first?.messages.first(where: { $0.id == firstResponse.id })
            )
            #expect(messageAfterCancel.content == "buffered partial")
            #expect(responseGroupAfterCancel.isComplete)
            #expect(responseGroupAfterCancel.responses.allSatisfy { $0.status == .failed })

            await manager.flushPendingSaves()
            let persisted = try #require(try await store.loadConversation(id: conversation.id))
            #expect(persisted.getResponseGroup(responseGroupId)?.isComplete == true)
            #expect(persisted.messages.first(where: { $0.id == firstResponse.id })?.content == "buffered partial")
        }

        @Test
        func `switching conversations flushes and persists buffered multi-model content`() async throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let store = TestHelpers.makeTestStore(directory: directory, keychain: InMemoryKeychainStorage())
            let manager = ConversationManager(
                store: store,
                saveDebounceDuration: .milliseconds(0),
                searchIndexWarmupEnabled: false
            )
            _ = await manager.loadingTask?.value
            let sourceConversation = TestHelpers.sampleConversation(title: "Source")
            let destinationConversation = TestHelpers.sampleConversation(title: "Destination")
            manager.conversations = [sourceConversation, destinationConversation]

            let service = AIService(urlSession: URLSession(configuration: .ephemeral))
            let viewModel = IOSChatViewModel(
                conversationId: sourceConversation.id,
                conversationManager: manager,
                aiService: service
            )
            viewModel.selectedModels = ["model-a", "model-b"]
            viewModel.messageText = "Switch while streaming"
            viewModel.sendMessage()

            let responseGroup = try #require(
                manager.conversation(byId: sourceConversation.id)?.responseGroups.last
            )
            let firstResponse = try #require(responseGroup.responses.first)
            viewModel.processMultiModelChunk(
                model: firstResponse.modelName,
                chunk: "queued before switch",
                messageIds: [firstResponse.modelName: firstResponse.id],
                conversationId: sourceConversation.id
            )

            viewModel.configure(with: manager, conversationId: destinationConversation.id)
            for _ in 0 ..< 1000 where viewModel.conversationId != destinationConversation.id {
                await Task.yield()
            }
            #expect(viewModel.conversationId == destinationConversation.id)

            await manager.flushPendingSaves()
            let persisted = try #require(try await store.loadConversation(id: sourceConversation.id))
            #expect(
                persisted.messages.first(where: { $0.id == firstResponse.id })?.content
                    == "queued before switch"
            )
            #expect(persisted.getResponseGroup(responseGroup.id)?.isComplete == true)
        }

        @Test
        func `resetting an idle new chat does not cancel a shared AI request`() async throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let store = TestHelpers.makeTestStore(directory: directory, keychain: InMemoryKeychainStorage())
            let manager = ConversationManager(
                store: store,
                saveDebounceDuration: .milliseconds(0),
                searchIndexWarmupEnabled: false
            )
            _ = await manager.loadingTask?.value
            let service = AIService(urlSession: URLSession(configuration: .ephemeral))
            var cancellationCount = 0
            let viewModel = IOSChatViewModel(
                conversationManager: manager,
                aiService: service,
                cancelCurrentAIRequest: { _ in
                    cancellationCount += 1
                }
            )

            viewModel.resetForNewChat()

            #expect(cancellationCount == 0)
        }

        @Test(.timeLimit(.minutes(1)))
        func `successful tool continuation persists its result before the follow-up assistant`() async throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let store = TestHelpers.makeTestStore(directory: directory, keychain: InMemoryKeychainStorage())
            let manager = ConversationManager(
                store: store,
                saveDebounceDuration: .milliseconds(0),
                searchIndexWarmupEnabled: false
            )
            _ = await manager.loadingTask?.value

            let requestProbe = IOSChatRequestProbe()
            IOSChatMockURLProtocol.requestHandler = { request in
                let requestNumber = requestProbe.recordRequest()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                let body = if requestNumber == 1 {
                    Data(
                        """
                        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_123","function":{"name":"web_search","arguments":"{\\"query\\":\\"test\\"}"}}]}}]}

                        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

                        data: [DONE]

                        """.utf8
                    )
                } else {
                    Data(
                        """
                        data: {"choices":[{"delta":{"content":"Finished"}}]}

                        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

                        data: [DONE]

                        """.utf8
                    )
                }
                return (response, body)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IOSChatMockURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            let model = "gpt-4o"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"

            let conversation = Conversation(title: "Tool Success", model: model)
            manager.conversations = [conversation]
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: service,
                executeBuiltInTool: { _, _ in
                    ("tool result", nil)
                }
            )
            viewModel.messageText = "Use the tool"
            viewModel.sendMessage()

            for _ in 0 ..< 100 where requestProbe.requestCount < 2 || viewModel.isGenerating {
                try await Task.sleep(for: .milliseconds(20))
            }

            #expect(requestProbe.requestCount == 2)
            #expect(!viewModel.isGenerating)
            let persistedConversation = try #require(manager.conversation(byId: conversation.id))
            let toolMessageIndex = try #require(persistedConversation.messages.firstIndex { message in
                message.role == .tool && message.toolCalls?.contains(where: { $0.id == "call_123" }) == true
            })
            let originatingAssistantIndex = try #require(persistedConversation.messages.firstIndex { message in
                message.role == .assistant && message.toolCalls?.contains(where: { $0.id == "call_123" }) == true
            })
            let followUpAssistantIndex = try #require(persistedConversation.messages.lastIndex { message in
                message.role == .assistant && message.content == "Finished"
            })
            #expect(persistedConversation.messages[toolMessageIndex].content == "tool result")
            #expect(originatingAssistantIndex < toolMessageIndex)
            #expect(toolMessageIndex < followUpAssistantIndex)
            #expect(!persistedConversation.messages.contains { message in
                message.role == .tool && message.content.contains("cancelled")
            })
        }

        @Test(.timeLimit(.minutes(1)))
        func `cancelling generation synchronously cancels a pending tool continuation`() async throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let store = TestHelpers.makeTestStore(directory: directory, keychain: InMemoryKeychainStorage())
            let manager = ConversationManager(
                store: store,
                saveDebounceDuration: .milliseconds(0),
                searchIndexWarmupEnabled: false
            )
            _ = await manager.loadingTask?.value

            let requestProbe = IOSChatRequestProbe()
            IOSChatMockURLProtocol.requestHandler = { request in
                requestProbe.recordRequest()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                let body = Data(
                    """
                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_123","function":{"name":"web_search","arguments":"{\\"query\\":\\"test\\"}"}}]}}]}

                    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

                    data: [DONE]

                    """.utf8
                )
                return (response, body)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IOSChatMockURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            let model = "gpt-4o"
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"

            let conversation = Conversation(title: "Tool Cancellation", model: model)
            manager.conversations = [conversation]
            let toolGate = IOSChatToolExecutionGate()
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: service,
                executeBuiltInTool: { _, _ in
                    await toolGate.execute()
                }
            )
            viewModel.messageText = "Use the tool"
            viewModel.sendMessage()
            await toolGate.waitUntilStarted()

            #expect(requestProbe.requestCount == 1)
            viewModel.cancelGeneration()
            #expect(toolGate.wasCancelled)

            toolGate.release()
            try await Task.sleep(for: .milliseconds(150))
            #expect(requestProbe.requestCount == 1)
            let persistedConversation = try #require(manager.conversation(byId: conversation.id))
            let persistedToolResult = persistedConversation.messages.first { message in
                message.role == .tool && message.toolCalls?.contains(where: { $0.id == "call_123" }) == true
            }
            #expect(persistedToolResult?.content == "Tool call cancelled before completion.")
        }

        private func makeFixture() async throws -> Fixture {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let store = TestHelpers.makeTestStore(directory: directory, keychain: InMemoryKeychainStorage())
            let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
            _ = await manager.loadingTask?.value

            let conversationId = UUID()
            let messageId = UUID()
            let responseGroupId = UUID()
            let userMessageId = UUID()
            let model = "test-model-a"
            let trailingModel = "test-model-b"
            let trailingMessageId = UUID()
            var responseGroup = ResponseGroup(id: responseGroupId, userMessageId: userMessageId)
            responseGroup.addResponse(messageId: messageId, modelName: model, status: .streaming)
            responseGroup.addResponse(messageId: trailingMessageId, modelName: trailingModel, status: .streaming)
            let assistantMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId
            )
            let trailingAssistantMessage = Message(
                id: trailingMessageId,
                role: .assistant,
                content: "",
                model: trailingModel,
                responseGroupId: responseGroupId
            )
            let conversation = Conversation(
                id: conversationId,
                title: "Streaming Coalescing",
                messages: [assistantMessage, trailingAssistantMessage],
                model: model,
                responseGroups: [responseGroup]
            )
            manager.conversations = [conversation]

            let service = AIService(urlSession: URLSession(configuration: .ephemeral))
            let viewModel = IOSChatViewModel(
                conversationId: conversationId,
                conversationManager: manager,
                aiService: service
            )

            return Fixture(
                viewModel: viewModel,
                manager: manager,
                conversationId: conversationId,
                messageId: messageId,
                responseGroupId: responseGroupId,
                model: model,
                messageIds: [model: messageId]
            )
        }
    }

    private final class IOSChatRequestProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var requestCount: Int {
            lock.withLock { count }
        }

        @discardableResult
        func recordRequest() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private final class IOSChatToolExecutionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancelled = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var startedContinuations: [CheckedContinuation<Void, Never>] = []

        var wasCancelled: Bool {
            lock.withLock { cancelled }
        }

        func execute() async -> (String, [CitationReference]?) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        started = true
                        for startedContinuation in startedContinuations {
                            startedContinuation.resume()
                        }
                        startedContinuations.removeAll()
                        releaseContinuation = continuation
                    }
                }
            } onCancel: {
                lock.withLock {
                    cancelled = true
                }
            }
            return ("tool result", nil)
        }

        func waitUntilStarted() async {
            let alreadyStarted = lock.withLock { started }
            guard !alreadyStarted else { return }
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if started {
                        continuation.resume()
                    } else {
                        startedContinuations.append(continuation)
                    }
                }
            }
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { releaseContinuation = nil }
                return releaseContinuation
            }
            continuation?.resume()
        }
    }

    private final class IOSChatMockURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override static func canInit(with _: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.requestHandler else {
                client?.urlProtocol(
                    self,
                    didFailWithError: NSError(domain: "IOSChatMockURLProtocol", code: -1)
                )
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }
#endif
