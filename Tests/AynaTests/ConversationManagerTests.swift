@testable import Ayna
import Foundation
import Testing

@Suite("ConversationManager Tests", .tags(.viewModel, .persistence))
struct ConversationManagerTests {
    private var defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: "ConversationManagerTests") else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "ConversationManagerTests")
        AppPreferences.use(defaults)
        defaults.set(false, forKey: "autoGenerateTitle")
    }

    @MainActor
    private func makeManager(directory: URL, keychain: KeychainStoring? = nil, keyIdentifier: String? = nil) -> ConversationManager {
        let keychainToUse = keychain ?? InMemoryKeychainStorage()
        let keyId = keyIdentifier ?? UUID().uuidString
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychainToUse)
        return ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
    }

    @Test("Create new conversation uses selected model")
    @MainActor
    func createNewConversationUsesSelectedModel() throws {
        AIService.keychain = InMemoryKeychainStorage()
        let directory = try TestHelpers.makeTemporaryDirectory()
        let expectedModel = "unit-test-model"

        AIService.shared.selectedModel = expectedModel
        let manager = makeManager(directory: directory)
        manager.createNewConversation()

        #expect(manager.conversations.count == 1)
        #expect(manager.conversations.first?.model == expectedModel)
    }

    @Test("Add message appends and updates timestamp")
    @MainActor
    func addMessageAppendsAndUpdatesTimestamp() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .user, content: "Ping")
        manager.addMessage(to: conversation, message: message)

        #expect(manager.conversations.first?.messages.count == 1)
        #expect(manager.conversations.first?.messages.first?.content == "Ping")
    }

    @Test("Clear all conversations empties encrypted store")
    @MainActor
    func clearAllConversationsEmptiesEncryptedStore() async throws {
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

        #expect(manager.conversations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversations.enc").path))
    }

    @Test("Search finds matches in title and messages")
    @MainActor
    func searchFindsMatchesInTitleAndMessages() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)

        var first = TestHelpers.sampleConversation(title: "Swift Tips")
        first.messages[0].content = "How to use SwiftUI?"
        var second = TestHelpers.sampleConversation(title: "Random Chat")
        second.messages[0].content = "Discussing movies"
        manager.conversations = [first, second]

        let titleResults = manager.searchConversations(query: "Swift")
        let bodyResults = manager.searchConversations(query: "movies")

        #expect(titleResults.count == 1)
        #expect(titleResults.first?.title == "Swift Tips")
        #expect(bodyResults.count == 1)
        #expect(bodyResults.first?.title == "Random Chat")
    }

    @Test("Save immediately persists manual changes")
    @MainActor
    func saveImmediatelyPersistsManualChanges() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-key-id"
        let manager = makeManager(directory: directory, keychain: keychain, keyIdentifier: keyId)

        // Create conversation directly without triggering debounced save
        let conversation = Conversation(title: "Test Conversation", model: "test-model")
        manager.conversations.insert(conversation, at: 0)

        // Manually update the conversation in the array (simulating what ChatView does with chunks)
        if let index = manager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            manager.conversations[index].messages.append(Message(role: .assistant, content: "Partial content"))
        }

        // Save immediately
        let saveTask = try manager.saveImmediately(#require(manager.conversations.first))

        // Wait for the save task to complete
        _ = await saveTask.value

        // Create a new manager to load from disk using the SAME keychain and keyIdentifier
        let newManager = makeManager(directory: directory, keychain: keychain, keyIdentifier: keyId)
        _ = await newManager.loadingTask?.value

        #expect(newManager.conversations.count == 1)
        #expect(newManager.conversations.first?.messages.last?.content == "Partial content")
    }

    @Test("Reload conversations removes stale non-dirty conversations")
    @MainActor
    func reloadConversationsRemovesStaleNonDirtyConversations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-reconcile-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)

        let kept = TestHelpers.sampleConversation(title: "Kept")
        try await store.save([kept])

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.count == 1)
        #expect(manager.conversations.first?.id == kept.id)

        let stale = TestHelpers.sampleConversation(title: "Stale")
        manager.conversations.append(stale)
        #expect(manager.conversations.count == 2)

        await manager.reloadConversations()

        #expect(manager.conversations.contains(where: { $0.id == kept.id }))
        #expect(!manager.conversations.contains(where: { $0.id == stale.id }))
    }

    @Test("Reload conversations preserves dirty in-memory conversations not yet on disk")
    @MainActor
    func reloadConversationsPreservesDirtyInMemoryConversationsNotYetOnDisk() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-dirty-wins-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        let dirty = TestHelpers.sampleConversation(title: "Dirty")
        manager.conversations = [dirty]
        manager.save(dirty)

        // Give the save() Task time to enqueue the pending save.
        try await Task.sleep(for: .milliseconds(50))

        // Confirm it's not on disk yet (debounce is long)
        let diskBefore = try await store.loadConversations()
        #expect(diskBefore.isEmpty)

        await manager.reloadConversations()

        #expect(manager.conversations.contains(where: { $0.id == dirty.id }))

        // Clean up pending saves to avoid test cross-talk.
        manager.clearAllConversations()
    }

    @Test("ID-based message update persists through reload")
    @MainActor
    func idBasedMessageUpdatePersistsThroughReload() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-id-update-persistence-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let original = TestHelpers.sampleConversation(title: "Terminal Update")
        let messageId = try #require(original.messages.last?.id)
        try await store.save(original)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        let updated = manager.updateMessage(conversationId: original.id, messageId: messageId) { message in
            message.content = "Saved terminal content"
        }
        #expect(updated)

        try await Task.sleep(for: .milliseconds(100))
        await manager.flushPendingSaves()

        let reloadedManager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await reloadedManager.loadingTask?.value

        let reloadedConversation = try #require(reloadedManager.conversation(byId: original.id))
        #expect(reloadedConversation.messages.last?.content == "Saved terminal content")
    }

    @Test("ID-based message removal persists through reload")
    @MainActor
    func idBasedMessageRemovalPersistsThroughReload() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-id-remove-persistence-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let original = TestHelpers.sampleConversation(title: "Terminal Remove")
        let messageIdToRemove = try #require(original.messages.last?.id)
        try await store.save(original)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        let removed = manager.removeMessage(conversationId: original.id, messageId: messageIdToRemove)
        #expect(removed)

        try await Task.sleep(for: .milliseconds(100))
        await manager.flushPendingSaves()

        let reloadedManager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await reloadedManager.loadingTask?.value

        let reloadedConversation = try #require(reloadedManager.conversation(byId: original.id))
        #expect(!reloadedConversation.messages.contains(where: { $0.id == messageIdToRemove }))
    }

    @Test("ID-based response group status update persists through reload")
    @MainActor
    func idBasedResponseGroupStatusUpdatePersistsThroughReload() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-id-response-group-persistence-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let assistantMessage = Message(role: .assistant, content: "Streaming", model: "test-model")
        var original = Conversation(title: "Terminal Group", model: "test-model")
        let userMessage = Message(role: .user, content: "Compare")
        original.addMessage(userMessage)
        original.addMessage(assistantMessage)
        let responseGroup = ResponseGroup(
            userMessageId: userMessage.id,
            responses: [
                ResponseGroup.ResponseEntry(
                    id: assistantMessage.id,
                    modelName: "test-model",
                    status: .streaming
                )
            ]
        )
        original.addResponseGroup(responseGroup)
        try await store.save(original)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        let updated = manager.updateResponseGroupStatus(
            conversationId: original.id,
            responseGroupId: responseGroup.id,
            messageId: assistantMessage.id,
            status: .completed
        )
        #expect(updated)

        try await Task.sleep(for: .milliseconds(100))
        await manager.flushPendingSaves()

        let reloadedManager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await reloadedManager.loadingTask?.value

        let reloadedConversation = try #require(reloadedManager.conversation(byId: original.id))
        let reloadedGroup = try #require(reloadedConversation.getResponseGroup(responseGroup.id))
        #expect(reloadedGroup.responses.first?.status == .completed)
    }


    @Test("Terminal response-group status persists accumulated streamed chunks")
    @MainActor
    func terminalResponseGroupStatusPersistsAccumulatedStreamedChunks() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-terminal-status-saves-streamed-content-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let assistantMessage = Message(role: .assistant, content: "", model: "test-model")
        var original = Conversation(title: "Stream Then Complete", model: "test-model")
        let userMessage = Message(role: .user, content: "Compare")
        original.addMessage(userMessage)
        original.addMessage(assistantMessage)
        let responseGroup = ResponseGroup(
            userMessageId: userMessage.id,
            responses: [
                ResponseGroup.ResponseEntry(
                    id: assistantMessage.id,
                    modelName: "test-model",
                    status: .streaming
                )
            ]
        )
        original.addResponseGroup(responseGroup)
        try await store.save(original)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        #expect(manager.appendToMessage(conversationId: original.id, messageId: assistantMessage.id, chunk: "Hello"))
        #expect(manager.appendToMessage(conversationId: original.id, messageId: assistantMessage.id, chunk: " world"))
        #expect(manager.updateResponseGroupStatus(
            conversationId: original.id,
            responseGroupId: responseGroup.id,
            messageId: assistantMessage.id,
            status: .completed
        ))

        try await Task.sleep(for: .milliseconds(100))
        await manager.flushPendingSaves()

        let reloadedManager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await reloadedManager.loadingTask?.value

        let reloadedConversation = try #require(reloadedManager.conversation(byId: original.id))
        let reloadedMessage = try #require(reloadedConversation.messages.first(where: { $0.id == assistantMessage.id }))
        let reloadedGroup = try #require(reloadedConversation.getResponseGroup(responseGroup.id))
        #expect(reloadedMessage.content == "Hello world")
        #expect(reloadedGroup.responses.first?.status == .completed)
    }

    @Test("Response-group status update fails for a message outside the group")
    @MainActor
    func responseGroupStatusUpdateFailsForMessageOutsideGroup() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-response-group-member-guard-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let assistantMessage = Message(role: .assistant, content: "Streaming", model: "test-model")
        var original = Conversation(title: "Missing Entry", model: "test-model")
        let userMessage = Message(role: .user, content: "Compare")
        original.addMessage(userMessage)
        original.addMessage(assistantMessage)
        let responseGroup = ResponseGroup(
            userMessageId: userMessage.id,
            responses: [
                ResponseGroup.ResponseEntry(
                    id: assistantMessage.id,
                    modelName: "test-model",
                    status: .streaming
                )
            ]
        )
        original.addResponseGroup(responseGroup)
        try await store.save(original)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        let updated = manager.updateResponseGroupStatus(
            conversationId: original.id,
            responseGroupId: responseGroup.id,
            messageId: UUID(),
            status: .completed
        )
        #expect(!updated)

        await manager.flushPendingSaves()

        let reloadedManager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await reloadedManager.loadingTask?.value

        let reloadedConversation = try #require(reloadedManager.conversation(byId: original.id))
        let reloadedGroup = try #require(reloadedConversation.getResponseGroup(responseGroup.id))
        #expect(reloadedGroup.responses.first?.status == .streaming)
    }

    @Test("Streaming append remains deferred until explicit save")
    @MainActor
    func streamingAppendRemainsDeferredUntilExplicitSave() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-streaming-append-deferred-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let original = TestHelpers.sampleConversation(title: "Streaming Deferred")
        let messageId = try #require(original.messages.last?.id)
        try await store.save(original)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        let appended = manager.appendToMessage(
            conversationId: original.id,
            messageId: messageId,
            chunk: " plus streamed chunk"
        )
        #expect(appended)

        try await Task.sleep(for: .milliseconds(100))
        await manager.flushPendingSaves()

        let reloadedManager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await reloadedManager.loadingTask?.value
        let reloadedConversation = try #require(reloadedManager.conversation(byId: original.id))
        #expect(reloadedConversation.messages.last?.content == original.messages.last?.content)

        let currentConversation = try #require(manager.conversation(byId: original.id))
        _ = await manager.saveImmediately(currentConversation).value

        let savedManager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await savedManager.loadingTask?.value
        let savedConversation = try #require(savedManager.conversation(byId: original.id))
        #expect(savedConversation.messages.last?.content == "Hi there plus streamed chunk")
    }

    // MARK: - Edit Message Tests

    @Test("Edit message updates content and marks as edited")
    @MainActor
    func editMessageUpdatesContentAndMarksAsEdited() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .user, content: "Original content")
        manager.addMessage(to: conversation, message: message)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: message.id,
            newContent: "Edited content"
        )

        #expect(editResult == true)
        #expect(manager.conversations.first?.messages.first?.content == "Edited content")
        #expect(manager.conversations.first?.messages.first?.isEdited == true)
        #expect(manager.conversations.first?.messages.first?.editedAt != nil)
    }

    @Test("Edit message removes subsequent messages")
    @MainActor
    func editMessageRemovesSubsequentMessages() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let userMessage = Message(role: .user, content: "What is 2+2?")
        manager.addMessage(to: conversation, message: userMessage)
        let assistantMessage = Message(role: .assistant, content: "2+2 = 4")
        manager.addMessage(to: conversation, message: assistantMessage)

        #expect(manager.conversations.first?.messages.count == 2)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: userMessage.id,
            newContent: "What is 3+3?"
        )

        #expect(editResult == true)
        #expect(manager.conversations.first?.messages.count == 1)
        #expect(manager.conversations.first?.messages.first?.content == "What is 3+3?")
        #expect(manager.conversations.first?.messages.first?.isEdited == true)
    }

    @Test("Edit message fails for assistant messages")
    @MainActor
    func editMessageFailsForAssistantMessages() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .assistant, content: "Assistant response")
        manager.addMessage(to: conversation, message: message)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: message.id,
            newContent: "Should not work"
        )

        #expect(editResult == false)
        #expect(manager.conversations.first?.messages.first?.content == "Assistant response")
        #expect(manager.conversations.first?.messages.first?.isEdited == false)
    }

    @Test("Edit message with same content does not mark as edited")
    @MainActor
    func editMessageWithSameContentDoesNotMarkAsEdited() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .user, content: "Same content")
        manager.addMessage(to: conversation, message: message)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: message.id,
            newContent: "Same content"
        )

        #expect(editResult == true)
        #expect(manager.conversations.first?.messages.first?.content == "Same content")
        #expect(manager.conversations.first?.messages.first?.isEdited == false)
    }

    @Test("Edit message fails for non-existent message")
    @MainActor
    func editMessageFailsForNonExistentMessage() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: UUID(),
            newContent: "Should not work"
        )

        #expect(editResult == false)
    }
}
