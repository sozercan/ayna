@testable import Ayna
import Foundation
import Testing

@Suite("ConversationManager Tests", .tags(.viewModel, .persistence), .serialized)
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

        let clearing = manager.clearAllConversations()
        await clearing.value
        await manager.flushPendingSaves()

        #expect(manager.conversations.isEmpty)
        #expect(try await store.loadConversations().isEmpty)
    }

    @Test("Failed delete and clear roll back optimistic UI without losing newer state")
    @MainActor
    func persistenceFailuresRollBackOptimisticUI() async throws {
        AIService.keychain = InMemoryKeychainStorage()
        let previousModels = AIService.shared.customModels
        let model = AIService.shared.selectedModel
        if !AIService.shared.customModels.contains(model) {
            AIService.shared.customModels.append(model)
        }
        defer { AIService.shared.customModels = previousModels }

        let deleted = Conversation(title: "Keep me", model: model)
        let deleteStore = ScriptedConversationStore(conversations: [deleted])
        let deleteManager = ConversationManager(store: deleteStore)
        _ = await deleteManager.loadingTask?.value
        let deleteGate = await deleteStore.enqueue(.delete(deleted.id), outcome: .fail, blocked: true)
        let deleteRepair = await deleteStore.enqueue(.save(deleted.id, nil), blocked: true)
        deleteManager.selectedConversationId = deleted.id
        let deleteTarget = try #require(deleteManager.conversations.first)
        let deleteRollback = try #require(deleteManager.deleteConversation(deleteTarget))
        await deleteGate.started.wait()
        #expect(deleteManager.conversations.isEmpty)
        await deleteGate.releaseGate.open()
        await deleteRollback.value
        #expect(deleteManager.conversations == [deleted])
        #expect(deleteManager.selectedConversationId == deleted.id)
        await deleteRepair.started.wait()
        await deleteRepair.releaseGate.open()
        await deleteManager.flushPendingSaves()

        let beforeClear = Conversation(title: "Before clear", model: model)
        let clearStore = ScriptedConversationStore(conversations: [beforeClear])
        let clearManager = ConversationManager(store: clearStore, saveDebounceDuration: .seconds(30))
        _ = await clearManager.loadingTask?.value
        let clearGate = await clearStore.enqueue(.clear, outcome: .fail, blocked: true)
        clearManager.selectedConversationId = beforeClear.id
        let clearRollback = clearManager.clearAllConversations()
        await clearGate.started.wait()
        clearManager.createNewConversation(title: "After clear")
        let created = try #require(clearManager.conversations.first)
        clearManager.selectedConversationId = created.id
        let saveGate = await clearStore.enqueue(.save(created.id, nil))
        let clearRepair = await clearStore.enqueue(.clear, blocked: true)
        _ = clearManager.saveImmediately(created)
        await clearGate.releaseGate.open()
        await saveGate.started.wait()
        await clearRollback.value
        #expect(Set(clearManager.conversations.map(\.id)) == Set([beforeClear.id, created.id]))
        #expect(clearManager.selectedConversationId == created.id)
        await clearRepair.started.wait()
        await clearRepair.releaseGate.open()
        await clearManager.flushPendingSaves()
    }

    @Test("Failed clear does not override a newer new-chat selection")
    @MainActor
    func failedClearPreservesNewChatSelection() async throws {
        let model = AIService.shared.selectedModel
        let existing = Conversation(title: "Existing", model: model)
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        manager.selectedConversationId = existing.id

        let clearGate = await store.enqueue(.clear, outcome: .fail, blocked: true)
        _ = await store.enqueue(.clear)
        let rollback = manager.clearAllConversations()
        await clearGate.started.wait()

        // Reassigning nil represents a newer explicit switch to New Chat.
        manager.selectedConversationId = nil
        await clearGate.releaseGate.open()
        await rollback.value

        #expect(manager.conversations.contains(where: { $0.id == existing.id }))
        #expect(manager.selectedConversationId == nil)
        await manager.flushPendingSaves()
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

        // Confirm it's not on disk yet (debounce is long)
        let diskBefore = try await store.loadConversations()
        #expect(diskBefore.isEmpty)

        await manager.reloadConversations()

        #expect(manager.conversations.contains(where: { $0.id == dirty.id }))

        manager.clearAllConversations()
        await manager.flushPendingSaves()
    }

    @Test("Dirty memory wins load, then removed model repair is persisted")
    @MainActor
    func dirtyMemoryWithRemovedModelMergesRepair() async throws {
        AIService.keychain = InMemoryKeychainStorage()
        let previousModels = AIService.shared.customModels
        let previousSelection = AIService.shared.selectedModel
        defer {
            AIService.shared.customModels = previousModels
            AIService.shared.selectedModel = previousSelection
        }

        let defaultModel = "available-model"
        AIService.shared.customModels = [defaultModel]
        AIService.shared.selectedModel = defaultModel

        let id = UUID()
        let disk = Conversation(id: id, title: "Disk", model: defaultModel)
        let dirty = Conversation(id: id, title: "Dirty", model: "removed-model")
        let store = ScriptedConversationStore(conversations: [disk])
        let loadGate = await store.enqueue(.load, outcome: .load([disk]), blocked: true)
        _ = await store.enqueue(.save(id, "Dirty"))

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(30))
        await loadGate.started.wait()
        manager.conversations = [dirty]
        manager.save(dirty)
        await loadGate.releaseGate.open()
        _ = await manager.loadingTask?.value
        await manager.flushPendingSaves()

        let merged = try #require(manager.conversations.first)
        #expect(merged.title == "Dirty")
        #expect(merged.model == defaultModel)
        let persisted = try #require(await store.persistedConversations().first)
        #expect(persisted.title == "Dirty")
        #expect(persisted.model == defaultModel)
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
