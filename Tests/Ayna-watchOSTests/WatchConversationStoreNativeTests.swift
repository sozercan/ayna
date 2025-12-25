//
//  WatchConversationStoreNativeTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for WatchConversationStore running natively on watchOS
//

@testable import Ayna_watchOS_Watch_App
import Foundation
import Testing

@Suite("WatchConversationStore Native Tests")
@MainActor
struct WatchConversationStoreNativeTests {
    private var store: WatchConversationStore
    private let testDefaultsKey = "com.sertacozercan.ayna.watch.conversations.test"

    init() {
        // Clear any existing test data
        UserDefaults.standard.removeObject(forKey: testDefaultsKey)
        // Note: WatchConversationStore.shared is a singleton, so we test through it
        store = WatchConversationStore.shared
        // Clear existing conversations for clean test state
        store.updateConversations([])
    }

    // MARK: - Conversation Creation Tests

    @Test("Create conversation with title and model")
    func createConversation() {
        let conversation = store.createConversation(title: "Test Chat", model: "gpt-4o")

        #expect(conversation.title == "Test Chat")
        #expect(conversation.model == "gpt-4o")
        #expect(conversation.messages.isEmpty)
        #expect(store.conversations.contains { $0.id == conversation.id })
    }

    @Test("Create conversation with default title")
    func createConversationWithDefaultTitle() {
        let conversation = store.createConversation(model: "gpt-4")

        #expect(conversation.title == "New Chat")
        #expect(conversation.model == "gpt-4")
    }

    @Test("New conversation appears first")
    func newConversationAppearsFirst() async {
        // Create first conversation
        let first = store.createConversation(model: "gpt-4o")

        // Wait a bit to ensure different timestamps
        try? await Task.sleep(for: .milliseconds(100))

        // Create second conversation
        let second = store.createConversation(model: "gpt-4")

        // Second should be at index 0 (most recent)
        #expect(store.conversations.first?.id == second.id)
        #expect(store.conversations.contains { $0.id == first.id })
    }

    // MARK: - Message Management Tests

