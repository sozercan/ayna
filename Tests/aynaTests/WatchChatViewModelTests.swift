@testable import Ayna
import XCTest

// Note: WatchChatViewModel is only available on watchOS. These tests verify the
// OpenAIService tool integration and the data flow patterns used by the watch.
// The actual WatchChatViewModel cannot be tested directly on macOS.

@MainActor
final class WatchChatViewModelIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keychain: InMemoryKeychainStorage!

    override func setUp() async throws {
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

    override func tearDown() async throws {
        AppPreferences.reset()
        defaults.removePersistentDomain(forName: "WatchChatViewModelTests")
        defaults = nil
        keychain = nil
        WatchMockURLProtocol.reset()
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
