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

    @Test
    @MainActor
    func `deferred manager initialization does not start loading`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(
            directory: directory,
            keychain: InMemoryKeychainStorage()
        )
        let probe = MetadataLoadInvocationProbe()
        let manager = ConversationManager(
            store: store,
            conversationMetadataLoader: {
                await probe.record()
                return []
            },
            searchIndexWarmupEnabled: false,
            startsLoadingImmediately: false
        )

        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(manager.loadingTask == nil)
        #expect(await probe.invocationCount == 0)
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
    func `create new conversation uses selected model`() throws {
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
    func `add message appends and updates timestamp`() throws {
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
    func `search finds matches in title and messages`() throws {
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
    func `save immediately persists manual changes`() async throws {
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
        #expect(newManager.conversations.first?.messages.isEmpty == true)

        let hydrated = await newManager.ensureConversationLoaded(conversation.id)
        #expect(hydrated?.messages.last?.content == "Partial content")
        #expect(newManager.conversations.first?.messages.last?.content == "Partial content")
    }

    @Test
    @MainActor
    func `later save inherits an outstanding immediate save requirement`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value
        var conversation = TestHelpers.sampleConversation(title: "Immediate")
        manager.conversations = [conversation]

        let immediateTask = manager.saveImmediately(conversation)
        conversation.title = "Latest snapshot"
        conversation.updatedAt = Date().addingTimeInterval(1)
        manager.conversations = [conversation]
        manager.save(conversation)
        await immediateTask.value

        for _ in 0 ..< 100 {
            if try await store.loadConversation(id: conversation.id)?.title == "Latest snapshot" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(try await store.loadConversation(id: conversation.id)?.title == "Latest snapshot")
        manager.clearAllConversations()
    }

    @Test
    @MainActor
    func `flush waits for a save registered during the coordinator flush`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Before Flush")
        try await store.save(conversation)

        let metadataGate = ConversationMetadataLoadGate(store: store)
        let flushGate = PersistenceFlushGate()
        let completion = AsyncCompletionProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationMetadataLoader: {
                try await metadataGate.load()
            },
            beforePersistenceFlush: {
                await flushGate.waitBeforeFlush()
            }
        )
        await metadataGate.waitUntilStarted()
        var placeholder = conversation
        placeholder.messages = []
        placeholder.metadataPreview = "Preview"
        manager.conversations = [placeholder]

        let flushTask = Task { @MainActor in
            await manager.flushPendingSaves()
            await completion.markComplete()
        }
        await flushGate.waitUntilStarted()

        manager.renameConversation(placeholder, newTitle: "Saved During Flush")
        await flushGate.release()

        try await Task.sleep(for: .milliseconds(50))
        #expect(await !(completion.isComplete()))

        await metadataGate.release()
        await flushTask.value

        #expect(await completion.isComplete())
        #expect(try await store.loadConversation(id: conversation.id)?.title == "Saved During Flush")
    }

    @Test
    @MainActor
    func `initial load uses metadata placeholders until conversation is selected`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-metadata-placeholder-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Metadata Only")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.count == 1)
        #expect(manager.conversations.first?.id == conversation.id)
        #expect(manager.conversations.first?.title == "Metadata Only")
        #expect(manager.conversations.first?.messages.isEmpty == true)

        let hydrated = await manager.ensureConversationLoaded(conversation.id)
        #expect(hydrated?.messages.count == conversation.messages.count)
        #expect(manager.conversations.first?.messages.count == conversation.messages.count)
    }

    @Test
    @MainActor
    func `hydrating metadata placeholder before export includes message history`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-export-hydration-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Export Hydration")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        let placeholder = try #require(manager.conversations.first)
        #expect(placeholder.messages.isEmpty == true)
        #expect(ConversationExporter.generateMarkdown(for: placeholder).contains("Hello") == false)

        let hydrated = try #require(await manager.ensureConversationLoaded(conversation.id))
        let markdown = ConversationExporter.generateMarkdown(for: hydrated)

        #expect(markdown.contains("Hello"))
        #expect(markdown.contains("Hi there"))
    }

    @Test
    @MainActor
    func `metadata-only search preserves matches from the middle of long history`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = Conversation(title: "Long Search")
        conversation.addMessage(Message(role: .user, content: String(repeating: "head ", count: 2000)))
        conversation.addMessage(Message(role: .assistant, content: "middle-only-needle"))
        conversation.addMessage(Message(role: .user, content: String(repeating: "tail ", count: 2000)))
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        #expect(manager.searchConversations(query: "middle-only-needle").isEmpty)

        let results = await manager.searchConversationsAsync(
            query: "middle-only-needle",
            conversations: manager.conversations
        )

        #expect(results.map(\.id) == [conversation.id])
        #expect(results.first?.messages.isEmpty == true)
    }

    @Test
    @MainActor
    func `selecting metadata placeholder lazy loads full conversation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-selected-lazy-load-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Lazy Selected")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.first?.messages.isEmpty == true)
        manager.selectedConversationId = conversation.id

        for _ in 0 ..< 20 {
            if manager.conversations.first?.messages.count == conversation.messages.count {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(manager.conversations.first?.messages.count == conversation.messages.count)
    }

    @Test
    @MainActor
    func `deleting during lazy hydration cannot recreate the conversation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Delete During Hydration")
        conversation.model = "missing-model-for-delete-race"
        try await store.save(conversation)
        let loadGate = ConversationStaleLoadGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationLoader: { conversationId in
                try await loadGate.load(conversationId)
            }
        )
        _ = await manager.loadingTask?.value
        let placeholder = try #require(manager.conversations.first)

        _ = manager.conversation(byId: conversation.id)
        await loadGate.waitUntilStarted()
        manager.deleteConversation(placeholder)

        for _ in 0 ..< 100 where try await store.loadConversation(id: conversation.id) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.loadConversation(id: conversation.id) == nil)

        await loadGate.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(try await store.loadConversation(id: conversation.id) == nil)
        #expect(!manager.conversations.contains { $0.id == conversation.id })
    }

    @Test
    @MainActor
    func `sync recreation authorization reaches the newest coalesced save`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let original = TestHelpers.sampleConversation(title: "Original")
        try await store.save(original)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        let placeholder = try #require(manager.conversations.first)
        manager.deleteConversation(placeholder)

        var recreation = original
        recreation.title = "Recreated from sync"
        recreation.messages = []
        manager.insertConversationFromSync(recreation, allowsRecreation: true)
        let inserted = try #require(manager.conversation(byId: original.id))
        manager.addMessage(to: inserted, message: Message(role: .user, content: "Synced message"))
        await manager.flushPendingSaves()

        let persisted = try #require(try await store.loadConversation(id: original.id))
        #expect(persisted.title == "Recreated from sync")
        #expect(persisted.messages.map(\.content) == ["Synced message"])
    }

    @Test
    @MainActor
    func `stale metadata reload preserves an authorized recreation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let original = TestHelpers.sampleConversation(title: "Original Before Reload")
        try await store.save(original)
        let metadataGate = ConversationReloadMetadataGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationMetadataLoader: {
                try await metadataGate.load()
            }
        )
        _ = await manager.loadingTask?.value
        let placeholder = try #require(manager.conversations.first)

        let reloadTask = Task { @MainActor in
            await manager.reloadConversations()
        }
        await metadataGate.waitUntilReloadStarted()

        manager.deleteConversation(placeholder)
        var recreation = original
        recreation.title = "Recreated During Reload"
        recreation.updatedAt = Date().addingTimeInterval(1)
        manager.insertConversationFromSync(recreation, allowsRecreation: true)
        await manager.flushPendingSaves()

        await metadataGate.releaseReload()
        await reloadTask.value

        #expect(manager.conversation(byId: original.id)?.title == "Recreated During Reload")
        #expect(try await store.loadConversation(id: original.id)?.title == "Recreated During Reload")
    }

    @Test
    @MainActor
    func `reload preserves a pending row whose save completes during metadata loading`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let metadataGate = ConversationReloadMetadataGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .seconds(10),
            conversationMetadataLoader: {
                try await metadataGate.load()
            }
        )
        _ = await manager.loadingTask?.value

        manager.createNewConversation(title: "Saved During Reload")
        let conversationId = try #require(manager.conversations.first?.id)
        try await Task.sleep(for: .milliseconds(50))

        let reloadTask = Task { @MainActor in
            await manager.reloadConversations()
        }
        await metadataGate.waitUntilReloadStarted()

        await manager.flushPendingSaves()
        #expect(try await store.loadConversation(id: conversationId)?.title == "Saved During Reload")

        await metadataGate.releaseReload()
        await reloadTask.value

        #expect(manager.conversation(byId: conversationId)?.title == "Saved During Reload")
    }

    @Test
    @MainActor
    func `metadata load started before clear cannot repopulate conversations`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Stale Metadata")
        try await store.save(conversation)
        let metadataGate = ConversationMetadataLoadGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationMetadataLoader: {
                try await metadataGate.load()
            }
        )

        await metadataGate.waitUntilStarted()
        manager.clearAllConversations()
        await metadataGate.release()
        _ = await manager.loadingTask?.value

        for _ in 0 ..< 100 where try await !(store.loadConversations().isEmpty) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.loadConversations().isEmpty)
        #expect(manager.conversations.isEmpty)
    }

    @Test
    @MainActor
    func `metadata load started before delete cannot restore the deleted row`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Stale Deleted Metadata")
        try await store.save(conversation)
        let metadataGate = ConversationMetadataLoadGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationMetadataLoader: {
                try await metadataGate.load()
            }
        )

        await metadataGate.waitUntilStarted()
        manager.conversations = [conversation]
        manager.deleteConversation(conversation)
        await manager.flushPendingSaves()
        #expect(try await store.loadConversation(id: conversation.id) == nil)

        await metadataGate.release()
        _ = await manager.loadingTask?.value

        #expect(!manager.conversations.contains { $0.id == conversation.id })
    }

    @Test
    @MainActor
    func `deleting a new row during initial load preserves existing history`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let persisted = TestHelpers.sampleConversation(title: "Persisted Before Startup")
        try await store.save(persisted)
        let metadataGate = ConversationMetadataLoadGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationMetadataLoader: {
                try await metadataGate.load()
            }
        )

        await metadataGate.waitUntilStarted()
        let local = TestHelpers.sampleConversation(title: "Created During Startup")
        manager.conversations = [local]
        manager.deleteConversation(local)
        await manager.flushPendingSaves()

        await metadataGate.release()
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.contains { $0.id == persisted.id })
        #expect(!manager.conversations.contains { $0.id == local.id })
    }

    @Test
    @MainActor
    func `metadata load schedules background search index warmup`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Warm Search")
        conversation.addMessage(Message(role: .assistant, content: "middle-only warmup content"))
        try await store.save(conversation)
        let searchIndexURL = store.searchIndexFileURL(for: conversation.id)
        #expect(!FileManager.default.fileExists(atPath: searchIndexURL.path))

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupDelay: .zero
        )
        _ = await manager.loadingTask?.value

        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: searchIndexURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(FileManager.default.fileExists(atPath: searchIndexURL.path))
        manager.clearAllConversations()
        await manager.flushPendingSaves()
    }

    @Test
    @MainActor
    func `disabled search warmup leaves conversation indexes cold`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Cold Search")
        conversation.addMessage(Message(role: .assistant, content: "content that would be indexed"))
        try await store.save(conversation)
        let searchIndexURL = store.searchIndexFileURL(for: conversation.id)

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupDelay: .zero,
            searchIndexWarmupEnabled: false
        )
        _ = await manager.loadingTask?.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(!FileManager.default.fileExists(atPath: searchIndexURL.path))
    }

    @Test
    @MainActor
    func `background search warmup is bounded to recent conversations`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let baseDate = Date()
        var conversations: [Conversation] = []

        for index in 0 ..< 18 {
            var conversation = TestHelpers.sampleConversation(title: "Warm \(index)")
            conversation.updatedAt = baseDate.addingTimeInterval(Double(index))
            conversations.append(conversation)
            try await store.save(conversation)
        }

        let newest = conversations.sorted { $0.updatedAt > $1.updatedAt }
        let expectedWarmIds = Set(newest.prefix(16).map(\.id))
        let expectedColdIds = Set(newest.dropFirst(16).map(\.id))
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupDelay: .zero
        )
        _ = await manager.loadingTask?.value

        for _ in 0 ..< 200 {
            let warmedIds = Set(expectedWarmIds.filter { conversationId in
                FileManager.default.fileExists(
                    atPath: store.searchIndexFileURL(for: conversationId).path
                )
            })
            if warmedIds == expectedWarmIds {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(expectedWarmIds.allSatisfy { conversationId in
            FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: conversationId).path)
        })
        #expect(expectedColdIds.allSatisfy { conversationId in
            !FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: conversationId).path)
        })

        manager.clearAllConversations()
        await manager.flushPendingSaves()
    }

    @Test
    @MainActor
    func `clearing during lazy hydration cannot recreate the conversation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Clear During Hydration")
        conversation.model = "missing-model-for-clear-race"
        try await store.save(conversation)
        let loadGate = ConversationStaleLoadGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationLoader: { conversationId in
                try await loadGate.load(conversationId)
            }
        )
        _ = await manager.loadingTask?.value

        _ = manager.conversation(byId: conversation.id)
        await loadGate.waitUntilStarted()
        manager.clearAllConversations()

        for _ in 0 ..< 100 where try await store.loadConversation(id: conversation.id) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.loadConversation(id: conversation.id) == nil)

        await loadGate.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(try await store.loadConversation(id: conversation.id) == nil)
        #expect(manager.conversations.isEmpty)
    }

    @Test
    @MainActor
    func `reload cancels stale lazy hydration before publishing messages`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var original = TestHelpers.sampleConversation(title: "Hydration Version A")
        original.messages = [Message(role: .user, content: "Version A")]
        try await store.save(original)
        let loadGate = ConversationStaleLoadGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationLoader: { conversationId in
                try await loadGate.load(conversationId)
            }
        )
        _ = await manager.loadingTask?.value

        _ = manager.conversation(byId: original.id)
        await loadGate.waitUntilStarted()

        var updated = original
        updated.title = "Hydration Version B"
        updated.messages = [Message(role: .user, content: "Version B")]
        updated.updatedAt = Date().addingTimeInterval(1)
        try await store.save(updated)
        await manager.reloadConversations()
        await loadGate.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.isMetadataOnlyConversation(original.id))
        let hydrated = try #require(await manager.ensureConversationLoaded(original.id))
        #expect(hydrated.messages.map(\.content) == ["Version B"])
    }

    @Test
    @MainActor
    func `concurrent lazy hydration callers share one store load`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Coalesced Hydration")
        try await store.save(conversation)
        let loadProbe = ConversationLoadProbe(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationLoader: { conversationId in
                try await loadProbe.load(conversationId)
            }
        )
        _ = await manager.loadingTask?.value

        _ = manager.conversation(byId: conversation.id)
        async let first = manager.ensureConversationLoaded(conversation.id)
        async let second = manager.ensureConversationLoaded(conversation.id)
        let loaded = await [first, second]

        #expect(loaded.allSatisfy { $0?.messages.count == conversation.messages.count })
        #expect(await loadProbe.loadCount() == 1)
    }

    @Test
    @MainActor
    func `lazy hydration repairs unavailable model`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-lazy-model-repair-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let defaultModel = AIService.shared.selectedModel.isEmpty
            ? "available-model"
            : AIService.shared.selectedModel
        let unavailableModel = "removed-\(UUID().uuidString)"

        if !AIService.shared.customModels.contains(defaultModel) {
            AIService.shared.customModels.insert(defaultModel, at: 0)
        }
        AIService.shared.selectedModel = defaultModel

        let conversation = TestHelpers.sampleConversation(title: "Repair", model: unavailableModel)
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.first?.model != unavailableModel)
        let hydrated = await manager.ensureConversationLoaded(conversation.id)

        #expect(hydrated?.model != unavailableModel)
        #expect(manager.conversations.first?.model != unavailableModel)
        await manager.flushPendingSaves()
        let persisted = try #require(try await store.loadConversation(id: conversation.id))
        #expect(persisted.model != unavailableModel)
    }

    @Test
    @MainActor
    func `saving metadata placeholder does not persist synthetic preview message`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-synthetic-preview-save-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Preview Save")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        var placeholder = try #require(manager.conversations.first)
        #expect(placeholder.messages.isEmpty == true)
        #expect(placeholder.metadataPreview != nil)

        placeholder.title = "Renamed Preview Save"
        placeholder.updatedAt = Date().addingTimeInterval(60)
        let saveTask = manager.saveImmediately(placeholder)
        _ = await saveTask.value

        let persisted = try #require(try await store.loadConversation(id: conversation.id))
        #expect(persisted.title == "Renamed Preview Save")
        #expect(persisted.messages.count == conversation.messages.count)
    }

    @Test
    @MainActor
    func `later metadata placeholder save replaces pending debounced save`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-metadata-debounce-latest-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Original Debounced")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(500))
        _ = await manager.loadingTask?.value

        var firstEdit = try #require(manager.conversations.first)
        firstEdit.title = "First Pending Title"
        firstEdit.updatedAt = Date().addingTimeInterval(10)
        manager.save(firstEdit)

        try await Task.sleep(for: .milliseconds(100))

        var secondEdit = firstEdit
        secondEdit.title = "Second Pending Title"
        secondEdit.temperature = 0.42
        secondEdit.updatedAt = Date().addingTimeInterval(20)
        manager.conversations = [secondEdit]
        manager.save(secondEdit)

        var persistedConversation: Conversation?
        for _ in 0 ..< 200 {
            persistedConversation = try await store.loadConversation(id: conversation.id)
            if persistedConversation?.title == "Second Pending Title" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let persisted = try #require(persistedConversation)
        #expect(persisted.title == "Second Pending Title")
        #expect(persisted.temperature == 0.42)
        #expect(persisted.messages.count == conversation.messages.count)
    }

    @Test
    @MainActor
    func `lazy hydration preserves newer placeholder metadata edits`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-lazy-merge-newer-edits-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Original Title")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        let index = try #require(manager.conversations.firstIndex(where: { $0.id == conversation.id }))
        manager.conversations[index].title = "Edited Before Hydration"
        manager.conversations[index].updatedAt = Date().addingTimeInterval(60)

        let hydrated = await manager.ensureConversationLoaded(conversation.id)

        #expect(hydrated?.title == "Edited Before Hydration")
        #expect(hydrated?.messages.count == conversation.messages.count)
        #expect(manager.conversations[index].title == "Edited Before Hydration")
    }

    @Test
    @MainActor
    func `lazy hydration preserves a newer available model selection`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let unavailableModel = "removed-\(UUID().uuidString)"
        let selectedModel = "selected-\(UUID().uuidString)"
        AIService.shared.customModels.insert(selectedModel, at: 0)
        var conversation = TestHelpers.sampleConversation(title: "Model Race", model: unavailableModel)
        conversation.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        try await store.save(conversation)
        let loadGate = ConversationStaleLoadGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationLoader: { conversationId in
                try await loadGate.load(conversationId)
            }
        )
        _ = await manager.loadingTask?.value

        _ = manager.conversation(byId: conversation.id)
        await loadGate.waitUntilStarted()
        let index = try #require(manager.conversations.firstIndex(where: { $0.id == conversation.id }))
        manager.conversations[index].model = selectedModel
        manager.conversations[index].updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        await loadGate.release()
        let hydrated = try #require(await manager.ensureConversationLoaded(conversation.id))

        #expect(hydrated.model == selectedModel)
        #expect(manager.conversations[index].model == selectedModel)
    }

    @Test
    @MainActor
    func `reload conversations removes stale non-dirty conversations`() async throws {
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
    func `reload conversations preserves dirty in-memory conversations not yet on disk`() async throws {
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

    @Test
    @MainActor
    func `reload ignores stale sidecar text for dirty full conversation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-dirty-search-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        var conversation = Conversation(title: "Searchable")
        conversation.addMessage(Message(role: .user, content: "old deleted term"))
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value
        let hydrated = try #require(await manager.ensureConversationLoaded(conversation.id))
        let messageId = try #require(hydrated.messages.first?.id)

        #expect(manager.editMessage(in: hydrated, messageId: messageId, newContent: "current replacement"))
        try await Task.sleep(for: .milliseconds(50))

        await manager.reloadConversations()

        #expect(manager.searchConversations(query: "old deleted term").isEmpty)
        #expect(manager.searchConversations(query: "current replacement").map(\.id) == [conversation.id])

        let verifiedResults = await manager.verifiedSearchResults(
            conversations: manager.conversations,
            query: "old deleted term",
            metadataSearchTextById: [:],
            metadataOnlyConversationIds: []
        )
        #expect(verifiedResults.isEmpty)

        manager.clearAllConversations()
    }
}

extension ConversationManagerTests {
    // MARK: - Edit Message Tests

    @Test
    @MainActor
    func `edit message updates content and marks as edited`() throws {
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
    func `edit message removes subsequent messages`() throws {
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
    func `edit message fails for assistant messages`() throws {
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
    func `edit message with same content does not mark as edited`() throws {
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
    func `edit message fails for non-existent message`() throws {
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

private actor ConversationMetadataLoadGate {
    private let store: EncryptedConversationStore
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func load() async throws -> [ConversationMetadata] {
        let staleMetadata = try await store.loadConversationMetadata()
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()

        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return staleMetadata
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ConversationReloadMetadataGate {
    private let store: EncryptedConversationStore
    private var loadCount = 0
    private var reloadStarted = false
    private var reloadReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func load() async throws -> [ConversationMetadata] {
        loadCount += 1
        let metadata = try await store.loadConversationMetadata()
        guard loadCount > 1 else { return metadata }

        reloadStarted = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()

        if !reloadReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return metadata
    }

    func waitUntilReloadStarted() async {
        guard !reloadStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseReload() {
        reloadReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MetadataLoadInvocationProbe {
    private(set) var invocationCount = 0

    func record() {
        invocationCount += 1
    }
}

private actor ConversationStaleLoadGate {
    private let store: EncryptedConversationStore
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func load(_ conversationId: UUID) async throws -> Conversation? {
        let staleConversation = try await store.loadConversation(id: conversationId)
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()

        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return staleConversation
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ConversationLoadProbe {
    private let store: EncryptedConversationStore
    private var count = 0

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func load(_ conversationId: UUID) async throws -> Conversation? {
        count += 1
        try await Task.sleep(for: .milliseconds(50))
        return try await store.loadConversation(id: conversationId)
    }

    func loadCount() -> Int {
        count
    }
}

private actor PersistenceFlushGate {
    private var callCount = 0
    private var firstCallStarted = false
    private var firstCallReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitBeforeFlush() async {
        callCount += 1
        guard callCount == 1 else { return }

        firstCallStarted = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()

        if !firstCallReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilStarted() async {
        guard !firstCallStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        firstCallReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AsyncCompletionProbe {
    private var complete = false

    func markComplete() {
        complete = true
    }

    func isComplete() -> Bool {
        complete
    }
}
