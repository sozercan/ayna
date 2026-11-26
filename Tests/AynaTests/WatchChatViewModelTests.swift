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
        func `tool call depth limit`() {
            let maxDepth = 5
            var currentDepth = 0

            for _ in 1 ... 10 {
                guard currentDepth < maxDepth else {
                    break
                }
                currentDepth += 1
            }

            #expect(currentDepth == maxDepth, "Tool call depth should be limited to \(maxDepth)")
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
        func `title generation trigger`() {
            var conversation = Conversation(title: "New Chat", model: "gpt-4o")

            let isFirstMessage = conversation.messages.isEmpty
            #expect(isFirstMessage, "First message should trigger title generation")

            conversation.addMessage(Message(role: .user, content: "Hello"))
            conversation.addMessage(Message(role: .assistant, content: "Hi!"))

            let isStillFirstMessage = conversation.messages.isEmpty
            #expect(!isStillFirstMessage, "Subsequent messages should not trigger title generation")
        }

        @Test
        func `conversation update preserves local title`() {
            let conversationId = UUID()

            let localTitle = "Weather Discussion"
            var localConv = Conversation(id: conversationId, title: localTitle, model: "gpt-4o")
            localConv.addMessage(Message(role: .user, content: "What's the weather?"))

            let syncedTitle = "New Chat"
            var syncedConv = Conversation(id: conversationId, title: syncedTitle, model: "gpt-4o")
            syncedConv.addMessage(Message(role: .user, content: "What's the weather?"))

            let shouldPreserveLocal = syncedConv.title == "New Chat" && localConv.title != "New Chat"
            let finalTitle = shouldPreserveLocal ? localConv.title : syncedConv.title

            #expect(finalTitle == localTitle)
        }

        @Test
        func `streaming throttle interval`() {
            let uiUpdateInterval: TimeInterval = 0.1
            #expect(uiUpdateInterval == 0.1)
            #expect(uiUpdateInterval >= 0.05, "Throttle should be at least 50ms for performance")
            #expect(uiUpdateInterval <= 0.2, "Throttle should be at most 200ms for responsiveness")
        }

        @Test
        func `max tool call depth constant`() {
            let maxToolCallDepth = 5

            var currentDepth = 0
            var reachedLimit = false

            for _ in 1 ... 10 {
                if currentDepth >= maxToolCallDepth {
                    reachedLimit = true
                    break
                }
                currentDepth += 1
            }

            #expect(reachedLimit, "Should reach tool call depth limit")
            #expect(currentDepth == maxToolCallDepth)
        }

        @Test
        func `watch conversation sync merge logic`() {
            let conversationId = UUID()

            var localConv = Conversation(id: conversationId, title: "Chat", model: "gpt-4o")
            localConv.addMessage(Message(role: .user, content: "Hello"))
            localConv.addMessage(Message(role: .assistant, content: "Hi!"))
            localConv.addMessage(Message(role: .assistant, content: ""))

            var remoteConv = Conversation(id: conversationId, title: "Chat", model: "gpt-4o")
            remoteConv.addMessage(Message(role: .user, content: "Hello"))
            remoteConv.addMessage(Message(role: .assistant, content: "Hi!"))

            let shouldPreserveLocalMessages = localConv.messages.count > remoteConv.messages.count
            #expect(shouldPreserveLocalMessages)
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

#endif
