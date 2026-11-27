#if os(watchOS)

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("WatchChatViewModel Integration Tests", .serialized)
    @MainActor
    struct WatchChatViewModelIntegrationTests {
        private var defaults: UserDefaults
        private var keychain: InMemoryKeychainStorage

        init() {
            guard let suite = UserDefaults(suiteName: "WatchChatViewModelTests") else {
                fatalError("Failed to create UserDefaults suite")
            }
            defaults = suite
            defaults.removePersistentDomain(forName: "WatchChatViewModelTests")
            defaults.synchronize()
            AppPreferences.use(defaults)

            keychain = InMemoryKeychainStorage()
        }

        @Test
        func `openAI service includes Tavily tool when configured`() {
            let tavilyService = TavilyService(keychain: keychain)
            tavilyService.apiKey = "tvly-test-key"
            tavilyService.isEnabled = true

            #expect(tavilyService.isAvailable)
            #expect(tavilyService.isConfigured)

            let toolDef = tavilyService.toolDefinition()
            guard let function = toolDef["function"] as? [String: Any],
                  let name = function["name"] as? String
            else {
                Issue.record("Invalid tool definition")
                return
            }

            #expect(name == "web_search")
        }

        @Test
        func `openAI service excludes Tavily tool when disabled`() {
            let tavilyService = TavilyService(keychain: keychain)
            tavilyService.apiKey = "tvly-test-key"
            tavilyService.isEnabled = false

            #expect(tavilyService.isConfigured)
            #expect(!tavilyService.isAvailable)
        }

        @Test
        func `openAI service excludes Tavily tool when not configured`() {
            let tavilyService = TavilyService(keychain: keychain)
            tavilyService.apiKey = ""
            tavilyService.isEnabled = true

            #expect(!tavilyService.isConfigured)
            #expect(!tavilyService.isAvailable)
        }

        @Test
        func `watch message sync flow`() throws {
            let userContent = "What's the weather?"
            let userMessage = Message(role: .user, content: userContent)
            let watchMessage = WatchMessage(from: userMessage)

            let data = try JSONEncoder().encode(watchMessage)
            #expect(!data.isEmpty)

            let decoded = try JSONDecoder().decode(WatchMessage.self, from: data)
            #expect(decoded.content == userContent)
            #expect(decoded.role == "user")

            let message = decoded.toMessage()
            #expect(message.content == userContent)
            #expect(message.role == .user)
        }

        @Test
        func `assistant message sync flow`() throws {
            let assistantContent = "The weather is sunny with a high of 72°F."
            let assistantMessage = Message(role: .assistant, content: assistantContent, model: "gpt-4o")
            let watchMessage = WatchMessage(from: assistantMessage)

            let data = try JSONEncoder().encode(watchMessage)
            let decoded = try JSONDecoder().decode(WatchMessage.self, from: data)

            #expect(decoded.content == assistantContent)
            #expect(decoded.role == "assistant")
            #expect(decoded.model == "gpt-4o")
        }

        @Test
        func `tavily tool call execution`() async {
            guard let url = URL(string: "https://api.tavily.com/search"),
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil
                  )
            else {
                Issue.record("Failed to construct Tavily test response")
                return
            }
            let body = Data("""
            {
                "query": "weather",
                "answer": "Sunny with temperatures around 72°F.",
                "results": [
                    {
                        "title": "Weather.com",
                        "url": "https://weather.com",
                        "content": "Today's forecast shows clear skies.",
                        "score": 0.9
                    }
                ],
                "response_time": 0.5
            }
            """.utf8)
            let tavilyService = TavilyService(keychain: keychain) { request in
                #expect(request.url == response.url)
                return (body, response)
            }
            tavilyService.apiKey = "tvly-test-key"
            tavilyService.isEnabled = true

            let (result, citations) = await tavilyService.executeToolCallWithCitations(
                arguments: ["query": "weather"]
            )

            #expect(result.contains("Answer"))
            #expect(result.contains("Sunny"))
            #expect(citations.count == 1)
            #expect(citations.first?.title == "Weather.com")
            #expect(citations.first?.url == "https://weather.com")
        }

        @Test
        func `tool call depth limit enforces WatchChatViewModel maxToolCallDepth`() async throws {
            let store = WatchConversationStore(
                userDefaults: defaults,
                persistenceKey: "watch.depth.\(UUID().uuidString)",
                mutationEnqueuer: { _ in }
            )
            let conversation = try #require(store.createConversation(title: "Depth Test", model: "gpt-4o"))
            WatchConnectivityService.shared.availableModels = ["gpt-4o"]
            WatchConnectivityService.shared.selectedModel = "gpt-4o"

            let aiService = WatchTestCapturingAIService(model: "gpt-4o")
            let viewModel = WatchChatViewModel(
                conversationStore: store,
                connectivityService: .shared,
                aiService: aiService
            )
            viewModel.setConversation(conversation.id)
            #expect(viewModel.sendMessage("Loop tools") == .started)

            for step in 0 ..< WatchChatViewModel.maxToolCallDepth {
                let deadline = ContinuousClock().now.advanced(by: .seconds(1))
                while aiService.requests.count <= step, ContinuousClock().now < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let current = try #require(aiService.requests.indices.contains(step) ? aiService.requests[step] : nil)
                current.onToolCallRequested?("call-\(step)", "unknown_tool", [:])
                current.onComplete()
            }

            let overflowDeadline = ContinuousClock().now.advanced(by: .seconds(1))
            while aiService.requests.count <= WatchChatViewModel.maxToolCallDepth, ContinuousClock().now < overflowDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let overflow = try #require(aiService.requests.last)
            overflow.onToolCallRequested?("call-overflow", "unknown_tool", [:])

            let stopDeadline = ContinuousClock().now.advanced(by: .seconds(1))
            while viewModel.isLoading, ContinuousClock().now < stopDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }

            #expect(!viewModel.isLoading)
            #expect(viewModel.errorMessage == "Tool call limit reached. Please try again.")
            #expect(aiService.requests.count == WatchChatViewModel.maxToolCallDepth + 1)
        }

        @Test
        func `watchOS model filtering`() {
            let allModels = ["gpt-4o", "claude", "apple-intelligence", "inherited-model"]
            let modelProviders: [String: AIProvider] = [
                "gpt-4o": .openai,
                "claude": .anthropic,
                "apple-intelligence": .appleIntelligence
            ]

            let usableModels = WatchLiveModelPolicy.usableModels(
                availableModels: allModels,
                modelProviders: modelProviders,
                defaultProvider: .openai
            )

            #expect(usableModels == ["gpt-4o", "claude", "inherited-model"])
            #expect(!WatchLiveModelPolicy.isUsable(
                "not-advertised",
                availableModels: allModels,
                modelProviders: ["not-advertised": .openai],
                defaultProvider: .openai
            ))
            #expect(!WatchLiveModelPolicy.isUsable(
                "inherited-model",
                availableModels: allModels,
                modelProviders: modelProviders,
                defaultProvider: .appleIntelligence
            ))
        }

        @Test
        func `first message completion triggers title generation on WatchChatViewModel`() async throws {
            let store = WatchConversationStore(
                userDefaults: defaults,
                persistenceKey: "watch.title.\(UUID().uuidString)",
                mutationEnqueuer: { _ in }
            )
            let conversation = try #require(store.createConversation(title: "New Chat", model: "gpt-4o"))
            WatchConnectivityService.shared.availableModels = ["gpt-4o"]
            WatchConnectivityService.shared.selectedModel = "gpt-4o"

            var receivedPrompts: [String] = []
            let aiService = AIService(responseSimulator: { messages, callbacks in
                receivedPrompts.append(messages.last?.content ?? "")
                if receivedPrompts.count == 1 {
                    callbacks.onChunk("Hi there!")
                    callbacks.onComplete()
                } else {
                    callbacks.onChunk("Greeting Chat")
                    callbacks.onComplete()
                }
            })
            aiService.customModels = ["gpt-4o"]
            aiService.selectedModel = "gpt-4o"
            aiService.modelProviders["gpt-4o"] = .openai
            aiService.modelAPIKeys["gpt-4o"] = "sk-watch-test"

            let viewModel = WatchChatViewModel(
                conversationStore: store,
                connectivityService: .shared,
                aiService: aiService
            )
            viewModel.setConversation(conversation.id)
            #expect(viewModel.sendMessage("Hello") == .started)

            let deadline = ContinuousClock().now.advanced(by: .seconds(1))
            while store.conversation(for: conversation.id)?.title == "New Chat", ContinuousClock().now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }

            #expect(store.conversation(for: conversation.id)?.title == "Greeting Chat")
            #expect(receivedPrompts.count == 2)
        }

        @Test
        func `conversation store sync preserves pending local rename and draft messages`() throws {
            let store = WatchConversationStore(
                userDefaults: defaults,
                persistenceKey: "watch.sync.\(UUID().uuidString)",
                mutationEnqueuer: { _ in }
            )
            let created = try #require(store.createConversation(title: "New Chat", model: "gpt-4o"))
            let userMessage = WatchMessage(from: Message(role: .user, content: "What's the weather?"))
            #expect(store.addMessage(userMessage, to: created.id))
            #expect(store.renameConversation(created.id, newTitle: "Weather Discussion"))

            var draft = try #require(store.conversation(for: created.id))
            draft.messages.append(WatchMessage(from: Message(role: .assistant, content: "Draft reply", model: "gpt-4o")))
            #expect(store.syncDraft(draft))

            let now = Date()
            let remoteConversation = WatchConversation(
                id: created.id,
                title: "New Chat",
                messages: [userMessage],
                model: "gpt-4o",
                updatedAt: now,
                createdAt: now
            )
            store.updateConversations([remoteConversation])

            let merged = try #require(store.conversation(for: created.id))
            #expect(merged.title == "Weather Discussion")
            #expect(merged.messages.count == 2)
            #expect(merged.messages.last?.content == "Draft reply")
        }

        @Test
        func `streaming throttle interval batches rapid chunks until WatchChatViewModel interval elapses`() async throws {
            let store = WatchConversationStore(
                userDefaults: defaults,
                persistenceKey: "watch.throttle.\(UUID().uuidString)",
                mutationEnqueuer: { _ in }
            )
            let conversation = try #require(store.createConversation(title: "Throttle Test", model: "gpt-4o"))
            WatchConnectivityService.shared.availableModels = ["gpt-4o"]
            WatchConnectivityService.shared.selectedModel = "gpt-4o"

            var currentTime = Date(timeIntervalSince1970: 1000)
            let clockCallCount = FlightTestBox(0)
            let secondChunkProcessed = FlightTestSignal()
            var capturedCallbacks: AIServiceResponseSimulationCallbacks?
            let aiService = AIService(responseSimulator: { _, callbacks in
                capturedCallbacks = callbacks
            })
            aiService.customModels = ["gpt-4o"]
            aiService.selectedModel = "gpt-4o"
            aiService.modelProviders["gpt-4o"] = .openai
            aiService.modelAPIKeys["gpt-4o"] = "sk-watch-test"

            let viewModel = WatchChatViewModel(
                conversationStore: store,
                connectivityService: .shared,
                aiService: aiService,
                now: {
                    clockCallCount.update { $0 += 1 }
                    if clockCallCount.value == 2 {
                        secondChunkProcessed.signal()
                    }
                    return currentTime
                }
            )
            viewModel.setConversation(conversation.id)
            #expect(viewModel.sendMessage("Stream") == .started)

            let callbacks = try #require(capturedCallbacks)
            callbacks.onChunk("Hello")
            let firstDeadline = ContinuousClock().now.advanced(by: .seconds(1))
            while viewModel.streamingContent != "Hello", ContinuousClock().now < firstDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(viewModel.streamingContent == "Hello")

            currentTime = currentTime.addingTimeInterval(WatchChatViewModel.defaultUIUpdateInterval / 2)
            callbacks.onChunk(" world")
            #expect(await secondChunkProcessed.wait(timeout: .seconds(1)))
            #expect(viewModel.streamingContent == "Hello")

            currentTime = currentTime.addingTimeInterval(WatchChatViewModel.defaultUIUpdateInterval)
            callbacks.onChunk("!")
            let flushDeadline = ContinuousClock().now.advanced(by: .seconds(1))
            while viewModel.streamingContent != "Hello world!", ContinuousClock().now < flushDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(viewModel.streamingContent == "Hello world!")

            callbacks.onComplete()
            let doneDeadline = ContinuousClock().now.advanced(by: .seconds(1))
            while viewModel.isLoading, ContinuousClock().now < doneDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(store.conversation(for: conversation.id)?.messages.last?.content == "Hello world!")
        }

        @Test
        func `watch message round trip with all fields`() throws {
            let originalId = UUID()
            let timestamp = Date()
            let original = Message(
                id: originalId,
                role: .assistant,
                content: "Response with **markdown** and `code`",
                timestamp: timestamp,
                model: "gpt-4o"
            )

            let watchMessage = WatchMessage(from: original)

            let data = try JSONEncoder().encode(watchMessage)
            let decoded = try JSONDecoder().decode(WatchMessage.self, from: data)

            let final = decoded.toMessage()

            #expect(final.id == originalId)
            #expect(final.role == .assistant)
            #expect(final.content == original.content)
            #expect(final.model == "gpt-4o")
            #expect(abs(final.timestamp.timeIntervalSince1970 - timestamp.timeIntervalSince1970) < 0.001)
        }

        @Test
        func `watch conversation round trip with messages`() throws {
            let originalId = UUID()
            let createdAt = Date()
            var original = Conversation(
                id: originalId,
                title: "Test Chat",
                createdAt: createdAt,
                model: "gpt-4o"
            )
            original.addMessage(Message(role: .user, content: "Question"))
            original.addMessage(Message(role: .assistant, content: "Answer", model: "gpt-4o"))

            let watchConv = WatchConversation(from: original)

            let data = try JSONEncoder().encode(watchConv)
            let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

            let final = decoded.toConversation()

            #expect(final.id == originalId)
            #expect(final.title == "Test Chat")
            #expect(final.model == "gpt-4o")
            #expect(final.messages.count == 2)
            #expect(final.messages[0].content == "Question")
            #expect(final.messages[1].content == "Answer")
        }

        @Test
        func `model usability check logic`() {
            let allModels = ["unknown", "on-device", "unconfigured", "configured"]
            let modelProviders: [String: AIProvider] = [
                "on-device": .appleIntelligence,
                "unconfigured": .openai,
                "configured": .anthropic,
            ]

            let selected = WatchLiveModelPolicy.firstUsableModel(
                availableModels: allModels,
                modelProviders: modelProviders,
                defaultProvider: .openai,
                isConfigured: { $0 == "configured" }
            )

            #expect(selected == "configured")
        }
    }

    private struct WatchCapturedRequest: @unchecked Sendable {
        let onChunk: @Sendable (String) -> Void
        let onComplete: @Sendable () -> Void
        let onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    }

    @MainActor
    private final class WatchTestCapturingAIService: AIService {
        private(set) var requests: [WatchCapturedRequest] = []

        init(model: String) {
            super.init(responseSimulator: { _, _ in })
            customModels = [model]
            selectedModel = model
            modelProviders[model] = .openai
            modelAPIKeys[model] = "sk-watch-test"
        }

        override func sendMessage(
            messages: [Message],
            model: String?,
            temperature: Double?,
            stream: Bool,
            tools: [[String: Any]]?,
            conversationId: UUID?,
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            requestFlightID: RequestFlightID?
        ) -> AITextRequest {
            requests.append(
                WatchCapturedRequest(
                    onChunk: onChunk,
                    onComplete: onComplete,
                    onToolCallRequested: onToolCallRequested
                )
            )
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                requestFlightID: requestFlightID
            )
        }
    }

#endif