    @Test("Add message to conversation")
    func addMessageToConversation() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .user, content: "Hello"))

        store.addMessage(message, to: conversation.id)

        let updated = store.conversation(for: conversation.id)
        #expect(updated?.messages.count == 1)
        #expect(updated?.messages.first?.content == "Hello")
        #expect(updated?.messages.first?.role == "user")
    }

    @Test("Add multiple messages")
    func addMultipleMessages() {
        let conversation = store.createConversation(model: "gpt-4o")

        let userMessage = WatchMessage(from: Message(role: .user, content: "Hi"))
        let assistantMessage = WatchMessage(from: Message(role: .assistant, content: "Hello!"))

        store.addMessage(userMessage, to: conversation.id)
        store.addMessage(assistantMessage, to: conversation.id)

        let updated = store.conversation(for: conversation.id)
        #expect(updated?.messages.count == 2)
        #expect(updated?.messages[0].role == "user")
        #expect(updated?.messages[1].role == "assistant")
    }

    @Test("Update last message")
    func updateLastMessage() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .assistant, content: ""))

        store.addMessage(message, to: conversation.id)
        store.updateLastMessage(in: conversation.id, content: "Streaming content...")

        let updated = store.conversation(for: conversation.id)
        #expect(updated?.messages.last?.content == "Streaming content...")
    }

    @Test("Update last message streaming")
    func updateLastMessageStreaming() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .assistant, content: ""))

        store.addMessage(message, to: conversation.id)

        // Simulate streaming updates
        store.updateLastMessage(in: conversation.id, content: "Hello")
        store.updateLastMessage(in: conversation.id, content: "Hello, ")
        store.updateLastMessage(in: conversation.id, content: "Hello, World!")

        let updated = store.conversation(for: conversation.id)
        #expect(updated?.messages.last?.content == "Hello, World!")
    }

    // MARK: - Conversation Retrieval Tests

    @Test("Get conversation for valid ID")
    func conversationForValidId() {
        let conversation = store.createConversation(model: "gpt-4o")

        let retrieved = store.conversation(for: conversation.id)

        #expect(retrieved != nil)
        #expect(retrieved?.id == conversation.id)
    }

    @Test("Get conversation for invalid ID returns nil")
    func conversationForInvalidId() {
        let randomId = UUID()
        let retrieved = store.conversation(for: randomId)

        #expect(retrieved == nil)
    }

    // MARK: - Preview Text Tests

    @Test("Preview text with messages")
    func previewTextWithMessages() {
        let conversation = store.createConversation(model: "gpt-4o")
        let message = WatchMessage(from: Message(role: .assistant, content: "This is a response"))

        store.addMessage(message, to: conversation.id)

        if let updated = store.conversation(for: conversation.id) {
            let preview = store.previewText(for: updated)
            #expect(preview == "This is a response")
        } else {
            Issue.record("Conversation should exist")
        }
    }

    @Test("Preview text with long message truncates")
    func previewTextWithLongMessage() {
        let conversation = store.createConversation(model: "gpt-4o")
        let longContent = String(repeating: "A", count: 100)
        let message = WatchMessage(from: Message(role: .assistant, content: longContent))

        store.addMessage(message, to: conversation.id)

        if let updated = store.conversation(for: conversation.id) {
            let preview = store.previewText(for: updated)
            #expect(preview.count <= 53) // 50 chars + "..."
            #expect(preview.hasSuffix("..."))
        } else {
            Issue.record("Conversation should exist")
        }
    }

    @Test("Preview text for empty conversation")
    func previewTextEmptyConversation() {
        let conversation = store.createConversation(model: "gpt-4o")

        let preview = store.previewText(for: conversation)
        #expect(preview == "No messages")
    }

    // MARK: - Delete Tests

    @Test("Delete conversation")
    func deleteConversation() {
        let conversation = store.createConversation(model: "gpt-4o")
        #expect(store.conversations.contains { $0.id == conversation.id })

        store.deleteConversation(conversation.id)

        #expect(!store.conversations.contains { $0.id == conversation.id })
        #expect(store.conversation(for: conversation.id) == nil)
    }

    @Test("Delete conversation clears selection")
    func deleteConversationClearsSelection() {
        let conversation = store.createConversation(model: "gpt-4o")
        store.selectedConversationId = conversation.id

        store.deleteConversation(conversation.id)

        #expect(store.selectedConversationId == nil)
    }

    // MARK: - Rename Tests

    @Test("Rename conversation")
    func renameConversation() {
        let conversation = store.createConversation(title: "Original", model: "gpt-4o")

        store.renameConversation(conversation.id, newTitle: "Renamed Chat")

        let updated = store.conversation(for: conversation.id)
        #expect(updated?.title == "Renamed Chat")
    }

    // MARK: - Update Conversations Tests

    @Test("Update conversations merges with remote")
    func updateConversationsMerge() {
        // Create a local conversation
        let local = store.createConversation(title: "Local Chat", model: "gpt-4o")

        // Simulate sync from iPhone with a new conversation
        let remoteId = UUID()
        let remote = WatchConversation(
            from: Conversation(id: remoteId, title: "Remote Chat", model: "gpt-4")
        )

        store.updateConversations([remote])

        // Both should exist
        #expect(store.conversation(for: local.id) != nil)
        #expect(store.conversation(for: remoteId) != nil)
    }

    @Test("Update conversations preserves local title")
    func updateConversationsPreservesLocalTitle() {
        // Create a local conversation with generated title
        let conversation = store.createConversation(title: "Generated Title", model: "gpt-4o")

        // Simulate sync from iPhone with "New Chat" title (not yet generated on iPhone)
        let syncedConversation = WatchConversation(
            from: Conversation(id: conversation.id, title: "New Chat", model: "gpt-4o")
        )

        store.updateConversations([syncedConversation])

        // Local title should be preserved
        let updated = store.conversation(for: conversation.id)
        #expect(updated?.title == "Generated Title")
    }

    @Test("Update conversations preserves local messages")
    func updateConversationsPreservesLocalMessages() {
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
        #expect(updated?.messages.count == 2)
    }

    @Test("Update conversations sorts by recent")
    func updateConversationsSortsByRecent() async {
        // Create conversations
        let older = store.createConversation(title: "Older", model: "gpt-4o")
        try? await Task.sleep(for: .milliseconds(100))
        let newer = store.createConversation(title: "Newer", model: "gpt-4o")

        // Verify newer is first
        #expect(store.conversations.first?.id == newer.id)

        // Update older conversation to have newer updatedAt
        var updatedOlder = WatchConversation(
            from: Conversation(id: older.id, title: "Older Updated", model: "gpt-4o")
        )
        updatedOlder.updatedAt = Date()

        store.updateConversations([updatedOlder])

        // Older should now be first (most recently updated)
        #expect(store.conversations.first?.id == older.id)
    }
}
