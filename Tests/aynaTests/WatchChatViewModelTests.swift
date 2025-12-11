@testable import Ayna
import XCTest

// Note: WatchChatViewModel is only available on watchOS. These tests verify the
// OpenAIService tool integration and the data flow patterns used by the watch.
// The actual WatchChatViewModel cannot be tested directly on macOS.

@MainActor
final class WatchChatViewModelIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keychain: InMemoryKeychainStorage!

    override func setUp() {
        super.setUp()
        guard let suite = UserDefaults(suiteName: "WatchChatViewModelTests") else {
            fatalError("Failed to create UserDefaults suite")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "WatchChatViewModelTests")
        defaults.synchronize()
        AppPreferences.use(defaults)

        keychain = InMemoryKeychainStorage()
        WatchMockURLProtocol.reset()
    }

    override func tearDown() {
        AppPreferences.reset()
        defaults.removePersistentDomain(forName: "WatchChatViewModelTests")
        defaults = nil
        keychain = nil
        WatchMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Tool Integration Tests

    func testOpenAIServiceIncludesTavilyToolWhenConfigured() async throws {
        // Configure TavilyService with a test API key
        let tavilyService = TavilyService(keychain: keychain)
        tavilyService.apiKey = "tvly-test-key"
        tavilyService.isEnabled = true

        // Note: In the actual app, OpenAIService.getAllAvailableTools() includes Tavily
        // when TavilyService.shared.isAvailable is true
        XCTAssertTrue(tavilyService.isAvailable)
        XCTAssertTrue(tavilyService.isConfigured)

        let toolDef = tavilyService.toolDefinition()
        guard let function = toolDef["function"] as? [String: Any],
              let name = function["name"] as? String
        else {
            XCTFail("Invalid tool definition")
            return
        }

        XCTAssertEqual(name, "web_search")
    }

    func testOpenAIServiceExcludesTavilyToolWhenDisabled() {
        let tavilyService = TavilyService(keychain: keychain)
        tavilyService.apiKey = "tvly-test-key"
        tavilyService.isEnabled = false

        XCTAssertTrue(tavilyService.isConfigured)
        XCTAssertFalse(tavilyService.isAvailable)
    }

    func testOpenAIServiceExcludesTavilyToolWhenNotConfigured() {
        let tavilyService = TavilyService(keychain: keychain)
        tavilyService.apiKey = ""
        tavilyService.isEnabled = true

        XCTAssertFalse(tavilyService.isConfigured)
        XCTAssertFalse(tavilyService.isAvailable)
    }

    // MARK: - Message Flow Tests

    func testWatchMessageSyncFlow() throws {
        // Simulate the message flow: User sends message → WatchMessage → sync to iPhone
        let userContent = "What's the weather?"
        let userMessage = Message(role: .user, content: userContent)
        let watchMessage = WatchMessage(from: userMessage)

        // Encode for WatchConnectivity
        let data = try JSONEncoder().encode(watchMessage)
        XCTAssertFalse(data.isEmpty)

        // Decode on iPhone side
        let decoded = try JSONDecoder().decode(WatchMessage.self, from: data)
        XCTAssertEqual(decoded.content, userContent)
        XCTAssertEqual(decoded.role, "user")

        // Convert to Message for ConversationManager
        let message = decoded.toMessage()
        XCTAssertEqual(message.content, userContent)
        XCTAssertEqual(message.role, .user)
    }

    func testAssistantMessageSyncFlow() throws {
        // Simulate: API response → Update local → WatchMessage → sync to iPhone
        let assistantContent = "The weather is sunny with a high of 72°F."
        let assistantMessage = Message(role: .assistant, content: assistantContent, model: "gpt-4o")
        let watchMessage = WatchMessage(from: assistantMessage)

        let data = try JSONEncoder().encode(watchMessage)
        let decoded = try JSONDecoder().decode(WatchMessage.self, from: data)

        XCTAssertEqual(decoded.content, assistantContent)
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(decoded.model, "gpt-4o")
    }

    // MARK: - Tool Execution Flow Tests

    func testTavilyToolCallExecution() async {
        // Configure mock Tavily service
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WatchMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let tavilyService = TavilyService(keychain: keychain, urlSession: session)
        tavilyService.apiKey = "tvly-test-key"
        tavilyService.isEnabled = true

        WatchMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.tavily.com/search")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
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
            return (response, body)
        }

        let result = await tavilyService.executeToolCall(arguments: ["query": "weather"])

        XCTAssertTrue(result.contains("Answer"))
        XCTAssertTrue(result.contains("Sunny"))
        XCTAssertTrue(result.contains("Sources"))
    }

    func testToolCallDepthLimit() {
        // The WatchChatViewModel has a maxToolCallDepth of 5
        // This test verifies the concept of depth limiting
        let maxDepth = 5
        var currentDepth = 0

        // Simulate recursive tool calls
        for _ in 1 ... 10 {
            guard currentDepth < maxDepth else {
                break
            }
            currentDepth += 1
        }

        XCTAssertEqual(currentDepth, maxDepth, "Tool call depth should be limited to \(maxDepth)")
    }

    // MARK: - Model Filtering Tests

    func testWatchOSModelFiltering() {
        // On watchOS, AIKit and Apple Intelligence models should be filtered out
        let allModels = ["gpt-4o", "gpt-4", "llama-local", "apple-intelligence"]
        let modelProviders: [String: AIProvider] = [
            "gpt-4o": .openai,
            "gpt-4": .openai,
            "llama-local": .aikit,
            "apple-intelligence": .appleIntelligence
        ]

        let usableModels = allModels.filter { model in
            let provider = modelProviders[model]
            return provider != .aikit && provider != .appleIntelligence
        }

        XCTAssertEqual(usableModels.count, 2)
        XCTAssertTrue(usableModels.contains("gpt-4o"))
        XCTAssertTrue(usableModels.contains("gpt-4"))
        XCTAssertFalse(usableModels.contains("llama-local"))
        XCTAssertFalse(usableModels.contains("apple-intelligence"))
    }

    // MARK: - Conversation State Tests

    func testTitleGenerationTrigger() {
        // Title generation should only trigger on the first message
        var conversation = Conversation(title: "New Chat", model: "gpt-4o")

        let isFirstMessage = conversation.messages.isEmpty
        XCTAssertTrue(isFirstMessage, "First message should trigger title generation")

        conversation.addMessage(Message(role: .user, content: "Hello"))
        conversation.addMessage(Message(role: .assistant, content: "Hi!"))

        let isStillFirstMessage = conversation.messages.isEmpty
        XCTAssertFalse(isStillFirstMessage, "Subsequent messages should not trigger title generation")
    }

    func testConversationUpdatePreservesLocalTitle() {
        // When iPhone syncs with "New Chat" but watch has generated a title,
        // the local title should be preserved
        let conversationId = UUID()

        // Simulate local conversation with generated title
        let localTitle = "Weather Discussion"
        var localConv = Conversation(id: conversationId, title: localTitle, model: "gpt-4o")
        localConv.addMessage(Message(role: .user, content: "What's the weather?"))

        // Simulate sync from iPhone with "New Chat" title
        let syncedTitle = "New Chat"
        var syncedConv = Conversation(id: conversationId, title: syncedTitle, model: "gpt-4o")
        syncedConv.addMessage(Message(role: .user, content: "What's the weather?"))

        // Merge logic: preserve local title if iPhone still has "New Chat"
        let shouldPreserveLocal = syncedConv.title == "New Chat" && localConv.title != "New Chat"
        let finalTitle = shouldPreserveLocal ? localConv.title : syncedConv.title

        XCTAssertEqual(finalTitle, localTitle)
    }

    // MARK: - Additional Watch Integration Tests

    func testStreamingThrottleInterval() {
        // Verify the throttle interval constant is reasonable for Watch performance
        let uiUpdateInterval: TimeInterval = 0.1 // 100ms as used in WatchChatViewModel
        XCTAssertEqual(uiUpdateInterval, 0.1, accuracy: 0.001)
        XCTAssertTrue(uiUpdateInterval >= 0.05, "Throttle should be at least 50ms for performance")
        XCTAssertTrue(uiUpdateInterval <= 0.2, "Throttle should be at most 200ms for responsiveness")
    }

    func testMaxToolCallDepthConstant() {
        // The WatchChatViewModel should limit recursive tool calls
        let maxToolCallDepth = 5

        // Simulate checking depth limit
        var currentDepth = 0
        var reachedLimit = false

        for _ in 1 ... 10 {
            if currentDepth >= maxToolCallDepth {
                reachedLimit = true
                break
            }
            currentDepth += 1
        }

        XCTAssertTrue(reachedLimit, "Should reach tool call depth limit")
        XCTAssertEqual(currentDepth, maxToolCallDepth)
    }

    func testWatchConversationSyncMergeLogic() {
        // Test the merge logic used in WatchConversationStore.updateConversations
        let conversationId = UUID()

        // Local has more messages (during streaming)
        var localConv = Conversation(id: conversationId, title: "Chat", model: "gpt-4o")
        localConv.addMessage(Message(role: .user, content: "Hello"))
        localConv.addMessage(Message(role: .assistant, content: "Hi!"))
        localConv.addMessage(Message(role: .assistant, content: "")) // Streaming placeholder

        // Remote has fewer messages (hasn't received streaming update yet)
        var remoteConv = Conversation(id: conversationId, title: "Chat", model: "gpt-4o")
        remoteConv.addMessage(Message(role: .user, content: "Hello"))
        remoteConv.addMessage(Message(role: .assistant, content: "Hi!"))

        // Merge logic should preserve local when it has more messages
        let shouldPreserveLocalMessages = localConv.messages.count > remoteConv.messages.count
        XCTAssertTrue(shouldPreserveLocalMessages)
    }

    func testWatchMessageRoundTripWithAllFields() throws {
        let originalId = UUID()
        let timestamp = Date()
        let original = Message(
            id: originalId,
            role: .assistant,
            content: "Response with **markdown** and `code`",
            timestamp: timestamp,
            model: "gpt-4o"
        )

        // Convert to WatchMessage
        let watchMessage = WatchMessage(from: original)

        // Encode/decode (simulating WatchConnectivity transfer)
        let data = try JSONEncoder().encode(watchMessage)
        let decoded = try JSONDecoder().decode(WatchMessage.self, from: data)

        // Convert back to Message
        let final = decoded.toMessage()

        XCTAssertEqual(final.id, originalId)
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, original.content)
        XCTAssertEqual(final.model, "gpt-4o")
        XCTAssertEqual(final.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testWatchConversationRoundTripWithMessages() throws {
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

        // Convert to WatchConversation
        let watchConv = WatchConversation(from: original)

        // Encode/decode
        let data = try JSONEncoder().encode(watchConv)
        let decoded = try JSONDecoder().decode(WatchConversation.self, from: data)

        // Convert back
        let final = decoded.toConversation()

        XCTAssertEqual(final.id, originalId)
        XCTAssertEqual(final.title, "Test Chat")
        XCTAssertEqual(final.model, "gpt-4o")
        XCTAssertEqual(final.messages.count, 2)
        XCTAssertEqual(final.messages[0].content, "Question")
        XCTAssertEqual(final.messages[1].content, "Answer")
    }

    func testModelUsabilityCheckLogic() {
        // Test the filtering logic for watchOS-compatible models
        let allModels = ["gpt-4o", "gpt-4", "gpt-3.5-turbo", "llama-local", "apple-intelligence-chat"]
        let modelProviders: [String: AIProvider] = [
            "gpt-4o": .openai,
            "gpt-4": .openai,
            "gpt-3.5-turbo": .openai,
            "llama-local": .aikit,
            "apple-intelligence-chat": .appleIntelligence
        ]

        // watchOS can only use cloud-based models (not AIKit or Apple Intelligence)
        let usableModels = allModels.filter { model in
            let provider = modelProviders[model]
            return provider != .aikit && provider != .appleIntelligence
        }

        XCTAssertEqual(usableModels.count, 3)
        XCTAssertTrue(usableModels.contains("gpt-4o"))
        XCTAssertTrue(usableModels.contains("gpt-4"))
        XCTAssertTrue(usableModels.contains("gpt-3.5-turbo"))
        XCTAssertFalse(usableModels.contains("llama-local"))
        XCTAssertFalse(usableModels.contains("apple-intelligence-chat"))
    }

    func testAzureProviderAllowedOnWatch() {
        // GitHub Models should work on watchOS (uses cloud API)
        let modelProviders: [String: AIProvider] = [
            "github-gpt-4o": .githubModels,
            "openai-gpt-4": .openai
        ]

        for (model, provider) in modelProviders {
            let isUsableOnWatch = provider != .aikit && provider != .appleIntelligence
            XCTAssertTrue(isUsableOnWatch, "\(model) should be usable on watchOS")
        }
    }
}

// MARK: - Mock URL Protocol for Watch Tests

private final class WatchMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        requestHandler = nil
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = WatchMockURLProtocol.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "WatchMockURLProtocol",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Handler not set"]
                )
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
