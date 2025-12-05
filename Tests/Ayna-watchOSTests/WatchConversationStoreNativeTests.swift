//
//  WatchConversationStoreNativeTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for WatchConversationStore running natively on watchOS
//

@testable import Ayna_watchOS_Watch_App
import XCTest

@MainActor
final class WatchConversationStoreNativeTests: XCTestCase {
    private var store: WatchConversationStore!
    private let testDefaultsKey = "com.sertacozercan.ayna.watch.conversations.test"

    override func setUp() async throws {
        // Clear any existing test data
        UserDefaults.standard.removeObject(forKey: testDefaultsKey)
        // Note: WatchConversationStore.shared is a singleton, so we test through it
        store = WatchConversationStore.shared
        // Clear existing conversations for clean test state
        store.updateConversations([])
    }

    override func tearDown() async throws {
        // Clean up
        store.updateConversations([])
        UserDefaults.standard.removeObject(forKey: testDefaultsKey)
        store = nil
    }

    // MARK: - Conversation Creation Tests

    func testCreateConversation() {
        let conversation = store.createConversation(title: "Test Chat", model: "gpt-4o")

        XCTAssertEqual(conversation.title, "Test Chat")
        XCTAssertEqual(conversation.model, "gpt-4o")
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertTrue(store.conversations.contains { $0.id == conversation.id })
    }

    func testCreateConversationWithDefaultTitle() {
        let conversation = store.createConversation(model: "gpt-4")

        XCTAssertEqual(conversation.title, "New Chat")
        XCTAssertEqual(conversation.model, "gpt-4")
    }

    func testNewConversationAppearsFirst() {
        // Create first conversation
        let first = store.createConversation(model: "gpt-4o")

        // Wait a bit to ensure different timestamps
        Thread.sleep(forTimeInterval: 0.1)

        // Create second conversation
        let second = store.createConversation(model: "gpt-4")

        // Second should be at index 0 (most recent)
        XCTAssertEqual(store.conversations.first?.id, second.id)
        XCTAssertTrue(store.conversations.contains { $0.id == first.id })
    }

    // MARK: - Message Management Tests

