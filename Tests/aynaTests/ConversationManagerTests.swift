@testable import Ayna
import XCTest

final class ConversationManagerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        guard let suite = UserDefaults(suiteName: "ConversationManagerTests") else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "ConversationManagerTests")
        AppPreferences.use(defaults)
        defaults.set(false, forKey: "autoGenerateTitle")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ConversationManagerTests")
        AppPreferences.reset()
        defaults = nil
        super.tearDown()
    }

    @MainActor
    func makeManager(directory: URL, keychain: KeychainStoring? = nil, keyIdentifier: String? = nil) -> ConversationManager {
        let keychainToUse = keychain ?? InMemoryKeychainStorage()
        let keyId = keyIdentifier ?? UUID().uuidString
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychainToUse)
        return ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
    }

    @MainActor
    func testCreateNewConversationUsesSelectedModel() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let expectedModel = "unit-test-model"

        OpenAIService.shared.selectedModel = expectedModel
        let manager = makeManager(directory: directory)
        manager.createNewConversation()

        XCTAssertEqual(manager.conversations.count, 1)
        XCTAssertEqual(manager.conversations.first?.model, expectedModel)
    }

    @MainActor
    func testAddMessageAppendsAndUpdatesTimestamp() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        guard let conversation = manager.conversations.first else {
            return XCTFail("Conversation missing")
        }

        let message = Message(role: .user, content: "Ping")
        manager.addMessage(to: conversation, message: message)

        XCTAssertEqual(manager.conversations.first?.messages.count, 1)
        XCTAssertEqual(manager.conversations.first?.messages.first?.content, "Ping")
    }

    @MainActor
    func testClearAllConversationsEmptiesEncryptedStore() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let store = TestHelpers.makeTestStore(directory: directory, keychain: keychain)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        manager.conversations = [TestHelpers.sampleConversation()]
        try await store.save(manager.conversations)

        manager.clearAllConversations()

        // Wait for async clear
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(manager.conversations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversations.enc").path))
    }

    @MainActor
    func testSearchFindsMatchesInTitleAndMessages() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)

        var first = TestHelpers.sampleConversation(title: "Swift Tips")
        first.messages[0].content = "How to use SwiftUI?"
        var second = TestHelpers.sampleConversation(title: "Random Chat")
        second.messages[0].content = "Discussing movies"
        manager.conversations = [first, second]

        let titleResults = manager.searchConversations(query: "Swift")
        let bodyResults = manager.searchConversations(query: "movies")

        XCTAssertEqual(titleResults.count, 1)
        XCTAssertEqual(titleResults.first?.title, "Swift Tips")
        XCTAssertEqual(bodyResults.count, 1)
        XCTAssertEqual(bodyResults.first?.title, "Random Chat")
    }

    @MainActor
    func testSaveImmediatelyPersistsManualChanges() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-key-id"
        let manager = makeManager(directory: directory, keychain: keychain, keyIdentifier: keyId)

        manager.createNewConversation()
        guard let conversation = manager.conversations.first else {
            return XCTFail("Conversation missing")
        }

        // Manually update the conversation in the array (simulating what ChatView does with chunks)
        if let index = manager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            manager.conversations[index].messages.append(Message(role: .assistant, content: "Partial content"))
        }

        // Save immediately
        let saveTask = manager.saveImmediately(manager.conversations.first!)

        // Wait for the save task to complete
        _ = await saveTask.value

        // Create a new manager to load from disk using the SAME keychain and keyIdentifier
        let newManager = makeManager(directory: directory, keychain: keychain, keyIdentifier: keyId)
        _ = await newManager.loadingTask?.value

        XCTAssertEqual(newManager.conversations.count, 1)
        XCTAssertEqual(newManager.conversations.first?.messages.last?.content, "Partial content")
    }
}
