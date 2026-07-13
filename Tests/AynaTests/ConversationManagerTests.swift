// swiftlint:disable file_length
@testable import Ayna
import Foundation
import Testing

// swiftlint:disable identifier_name
@Suite("ConversationManager Tests", .tags(.viewModel, .persistence), .serialized)
// swiftlint:disable:next type_body_length
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

    @Test
    @MainActor
    func `Create new conversation uses selected model`() throws {
        AIService.keychain = InMemoryKeychainStorage()
        let directory = try TestHelpers.makeTemporaryDirectory()
        let expectedModel = "unit-test-model"

        AIService.shared.selectedModel = expectedModel
        let manager = makeManager(directory: directory)
        manager.createNewConversation()

        #expect(manager.conversations.count == 1)
        #expect(manager.conversations.first?.model == expectedModel)
    }

    @Test
    @MainActor
    func `Add message appends and updates timestamp`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .user, content: "Ping")
        manager.addMessage(to: conversation, message: message)

        #expect(manager.conversations.first?.messages.count == 1)
        #expect(manager.conversations.first?.messages.first?.content == "Ping")
    }

    @Test
    @MainActor
    func `Update message reports whether the target still exists`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)
        let message = Message(role: .assistant, content: "Pending")
        manager.addMessage(to: conversation, message: message)

        let updated = manager.updateMessage(in: conversation, messageId: message.id) { target in
            target.content = "Completed"
        }
        let missing = manager.updateMessage(in: conversation, messageId: UUID()) { target in
            target.content = "Unexpected"
        }

        #expect(updated)
        #expect(!missing)
        #expect(manager.conversations.first?.messages.first?.content == "Completed")
    }

    @Test
    @MainActor
    func `Appending streamed content advances the conversation revision`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)
        let message = Message(role: .assistant, content: "")
        manager.addMessage(to: conversation, message: message)
        let previousUpdate = try #require(manager.conversations.first?.updatedAt)
        try await Task.sleep(for: .milliseconds(2))

        let appended = manager.appendToMessage(
            conversationId: conversation.id,
            messageId: message.id,
            chunk: "stream"
        )

        #expect(appended)
        #expect(manager.conversations.first?.messages.first?.content == "stream")
        #expect(manager.conversations.first?.updatedAt ?? .distantPast > previousUpdate)
    }

    @Test
    @MainActor
    func `Clear all conversations empties encrypted store`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let store = TestHelpers.makeTestStore(directory: directory, keychain: keychain)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        #expect(manager.isConversationStateAuthoritative)
        manager.conversations = [TestHelpers.sampleConversation()]
        try await store.save(manager.conversations)

        let clearing = manager.clearAllConversations()
        await clearing.value
        await manager.flushPendingSaves()

        #expect(manager.conversations.isEmpty)
        #expect(try await store.loadConversations().isEmpty)
    }

    @Test
    @MainActor
    func `Failed initial load does not mark empty memory as authoritative`() async {
        let store = ScriptedConversationStore()
        _ = await store.enqueue(.load, outcome: .fail)
        let manager = ConversationManager(store: store, loadRetryBaseDelay: .seconds(30))

        _ = await manager.loadingTask?.value

        #expect(manager.conversations.isEmpty)
        #expect(!manager.isConversationStateAuthoritative)
    }

    @Test
    @MainActor
    func `Unreadable encrypted record does not publish a partial authoritative load`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let readable = TestHelpers.sampleConversation(title: "Readable")
        let unreadable = TestHelpers.sampleConversation(title: "Unreadable")
        try await store.save(readable)
        try await store.save(unreadable)
        try Data("corrupt encrypted record".utf8).write(
            to: store.fileURL(for: unreadable.id),
            options: .atomic
        )
        let manager = ConversationManager(
            store: store,
            loadRetryBaseDelay: .seconds(30)
        )

        _ = await manager.loadingTask?.value

        #expect(!manager.isConversationStateAuthoritative)
        #expect(manager.conversations.isEmpty)
    }

    @Test
    @MainActor
    func `Authoritative state wait blocks legacy ingress until initial load succeeds`() async {
        let stored = TestHelpers.sampleConversation(title: "Loaded before legacy ingress")
        let store = ScriptedConversationStore(conversations: [stored])
        let loadGate = await store.enqueue(.load, outcome: .load([stored]), blocked: true)
        let manager = ConversationManager(store: store)
        await loadGate.started.wait()

        let waitingStarted = TestLatch()
        let waitingFinished = TestLatch()
        let waiting = Task { @MainActor in
            await waitingStarted.open()
            let authoritative = await manager.waitUntilConversationStateIsAuthoritative()
            await waitingFinished.open()
            return authoritative
        }
        await waitingStarted.wait()
        await Task.yield()

        let finishedBeforeLoad = await waitingFinished.opened()
        #expect(!finishedBeforeLoad)
        #expect(!manager.isConversationStateAuthoritative)

        await loadGate.releaseGate.open()
        _ = await manager.loadingTask?.value

        let becameAuthoritative = await waiting.value
        let didFinishWaiting = await waitingFinished.opened()
        #expect(becameAuthoritative)
        #expect(didFinishWaiting)
        #expect(manager.isConversationStateAuthoritative)
        #expect(manager.conversations.map(\.id) == [stored.id])
    }

    @Test
    @MainActor
    func `Initial load failure retries and restores authority automatically`() async {
        let stored = TestHelpers.sampleConversation()
        let store = ScriptedConversationStore(conversations: [stored])
        _ = await store.enqueue(.load, outcome: .fail)
        let manager = ConversationManager(
            store: store,
            loadRetryBaseDelay: .milliseconds(1)
        )

        _ = await manager.loadingTask?.value
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !manager.isConversationStateAuthoritative, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(manager.isConversationStateAuthoritative)
        #expect(manager.conversations.map(\.id) == [stored.id])
        #expect(manager.conversations.first?.title == stored.title)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Reload failure closes authority preserves UI and retries latest load`() async {
        let previousModels = AIService.shared.customModels
        let model = AIService.shared.selectedModel
        if !AIService.shared.customModels.contains(model) {
            AIService.shared.customModels.append(model)
        }
        defer { AIService.shared.customModels = previousModels }

        let stored = Conversation(title: "Visible before failed reload", model: model)
        var refreshed = stored
        refreshed.title = "Loaded by retry"
        refreshed.updatedAt = stored.updatedAt.addingTimeInterval(1)
        let store = ScriptedConversationStore(conversations: [stored])
        let manager = ConversationManager(store: store, loadRetryBaseDelay: .zero)
        _ = await manager.loadingTask?.value
        manager.selectedConversationId = stored.id
        _ = await store.enqueue(.load, outcome: .fail)
        let retry = await store.enqueue(
            .load,
            outcome: .load([refreshed]),
            blocked: true
        )

        await manager.reloadConversations()

        guard !manager.isConversationStateAuthoritative else {
            Issue.record("Expected the failed latest reload to close conversation authority")
            return
        }
        #expect(manager.conversations == [stored])
        #expect(manager.selectedConversationId == stored.id)

        await retry.started.wait()
        #expect(!manager.isConversationStateAuthoritative)
        #expect(manager.conversations == [stored])
        #expect(manager.selectedConversationId == stored.id)

        await retry.releaseGate.open()
        #expect(await manager.waitUntilConversationStateIsAuthoritative())
        #expect(manager.conversations == [refreshed])
        #expect(manager.selectedConversationId == stored.id)
        #expect(await store.operations() == [.load, .load, .load])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Failed reload gates stale Watch publication until retry succeeds`() async {
        let previousModels = AIService.shared.customModels
        let model = AIService.shared.selectedModel
        if !AIService.shared.customModels.contains(model) {
            AIService.shared.customModels.append(model)
        }
        defer { AIService.shared.customModels = previousModels }

        let stored = Conversation(title: "Stale Watch snapshot", model: model)
        var refreshed = stored
        refreshed.title = "Fresh Watch snapshot"
        refreshed.updatedAt = stored.updatedAt.addingTimeInterval(1)
        let store = ScriptedConversationStore(conversations: [stored])
        let manager = ConversationManager(store: store, loadRetryBaseDelay: .zero)
        _ = await manager.loadingTask?.value
        _ = await store.enqueue(.load, outcome: .fail)
        let retry = await store.enqueue(
            .load,
            outcome: .load([refreshed]),
            blocked: true
        )

        await manager.reloadConversations()

        guard !manager.isConversationStateAuthoritative else {
            Issue.record("Expected failed reload authority to gate Watch publication")
            return
        }
        #expect(manager.durableConversationsForSync() == [stored])
        let stalePublication = manager.isConversationStateAuthoritative
            ? manager.durableConversationsForSync()
            : nil
        #expect(stalePublication == nil)

        await retry.started.wait()
        let publicationDuringRetry = manager.isConversationStateAuthoritative
            ? manager.durableConversationsForSync()
            : nil
        #expect(publicationDuringRetry == nil)

        await retry.releaseGate.open()
        #expect(await manager.waitUntilConversationStateIsAuthoritative())
        let publicationAfterRetry = manager.isConversationStateAuthoritative
            ? manager.durableConversationsForSync()
            : nil
        #expect(publicationAfterRetry == [refreshed])
    }

    @Test
    @MainActor
    func `Failed clear after failed initial load remains non-authoritative and keeps retrying`() async {
        let stored = TestHelpers.sampleConversation()
        let store = ScriptedConversationStore(conversations: [stored])
        _ = await store.enqueue(.load, outcome: .fail)
        _ = await store.enqueue(.clear, outcome: .fail)
        _ = await store.enqueue(.clear)
        _ = await store.enqueue(.load, outcome: .fail)
        _ = await store.enqueue(.load, outcome: .load([stored]))
        let manager = ConversationManager(
            store: store,
            loadRetryBaseDelay: .milliseconds(100)
        )

        _ = await manager.loadingTask?.value
        await manager.clearAllConversations().value

        #expect(!manager.isConversationStateAuthoritative)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !manager.conversations.contains(where: { $0.id == stored.id }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(manager.isConversationStateAuthoritative)
        #expect(manager.conversations.map(\.id) == [stored.id])
    }

    @Test
    @MainActor
    func `Failed delete and clear roll back optimistic UI without losing newer state`() async throws {
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
        #expect(deleteManager.pendingDestructivePersistenceOperations == 1)
        await deleteGate.releaseGate.open()
        _ = await deleteRollback.value
        #expect(deleteManager.pendingDestructivePersistenceOperations == 1)
        #expect(deleteManager.conversations == [deleted])
        #expect(deleteManager.selectedConversationId == deleted.id)
        await deleteRepair.started.wait()
        await deleteRepair.releaseGate.open()
        await deleteManager.flushPendingSaves()
        #expect(await waitUntil {
            deleteManager.pendingDestructivePersistenceOperations == 0
        })

        let beforeClear = Conversation(title: "Before clear", model: model)
        let clearStore = ScriptedConversationStore(conversations: [beforeClear])
        let clearManager = ConversationManager(store: clearStore, saveDebounceDuration: .seconds(30))
        _ = await clearManager.loadingTask?.value
        let clearGate = await clearStore.enqueue(.clear, outcome: .partialClear([beforeClear.id]), blocked: true)
        clearManager.selectedConversationId = beforeClear.id
        let clearRollback = clearManager.clearAllConversations()
        await clearGate.started.wait()
        #expect(clearManager.pendingDestructivePersistenceOperations == 1)
        clearManager.createNewConversation(title: "After clear")
        let created = try #require(clearManager.conversations.first)
        clearManager.selectedConversationId = created.id
        let saveGate = await clearStore.enqueue(.save(created.id, nil))
        let clearRepair = await clearStore.enqueue(.clear, blocked: true)
        _ = clearManager.saveImmediately(created)
        await clearGate.releaseGate.open()
        await saveGate.started.wait()
        await clearRollback.value
        #expect(clearManager.pendingDestructivePersistenceOperations == 1)
        #expect(Set(clearManager.conversations.map(\.id)) == Set([beforeClear.id, created.id]))
        #expect(clearManager.selectedConversationId == created.id)
        await clearRepair.started.wait()
        await clearRepair.releaseGate.open()
        await clearManager.flushPendingSaves()
        #expect(await waitUntil {
            clearManager.pendingDestructivePersistenceOperations == 0
        })
    }

    @Test
    @MainActor
    func `Failed delete restores image placeholders as stopped`() async throws {
        let model = AIService.shared.selectedModel
        let userMessage = Message(role: .user, content: "Draw a sphere")
        let responseGroupID = UUID()
        let placeholder = Message(
            role: .assistant,
            content: "",
            model: model,
            responseGroupId: responseGroupID,
            mediaType: .image
        )
        let responseGroup = ResponseGroup(
            id: responseGroupID,
            userMessageId: userMessage.id,
            responses: [
                .init(id: placeholder.id, modelName: model, status: .streaming),
            ]
        )
        let conversation = Conversation(
            title: "Interrupted image",
            messages: [userMessage, placeholder],
            model: model,
            responseGroups: [responseGroup]
        )
        let store = ScriptedConversationStore(conversations: [conversation])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        let deleteGate = await store.enqueue(.delete(conversation.id), outcome: .fail, blocked: true)
        let repairGate = await store.enqueue(.save(conversation.id, nil), blocked: true)

        let target = try #require(manager.conversations.first)
        let rollback = try #require(manager.deleteConversation(target))
        await deleteGate.started.wait()
        await deleteGate.releaseGate.open()
        _ = await rollback.value

        let restored = try #require(manager.conversation(byId: conversation.id))
        let restoredMessage = try #require(restored.messages.first(where: { $0.id == placeholder.id }))
        let restoredGroup = try #require(restored.getResponseGroup(responseGroupID))
        #expect(restoredMessage.content == "Image generation stopped")
        #expect(restoredGroup.responses.first?.status == .failed)

        await repairGate.started.wait()
        await repairGate.releaseGate.open()
        await manager.flushPendingSaves()
    }

    @Test
    @MainActor
    func `Failed clear does not override a newer new-chat selection`() async {
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

    @Test
    @MainActor
    func `Search finds matches in title and messages`() throws {
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

    @Test
    @MainActor
    func `Save immediately persists manual changes`() async throws {
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

    @Test
    @MainActor
    func `Proposed save publishes only after durable success is committed`() async {
        let store = ScriptedConversationStore()
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        let proposed = TestHelpers.sampleConversation(title: "From Watch")
        let saveGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            blocked: true
        )

        let persistence = manager.persistProposedConversation(proposed)
        await saveGate.started.wait()

        #expect(manager.conversations.isEmpty)
        #expect(manager.conversation(byId: proposed.id) == nil)

        await saveGate.releaseGate.open()
        let result = await persistence.value

        #expect(result == .saved)
        #expect(manager.conversations.isEmpty)
        #expect(await store.persistedConversations() == [proposed])

        manager.commitPersistedConversation(proposed)

        #expect(manager.conversations == [proposed])
        #expect(manager.conversation(byId: proposed.id) == proposed)
        #expect(await store.operations() == [.load, .save(proposed.id, proposed.title)])
    }

    @Test
    @MainActor
    func `Failed proposed save leaves manager UI unchanged across reload`() async {
        let previousModels = AIService.shared.customModels
        let model = AIService.shared.selectedModel
        if !AIService.shared.customModels.contains(model) {
            AIService.shared.customModels.append(model)
        }
        defer { AIService.shared.customModels = previousModels }

        let stored = Conversation(title: "Stored", model: model)
        var proposed = stored
        proposed.title = "Rejected Watch save"
        proposed.updatedAt = stored.updatedAt.addingTimeInterval(1)
        let store = ScriptedConversationStore(conversations: [stored])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        let saveGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            outcome: .fail,
            blocked: true
        )

        let persistence = manager.persistProposedConversation(proposed)
        await saveGate.started.wait()

        #expect(manager.conversations == [stored])

        await saveGate.releaseGate.open()
        let result = await persistence.value

        guard case .failed = result else {
            Issue.record("Expected proposed save to fail, got \(result)")
            return
        }
        #expect(manager.conversations == [stored])
        #expect(manager.conversation(byId: proposed.id) == stored)
        #expect(await store.persistedConversations() == [stored])

        await manager.reloadConversations()
        await manager.flushPendingSaves()

        #expect(manager.conversations == [stored])
        #expect(manager.conversation(byId: proposed.id) == stored)
        #expect(await store.persistedConversations() == [stored])
        #expect(await store.operations() == [
            .load,
            .save(proposed.id, proposed.title),
            .load,
        ])
    }

    @Test
    @MainActor
    func `Superseded proposed save is not committed`() async {
        let store = ScriptedConversationStore()
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        let older = Conversation(title: "Older Watch edit", model: AIService.shared.selectedModel)
        var newer = older
        newer.title = "Newer Watch edit"
        newer.updatedAt = older.updatedAt.addingTimeInterval(1)
        let olderGate = await store.enqueue(
            .save(older.id, older.title),
            blocked: true
        )
        let newerGate = await store.enqueue(
            .save(newer.id, newer.title),
            blocked: true
        )

        let olderPersistence = manager.persistProposedConversation(older)
        await olderGate.started.wait()
        let newerPersistence = manager.persistProposedConversation(newer)

        #expect(manager.conversations.isEmpty)

        await olderGate.releaseGate.open()
        let olderResult = await olderPersistence.value

        #expect(olderResult == .superseded)
        #expect(manager.conversations.isEmpty)

        await newerGate.started.wait()
        #expect(manager.conversations.isEmpty)
        await newerGate.releaseGate.open()
        let newerResult = await newerPersistence.value

        #expect(newerResult == .saved)
        #expect(manager.conversations.isEmpty)

        manager.commitPersistedConversation(newer)

        #expect(manager.conversations == [newer])
        #expect(await store.operations() == [
            .load,
            .save(older.id, older.title),
            .save(newer.id, newer.title),
        ])
    }

    @Test
    @MainActor
    func `Proposed deletion publishes only after durable success is committed`() async {
        let previousModels = AIService.shared.customModels
        let model = AIService.shared.selectedModel
        if !AIService.shared.customModels.contains(model) {
            AIService.shared.customModels.append(model)
        }
        defer { AIService.shared.customModels = previousModels }

        let existing = Conversation(title: "Delete from Watch", model: model)
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        manager.selectedConversationId = existing.id
        let deleteGate = await store.enqueue(
            .delete(existing.id),
            blocked: true
        )

        let persistence = manager.persistProposedDeletion(existing)
        await deleteGate.started.wait()

        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(manager.conversations == [existing])
        #expect(manager.selectedConversationId == existing.id)

        await deleteGate.releaseGate.open()
        let result = await persistence.value

        #expect(result == .deleted)
        #expect(manager.pendingDestructivePersistenceOperations == 0)
        #expect(manager.conversations == [existing])
        #expect(manager.selectedConversationId == existing.id)

        manager.commitPersistedDeletion(existing.id)

        #expect(manager.conversations.isEmpty)
        #expect(manager.conversation(byId: existing.id) == nil)
        #expect(manager.selectedConversationId == nil)
        #expect(await store.operations() == [.load, .delete(existing.id)])
    }

    @Test
    @MainActor
    func `ID-only proposed deletion removes a backing record absent from memory`() async {
        let hidden = TestHelpers.sampleConversation(title: "Hidden backing record")
        let store = ScriptedConversationStore(conversations: [hidden])
        _ = await store.enqueue(.load, outcome: .load([]))
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value

        #expect(manager.isConversationStateAuthoritative)
        #expect(manager.conversations.isEmpty)
        #expect(await store.persistedConversations() == [hidden])

        let persistence = manager.persistProposedDeletion(conversationID: hidden.id)
        let result = await persistence.value

        #expect(result == .deleted)
        #expect(manager.pendingDestructivePersistenceOperations == 0)
        #expect(manager.conversations.isEmpty)
        #expect(await store.persistedConversations().isEmpty)
        #expect(await store.operations() == [.load, .delete(hidden.id)])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Failed ID-only deletion keeps its barrier until a delete retry succeeds`() async {
        let hidden = TestHelpers.sampleConversation(title: "Retry hidden deletion")
        let store = ScriptedConversationStore(conversations: [hidden])
        _ = await store.enqueue(.load, outcome: .load([]))
        _ = await store.enqueue(.delete(hidden.id), outcome: .fail)
        let retry = await store.enqueue(.delete(hidden.id), blocked: true)
        let manager = ConversationManager(
            store: store,
            destructiveRepairRetryBaseDelay: .milliseconds(1)
        )
        _ = await manager.loadingTask?.value

        let persistence = manager.persistProposedDeletion(conversationID: hidden.id)
        let result = await persistence.value

        guard case .failed(nil, _) = result else {
            Issue.record("Expected an ID-only delete failure, got \(result)")
            return
        }
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(await store.persistedConversations() == [hidden])

        await retry.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await retry.releaseGate.open()

        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })
        #expect(await store.persistedConversations().isEmpty)
        #expect(await store.operations() == [
            .load,
            .delete(hidden.id),
            .delete(hidden.id),
        ])
    }

    @Test
    @MainActor
    func `Failed proposed deletion leaves manager UI unchanged`() async {
        let previousModels = AIService.shared.customModels
        let model = AIService.shared.selectedModel
        if !AIService.shared.customModels.contains(model) {
            AIService.shared.customModels.append(model)
        }
        defer { AIService.shared.customModels = previousModels }

        let existing = Conversation(title: "Keep after Watch delete", model: model)
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        manager.selectedConversationId = existing.id
        let deleteGate = await store.enqueue(
            .delete(existing.id),
            outcome: .fail,
            blocked: true
        )
        let repairGate = await store.enqueue(
            .save(existing.id, existing.title),
            blocked: true
        )

        let persistence = manager.persistProposedDeletion(existing)
        await deleteGate.started.wait()

        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(manager.conversations == [existing])
        #expect(manager.selectedConversationId == existing.id)

        await deleteGate.releaseGate.open()
        let result = await persistence.value

        guard case .failed = result else {
            Issue.record("Expected proposed deletion to fail, got \(result)")
            return
        }
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(manager.conversations == [existing])
        #expect(manager.selectedConversationId == existing.id)

        await repairGate.started.wait()
        await repairGate.releaseGate.open()
        await manager.flushPendingSaves()
        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })

        #expect(manager.conversations == [existing])
        #expect(await store.persistedConversations() == [existing])
        #expect(await store.operations() == [
            .load,
            .delete(existing.id),
            .save(existing.id, existing.title),
        ])
    }

    @Test
    @MainActor
    func `Superseded proposed deletion is not committed`() async {
        let previousModels = AIService.shared.customModels
        let model = AIService.shared.selectedModel
        if !AIService.shared.customModels.contains(model) {
            AIService.shared.customModels.append(model)
        }
        defer { AIService.shared.customModels = previousModels }

        let existing = Conversation(title: "Before Watch edit", model: model)
        var newer = existing
        newer.title = "After Watch edit"
        newer.updatedAt = existing.updatedAt.addingTimeInterval(1)
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value
        let deleteGate = await store.enqueue(
            .delete(existing.id),
            blocked: true
        )
        let saveGate = await store.enqueue(
            .save(newer.id, newer.title),
            blocked: true
        )

        let deletion = manager.persistProposedDeletion(existing)
        await deleteGate.started.wait()
        let save = manager.persistProposedConversation(newer)

        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(manager.conversations == [existing])

        await deleteGate.releaseGate.open()
        let deleteResult = await deletion.value

        #expect(deleteResult == .superseded)
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(manager.conversations == [existing])

        await saveGate.started.wait()
        #expect(manager.conversations == [existing])
        await saveGate.releaseGate.open()
        let saveResult = await save.value

        #expect(saveResult == .saved)
        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })
        #expect(manager.conversations == [existing])

        manager.commitPersistedConversation(newer)

        #expect(manager.conversations == [newer])
        #expect(await store.operations() == [
            .load,
            .delete(existing.id),
            .save(newer.id, newer.title),
        ])
    }

    @Test
    @MainActor
    func `Failed normal save keeps Watch sync on the last durable snapshot until retry succeeds`() async {
        let model = AIService.shared.selectedModel
        let stored = Conversation(title: "Durable before edit", model: model)
        var edited = stored
        edited.title = "Visible but not durable"
        edited.updatedAt = stored.updatedAt.addingTimeInterval(1)
        let store = ScriptedConversationStore(conversations: [stored])
        _ = await store.enqueue(.save(edited.id, edited.title), outcome: .fail)
        _ = await store.enqueue(.save(edited.id, edited.title))
        let manager = ConversationManager(store: store, saveDebounceDuration: .zero)
        _ = await manager.loadingTask?.value
        let initialDurableRevision = manager.durableConversationRevision

        manager.conversations = [edited]
        manager.save(edited)
        await manager.flushPendingSaves()

        #expect(manager.conversations == [edited])
        #expect(manager.durableConversationsForSync() == [stored])

        await manager.flushPendingSaves()

        #expect(manager.durableConversationsForSync() == [edited])
        #expect(manager.durableConversationRevision > initialDurableRevision)
        #expect(await store.persistedConversations() == [edited])
    }

    @Test
    @MainActor
    func `Reload conversations removes stale non-dirty conversations`() async throws {
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

    @Test
    @MainActor
    func `Reload conversations preserves dirty in-memory conversations not yet on disk`() async throws {
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

    @Test
    @MainActor
    func `Dirty memory wins load, then removed model repair is persisted`() async throws {
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

    @Test
    @MainActor
    func `Edit message updates content and marks as edited`() throws {
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

    @Test
    @MainActor
    func `Edit message removes subsequent messages`() throws {
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

    @Test
    @MainActor
    func `Edit message fails for assistant messages`() throws {
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

    @Test
    @MainActor
    func `Edit message with same content does not mark as edited`() throws {
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

    @Test
    @MainActor
    func `Edit message fails for non-existent message`() throws {
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

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

extension ConversationManagerTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Destructive barrier retries failed delete repair until durable success`() async throws {
        let model = AIService.shared.selectedModel
        let existing = Conversation(title: "Retry delete rollback", model: model)
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(
            store: store,
            destructiveRepairRetryBaseDelay: .milliseconds(1)
        )
        _ = await manager.loadingTask?.value

        let deleteGate = await store.enqueue(
            .delete(existing.id),
            outcome: .fail,
            blocked: true
        )
        let firstRepair = await store.enqueue(
            .save(existing.id, existing.title),
            outcome: .fail,
            blocked: true
        )
        let secondRepair = await store.enqueue(
            .save(existing.id, existing.title),
            outcome: .fail,
            blocked: true
        )
        let successfulRepair = await store.enqueue(
            .save(existing.id, existing.title),
            blocked: true
        )

        let target = try #require(manager.conversations.first)
        let deletion = try #require(manager.deleteConversation(target))
        await deleteGate.started.wait()
        await deleteGate.releaseGate.open()
        guard case .failed = await deletion.value else {
            Issue.record("Expected delete failure")
            return
        }

        await firstRepair.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await firstRepair.releaseGate.open()

        await secondRepair.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await secondRepair.releaseGate.open()

        await successfulRepair.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await successfulRepair.releaseGate.open()

        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })
        #expect(manager.conversations == [existing])
        #expect(await store.persistedConversations() == [existing])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Edit during failed delete repair keeps barrier until newest state is durable`() async throws {
        let existing = Conversation(
            title: "Rollback before edit",
            model: AIService.shared.selectedModel
        )
        let editedTitle = "Edited after rollback"
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            destructiveRepairRetryBaseDelay: .milliseconds(1)
        )
        _ = await manager.loadingTask?.value
        await manager.flushPendingSaves()
        let operationBaseline = await store.operations().count

        let failedDelete = await store.enqueue(
            .delete(existing.id),
            outcome: .fail,
            blocked: true
        )
        let failedRollbackSave = await store.enqueue(
            .save(existing.id, existing.title),
            outcome: .fail,
            blocked: true
        )
        let failedEditedSave = await store.enqueue(
            .save(existing.id, editedTitle),
            outcome: .fail,
            blocked: true
        )
        let successfulRetry = await store.enqueue(
            .save(existing.id, editedTitle),
            blocked: true
        )

        let target = try #require(manager.conversations.first)
        let deletion = try #require(manager.deleteConversation(target))
        await failedDelete.started.wait()
        await failedDelete.releaseGate.open()
        guard case .failed = await deletion.value else {
            Issue.record("Expected delete failure")
            return
        }
        await failedRollbackSave.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)

        let restored = try #require(manager.conversation(byId: existing.id))
        manager.renameConversation(restored, newTitle: editedTitle)
        let edited = try #require(manager.conversation(byId: existing.id))
        #expect(edited.title == editedTitle)

        await failedRollbackSave.releaseGate.open()
        await failedEditedSave.started.wait()
        let barrierDroppedDuringEditedSave = await waitUntil(timeout: .milliseconds(50)) {
            manager.pendingDestructivePersistenceOperations == 0
        }
        guard barrierDroppedDuringEditedSave == false else {
            Issue.record("Destructive barrier dropped before the edited state was durable")
            return
        }
        #expect(await store.persistedConversations() == [existing])

        await failedEditedSave.releaseGate.open()
        await successfulRetry.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(manager.conversations == [edited])
        await successfulRetry.releaseGate.open()

        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })
        #expect(manager.conversations == [edited])
        #expect(await store.persistedConversations() == [edited])
        let operations = await store.operations()
        #expect(Array(operations.dropFirst(operationBaseline)) == [
            .delete(existing.id),
            .save(existing.id, existing.title),
            .save(existing.id, editedTitle),
            .save(existing.id, editedTitle),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Newer delete supersedes an older blocked rollback barrier`() async throws {
        let existing = Conversation(
            title: "Delete rollback superseded",
            model: AIService.shared.selectedModel
        )
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value

        let firstDelete = await store.enqueue(
            .delete(existing.id),
            outcome: .fail,
            blocked: true
        )
        let oldRepair = await store.enqueue(
            .save(existing.id, existing.title),
            outcome: .fail,
            blocked: true
        )
        let newerDelete = await store.enqueue(.delete(existing.id), blocked: true)

        let firstTarget = try #require(manager.conversations.first)
        let firstTask = try #require(manager.deleteConversation(firstTarget))
        await firstDelete.started.wait()
        await firstDelete.releaseGate.open()
        guard case .failed = await firstTask.value else {
            Issue.record("Expected first delete failure")
            return
        }
        await oldRepair.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)

        let restored = try #require(manager.conversation(byId: existing.id))
        let newerTask = try #require(manager.deleteConversation(restored))

        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await oldRepair.releaseGate.open()
        await newerDelete.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await newerDelete.releaseGate.open()
        #expect(await newerTask.value == .deleted)
        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })
        #expect(manager.conversations.isEmpty)
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Newer clear supersedes an older blocked delete rollback barrier`() async throws {
        let existing = Conversation(
            title: "Delete rollback cleared",
            model: AIService.shared.selectedModel
        )
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value

        let failedDelete = await store.enqueue(
            .delete(existing.id),
            outcome: .fail,
            blocked: true
        )
        let oldRepair = await store.enqueue(
            .save(existing.id, existing.title),
            outcome: .fail,
            blocked: true
        )
        let newerClear = await store.enqueue(.clear, blocked: true)

        let target = try #require(manager.conversations.first)
        let deleteTask = try #require(manager.deleteConversation(target))
        await failedDelete.started.wait()
        await failedDelete.releaseGate.open()
        guard case .failed = await deleteTask.value else {
            Issue.record("Expected delete failure")
            return
        }
        await oldRepair.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)

        let clearTask = manager.clearAllConversations()

        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await oldRepair.releaseGate.open()
        await newerClear.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await newerClear.releaseGate.open()
        await clearTask.value
        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })
        #expect(manager.conversations.isEmpty)
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `Newer clear supersedes an older blocked rewrite barrier`() async {
        let existing = Conversation(
            title: "Clear rollback superseded",
            model: AIService.shared.selectedModel
        )
        let store = ScriptedConversationStore(conversations: [existing])
        let manager = ConversationManager(store: store)
        _ = await manager.loadingTask?.value

        let firstClear = await store.enqueue(
            .clear,
            outcome: .partialClear([existing.id]),
            blocked: true
        )
        let oldRepair = await store.enqueue(
            .clear,
            outcome: .fail,
            blocked: true
        )
        let newerClear = await store.enqueue(.clear, blocked: true)

        let firstTask = manager.clearAllConversations()
        await firstClear.started.wait()
        await firstClear.releaseGate.open()
        await firstTask.value
        await oldRepair.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        #expect(manager.conversations == [existing])

        let newerTask = manager.clearAllConversations()

        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await oldRepair.releaseGate.open()
        await newerClear.started.wait()
        #expect(manager.pendingDestructivePersistenceOperations == 1)
        await newerClear.releaseGate.open()
        await newerTask.value
        #expect(await waitUntil {
            manager.pendingDestructivePersistenceOperations == 0
        })
        #expect(manager.conversations.isEmpty)
        #expect(await store.persistedConversations().isEmpty)
    }
}

// swiftlint:enable identifier_name