    func testAddMessageToConversation() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .user, content: "Hello"))

        store.addMessage(message, to: conversation.id)

        let updated = store.conversation(for: conversation.id)
        XCTAssertEqual(updated?.messages.count, 1)
        XCTAssertEqual(updated?.messages.first?.content, "Hello")
        XCTAssertEqual(updated?.messages.first?.role, "user")
    }

    func testAddMultipleMessages() {
        let conversation = store.createConversation(model: "gpt-4o")

        let userMessage = WatchMessage(from: Message(role: .user, content: "Hi"))
        let assistantMessage = WatchMessage(from: Message(role: .assistant, content: "Hello!"))

        store.addMessage(userMessage, to: conversation.id)
        store.addMessage(assistantMessage, to: conversation.id)

        let updated = store.conversation(for: conversation.id)
        XCTAssertEqual(updated?.messages.count, 2)
        XCTAssertEqual(updated?.messages[0].role, "user")
        XCTAssertEqual(updated?.messages[1].role, "assistant")
    }

    func testUpdateLastMessage() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .assistant, content: ""))

        store.addMessage(message, to: conversation.id)
        store.updateLastMessage(in: conversation.id, content: "Streaming content...")

        let updated = store.conversation(for: conversation.id)
        XCTAssertEqual(updated?.messages.last?.content, "Streaming content...")
    }

    func testUpdateLastMessageStreaming() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .assistant, content: ""))

        store.addMessage(message, to: conversation.id)

        // Simulate streaming updates
        store.updateLastMessage(in: conversation.id, content: "Hello")
        store.updateLastMessage(in: conversation.id, content: "Hello, ")
        store.updateLastMessage(in: conversation.id, content: "Hello, World!")

        let updated = store.conversation(for: conversation.id)
        XCTAssertEqual(updated?.messages.last?.content, "Hello, World!")
    }

    // MARK: - Conversation Retrieval Tests

    func testConversationForValidId() {
        let conversation = store.createConversation(model: "gpt-4o")

        let retrieved = store.conversation(for: conversation.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, conversation.id)
    }

    func testConversationForInvalidId() {
        let randomId = UUID()
        let retrieved = store.conversation(for: randomId)

        XCTAssertNil(retrieved)
    }

    // MARK: - Preview Text Tests

    func testPreviewTextWithMessages() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .assistant, content: "This is a response"))

        store.addMessage(message, to: conversation.id)

        if let updated = store.conversation(for: conversation.id) {
            let preview = store.previewText(for: updated)
            XCTAssertEqual(preview, "This is a response")
        } else {
            XCTFail("Conversation should exist")
        }
    }

    func testPreviewTextWithLongMessage() {
        let conversation = store.createConversation(model: "gpt-4o")
        let longContent = String(repeating: "A", count: 100)
        let message = WatchMessage(from: Message(role: .assistant, content: longContent))

        store.addMessage(message, to: conversation.id)

        if let updated = store.conversation(for: conversation.id) {
            let preview = store.previewText(for: updated)
            XCTAssertTrue(preview.count <= 53) // 50 chars + "..."
            XCTAssertTrue(preview.hasSuffix("..."))
        } else {
            XCTFail("Conversation should exist")
        }
    }

    func testPreviewTextEmptyConversation() {
        let conversation = store.createConversation(model: "gpt-4o")

        let preview = store.previewText(for: conversation)
        XCTAssertEqual(preview, "No messages")
    }

    // MARK: - Delete Tests

    func testDeleteConversation() {
        let conversation = store.createConversation(model: "gpt-4o")
        XCTAssertTrue(store.conversations.contains { $0.id == conversation.id })

        store.deleteConversation(conversation.id)

        XCTAssertFalse(store.conversations.contains { $0.id == conversation.id })
        XCTAssertNil(store.conversation(for: conversation.id))
    }

    func testDeleteConversationClearsSelection() {
        let conversation = store.createConversation(model: "gpt-4o")
        store.selectedConversationId = conversation.id

        store.deleteConversation(conversation.id)

        XCTAssertNil(store.selectedConversationId)
    }

    // MARK: - Rename Tests

    func testRenameConversation() {
        let conversation = store.createConversation(title: "Original", model: "gpt-4o")

        store.renameConversation(conversation.id, newTitle: "Renamed Chat")

        let updated = store.conversation(for: conversation.id)
        XCTAssertEqual(updated?.title, "Renamed Chat")
    }

    // MARK: - Update Conversations Tests

    func testUpdateConversationsMerge() {
        // Create a local conversation
        let local = store.createConversation(title: "Local Chat", model: "gpt-4o")

        // Simulate sync from iPhone with a new conversation
        let remoteId = UUID()
        let remote = WatchConversation(
            from: Conversation(id: remoteId, title: "Remote Chat", model: "gpt-4")
        )

        store.updateConversations([remote])

        // Both should exist
        XCTAssertNotNil(store.conversation(for: local.id))
        XCTAssertNotNil(store.conversation(for: remoteId))
    }

    func testUpdateConversationsPreservesLocalTitle() {
        // Create a local conversation with generated title
        let conversation = store.createConversation(title: "Generated Title", model: "gpt-4o")

        // Simulate sync from iPhone with "New Chat" title (not yet generated on iPhone)
        let syncedConversation = WatchConversation(
            from: Conversation(id: conversation.id, title: "New Chat", model: "gpt-4o")
        )

        store.updateConversations([syncedConversation])

        // Local title should be preserved
        let updated = store.conversation(for: conversation.id)
        XCTAssertEqual(updated?.title, "Generated Title")
    }

    func testUpdateConversationsPreservesLocalMessages() {
        // Create a local conversation with messages
        let conversation = store.createConversation(model: "gpt-4o")
        let userMsg = WatchMessage(from: Message(role: .user, content: "Hello"))
        let assistantMsg = WatchMessage(from: Message(role: .assistant, content: "Hi!"))
        store.addMessage(userMsg, to: conversation.id)
        store.addMessage(assistantMsg, to: conversation.id)

        // Simulate sync from iPhone with fewer messages (iPhone behind during streaming)
        var syncedConversation = WatchConversation(
            from: Conversation(id: conversation.id, title: "New Chat", model: "gpt-4o")
        )
        syncedConversation.messages = [userMsg] // Only 1 message

        store.updateConversations([syncedConversation])

        // Local messages should be preserved (we have more)
        let updated = store.conversation(for: conversation.id)
        XCTAssertEqual(updated?.messages.count, 2)
    }

    func testUpdateConversationsSortsByRecent() {
        // Create conversations
        let older = store.createConversation(title: "Older", model: "gpt-4o")
        Thread.sleep(forTimeInterval: 0.1)
        let newer = store.createConversation(title: "Newer", model: "gpt-4o")

        // Verify newer is first
        XCTAssertEqual(store.conversations.first?.id, newer.id)

        // Update older conversation to have newer updatedAt
        var updatedOlder = WatchConversation(
            from: Conversation(id: older.id, title: "Older Updated", model: "gpt-4o")
        )
        updatedOlder.updatedAt = Date()

        store.updateConversations([updatedOlder])

        // Older should now be first (most recently updated)
        XCTAssertEqual(store.conversations.first?.id, older.id)
    }
}
