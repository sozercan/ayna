@testable import Ayna
import Foundation
import Testing

@Suite("ConversationManager Clear Tests", .tags(.viewModel, .persistence), .serialized)
struct ConversationManagerClearTests {
    private var defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: "ConversationManagerClearTests") else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "ConversationManagerClearTests")
        AppPreferences.use(defaults)
        defaults.set(false, forKey: "autoGenerateTitle")
    }

    @Test
    @MainActor
    func `failed optimistic deletion reloads the persisted conversation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Deletion Must Roll Back")
        try await store.save(conversation)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            deleteOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value
        let loaded = try #require(manager.conversations.first)

        manager.deleteConversation(loaded)
        await manager.flushPendingSaves()

        #expect(manager.conversations.map(\.id) == [conversation.id])
        #expect(manager.conversations.first?.title == conversation.title)
    }

    @Test
    @MainActor
    func `failed optimistic deletion preserves an edit still being prepared`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Persisted Title")
        try await store.save(conversation)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            deleteOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value
        var edited = try #require(manager.conversations.first)
        edited.title = "Newest In-Memory Edit"
        edited.updatedAt = Date().addingTimeInterval(1)
        manager.conversations = [edited]
        manager.save(edited)
        // Do not yield between save and delete: the preparation task has not reached
        // the persistence coordinator when optimistic deletion invalidates it.
        manager.deleteConversation(edited)
        await manager.flushPendingSaves()

        #expect(manager.conversations.first?.title == "Newest In-Memory Edit")
        #expect(try await store.loadConversation(id: conversation.id)?.title == "Newest In-Memory Edit")
    }

    @Test
    @MainActor
    func `failed optimistic deletion restores the live row instead of a stale argument`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let staleArgument = TestHelpers.sampleConversation(title: "Stale Argument")
        try await store.save(staleArgument)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            deleteOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value
        var liveConversation = try #require(manager.conversations.first)
        liveConversation.title = "Live Newer State"
        liveConversation.updatedAt = Date().addingTimeInterval(1)
        manager.conversations = [liveConversation]

        manager.deleteConversation(staleArgument)
        await manager.flushPendingSaves()

        #expect(manager.conversations.first?.title == "Live Newer State")
        #expect(try await store.loadConversation(id: staleArgument.id)?.title == "Live Newer State")
    }

    @Test
    @MainActor
    func `clear all conversations empties encrypted store`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let store = TestHelpers.makeTestStore(directory: directory, keychain: keychain)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        manager.conversations = [TestHelpers.sampleConversation()]
        try await store.save(manager.conversations)

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(manager.conversations.isEmpty)
        #expect(try await store.loadConversations().isEmpty)
        #expect(manager.persistenceErrorMessage == nil)
    }

    @Test
    @MainActor
    func `failed clear does not publish a committed history tombstone`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Restored")
        try await store.save(conversation)
        let startedProbe = ConversationClearNotificationProbe()
        let committedProbe = ConversationClearNotificationProbe()
        let rolledBackProbe = ConversationClearNotificationProbe()
        let startedToken = NotificationCenter.default.addObserver(
            forName: .conversationHistoryClearStarted,
            object: nil,
            queue: nil
        ) { _ in
            startedProbe.record()
        }
        let committedToken = NotificationCenter.default.addObserver(
            forName: .conversationHistoryClearCommitted,
            object: nil,
            queue: nil
        ) { _ in
            committedProbe.record()
        }
        let rolledBackToken = NotificationCenter.default.addObserver(
            forName: .conversationHistoryClearRolledBack,
            object: nil,
            queue: nil
        ) { _ in
            rolledBackProbe.record()
        }
        defer {
            NotificationCenter.default.removeObserver(startedToken)
            NotificationCenter.default.removeObserver(committedToken)
            NotificationCenter.default.removeObserver(rolledBackToken)
        }
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            clearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(startedProbe.wasNotified)
        #expect(!committedProbe.wasNotified)
        #expect(rolledBackProbe.wasNotified)
        #expect(manager.conversations.map(\.id) == [conversation.id])
    }

    @Test
    @MainActor
    func `sync recreation requires explicit current-generation authorization`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let original = TestHelpers.sampleConversation(title: "Cleared")
        try await store.save(original)
        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        var staleSync = original
        staleSync.title = "Stale Watch Copy"
        staleSync.updatedAt = Date().addingTimeInterval(10)
        manager.insertConversationFromSync(staleSync)
        await manager.flushPendingSaves()

        #expect(try await store.loadConversation(id: original.id) == nil)
    }

    @Test
    @MainActor
    func `failed deletion preserves a newer sync recreation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let original = TestHelpers.sampleConversation(title: "Original")
        try await store.save(original)
        let deleteGate = FailingManagerDeletionGate()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        _ = await manager.loadingTask?.value
        let loaded = try #require(manager.conversations.first)

        manager.deleteConversation(loaded)
        await deleteGate.waitUntilStarted()
        var synced = original
        synced.title = "Newer Sync Recreation"
        synced.updatedAt = Date().addingTimeInterval(10)
        manager.insertConversationFromSync(synced, allowsRecreation: true)
        await deleteGate.releaseWithFailure()
        await manager.flushPendingSaves()

        #expect(manager.conversations.first?.title == "Newer Sync Recreation")
        #expect(try await store.loadConversation(id: original.id)?.title == "Newer Sync Recreation")
    }

    @Test
    @MainActor
    func `committed clear cleanup failure keeps the manager empty`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            backupRemovalOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Must Stay Cleared")
        try await store.save(conversation)
        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(manager.conversations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))
        #expect(manager.persistenceErrorMessage != nil)
        manager.dismissPersistenceError()
        #expect(manager.persistenceErrorMessage == nil)
    }

    @Test
    @MainActor
    func `committed clear reports both backup and summary cleanup failures`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            backupRemovalOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        try await store.save(TestHelpers.sampleConversation(title: "Cleanup Failures"))
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        let message = try #require(manager.persistenceErrorMessage)
        #expect(message.localizedCaseInsensitiveContains("backup cleanup"))
        #expect(message.localizedCaseInsensitiveContains("summary cleanup"))
    }

    @Test
    @MainActor
    func `recovery-required clear restores visible snapshots without writing`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Still On Disk")
        try await store.save(conversation)
        let releaseProbe = AttachmentCleanupReleaseProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            attachmentCleanupSnapshotOperation: { .empty },
            attachmentCleanupReleaseOperation: {
                releaseProbe.recordRelease()
            },
            clearOperation: {
                throw EncryptedStoreError.clearRecoveryRequired(paths: ["backup"])
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(manager.conversations.map(\.id) == [conversation.id])
        #expect(try await store.loadConversation(id: conversation.id)?.title == conversation.title)
        #expect(releaseProbe.releaseCount == 0)
    }

    @Test
    @MainActor
    func `second clear request also removes conversations created during the first clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let clearGate = BlockingClearOperationGate()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            clearOperation: {
                clearGate.run()
            }
        )
        _ = await manager.loadingTask?.value
        manager.createNewConversation(title: "Before First Clear")

        manager.clearAllConversations()
        while !clearGate.hasStarted() {
            await Task.yield()
        }
        manager.createNewConversation(title: "Created During First Clear")
        manager.clearAllConversations()
        clearGate.release()
        await manager.flushPendingSaves()

        #expect(manager.conversations.isEmpty)
        #expect(try await store.loadConversations().isEmpty)
    }

    @Test
    @MainActor
    func `committed clear snapshots are not restored by an overlapping failed clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let removed = TestHelpers.sampleConversation(title: "Removed by First Clear")
        try await store.save(removed)
        let summaryGate = CommittedSummaryClearGate()
        let clearSequence = SequencedManagerClearOperation(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {
                try await summaryGate.clear()
            },
            clearOperation: {
                try clearSequence.clear()
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await summaryGate.waitUntilStarted()

        manager.clearAllConversations()
        let completion = ClearFlushCompletionProbe()
        let flushTask = Task { @MainActor in
            await manager.flushPendingSaves()
            await completion.complete()
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        #expect(await !(completion.isComplete()))

        await summaryGate.release()
        await flushTask.value

        #expect(await completion.isComplete())
        #expect(manager.persistenceErrorMessage != nil)
        #expect(manager.conversations.isEmpty)
        #expect(try await store.loadConversations().isEmpty)
    }

    @Test
    @MainActor
    func `committed clear preserves a newer same ID snapshot for an overlapping failed clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let original = TestHelpers.sampleConversation(title: "Original Snapshot")
        try await store.save(original)
        let clearGate = BlockingClearOperationGate()
        let clearSequence = SequencedManagerClearOperation(store: store)
        let summaryProbe = OverlappingSummaryRollbackProbe(
            originalConversation: original,
            recreatedTitle: "Recreated During First Clear"
        )
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryInvalidateOperation: {
                summaryProbe.invalidate()
            },
            conversationSummaryRestoreOperation: { snapshot in
                summaryProbe.restore(snapshot)
            },
            conversationSummaryClearOperation: {},
            clearOperation: {
                clearGate.run()
                try clearSequence.clear()
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        while !clearGate.hasStarted() {
            await Task.yield()
        }
        var recreated = original
        recreated.title = "Recreated During First Clear"
        recreated.updatedAt = Date().addingTimeInterval(1)
        manager.insertConversationFromSync(recreated, allowsRecreation: true)
        manager.clearAllConversations()
        clearGate.release()
        await manager.flushPendingSaves()

        #expect(manager.conversations.first?.title == recreated.title)
        #expect(try await store.loadConversation(id: original.id)?.title == recreated.title)
        #expect(summaryProbe.restoredTitles == [recreated.title])
    }

    @Test
    @MainActor
    func `flush waits for committed Spotlight cleanup`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let cleanupGate = SpotlightCleanupGate()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {},
            spotlightCleanupOperation: {
                await cleanupGate.run()
            }
        )
        _ = await manager.loadingTask?.value
        manager.conversations = [TestHelpers.sampleConversation(title: "Spotlight Clear")]
        try await store.save(manager.conversations)

        manager.clearAllConversations()
        await cleanupGate.waitUntilStarted()
        let completion = ClearFlushCompletionProbe()
        let flushTask = Task { @MainActor in
            await manager.flushPendingSaves()
            await completion.complete()
        }

        for _ in 0 ..< 100 {
            await Task.yield()
        }
        #expect(await !(completion.isComplete()))

        await cleanupGate.release()
        await flushTask.value
        #expect(await completion.isComplete())
    }

    @Test
    @MainActor
    func `startup completes pending privacy cleanup before loading conversations`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Pending Privacy Cleanup"))
        try store.clear()
        try store.recordAttachmentCleanupSnapshot(
            .empty,
            for: store.pendingPrivacyCleanupMarkerSnapshot()
        )
        #expect(store.hasPendingPrivacyCleanup())
        let cleanupProbe = PrivacyCleanupProbe()

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {
                await cleanupProbe.recordSummaryCleanup()
            },
            attachmentCleanupOperation: {
                await cleanupProbe.recordAttachmentCleanup()
            },
            spotlightCleanupOperation: {
                await cleanupProbe.recordSpotlightCleanup()
            }
        )
        _ = await manager.loadingTask?.value

        #expect(await cleanupProbe.summaryCleanupCount == 1)
        #expect(await cleanupProbe.attachmentCleanupCount == 1)
        #expect(await cleanupProbe.spotlightCleanupCount == 1)
        #expect(!store.hasPendingPrivacyCleanup())
        #expect(manager.conversations.isEmpty)
    }

    @Test
    @MainActor
    func `startup leaves attachment cleanup pending when marker scope is unknown`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Unknown Attachment Scope"))
        try store.clear()
        let cleanupProbe = PrivacyCleanupProbe()

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {},
            attachmentCleanupOperation: {
                await cleanupProbe.recordAttachmentCleanup()
            },
            spotlightCleanupOperation: {
                await cleanupProbe.recordSpotlightCleanup()
            }
        )
        _ = await manager.loadingTask?.value

        #expect(await cleanupProbe.attachmentCleanupCount == 0)
        #expect(store.hasPendingPrivacyCleanup())
        #expect(manager.persistenceErrorMessage?.localizedCaseInsensitiveContains("attachment cleanup") == true)
    }

    @Test
    @MainActor
    func `failed attachment cleanup keeps privacy cleanup pending`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Pending Attachment Cleanup"))
        try store.clear()
        try store.recordAttachmentCleanupSnapshot(
            .empty,
            for: store.pendingPrivacyCleanupMarkerSnapshot()
        )

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {},
            attachmentCleanupOperation: {
                throw CocoaError(.fileWriteUnknown)
            },
            spotlightCleanupOperation: {}
        )
        _ = await manager.loadingTask?.value

        #expect(store.hasPendingPrivacyCleanup())
        #expect(manager.persistenceErrorMessage?.localizedCaseInsensitiveContains("attachment cleanup") == true)
    }

    @Test
    @MainActor
    func `summary cleanup retry does not replay completed attachment cleanup`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Pending Summary Cleanup"))
        try store.clear()
        try store.recordAttachmentCleanupSnapshot(
            .empty,
            for: store.pendingPrivacyCleanupMarkerSnapshot()
        )
        let cleanupProbe = PrivacyCleanupProbe()

        let firstManager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {
                throw CocoaError(.fileWriteUnknown)
            },
            attachmentCleanupOperation: {
                await cleanupProbe.recordAttachmentCleanup()
            },
            spotlightCleanupOperation: {
                await cleanupProbe.recordSpotlightCleanup()
            }
        )
        _ = await firstManager.loadingTask?.value

        #expect(store.hasPendingPrivacyCleanup())
        #expect(await cleanupProbe.attachmentCleanupCount == 1)
        let firstSpotlightCleanupCount = await cleanupProbe.spotlightCleanupCount
        #expect(firstSpotlightCleanupCount == 1)

        let retryManager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {},
            attachmentCleanupOperation: {
                await cleanupProbe.recordAttachmentCleanup()
            },
            spotlightCleanupOperation: {
                await cleanupProbe.recordSpotlightCleanup()
            }
        )
        _ = await retryManager.loadingTask?.value

        #expect(await cleanupProbe.attachmentCleanupCount == 1)
        let retrySpotlightCleanupCount = await cleanupProbe.spotlightCleanupCount
        #expect(retrySpotlightCleanupCount == 1)
        #expect(!store.hasPendingPrivacyCleanup())
    }

    @Test
    @MainActor
    func `attachment cleanup retry does not replay completed summary cleanup`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Pending Attachment Retry"))
        try store.clear(attachmentCleanupSnapshot: .empty)
        let cleanupProbe = PrivacyCleanupProbe()

        let firstManager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {
                await cleanupProbe.recordSummaryCleanup()
            },
            attachmentCleanupOperation: {
                throw CocoaError(.fileWriteUnknown)
            },
            spotlightCleanupOperation: {}
        )
        _ = await firstManager.loadingTask?.value

        #expect(store.hasPendingPrivacyCleanup())
        #expect(await cleanupProbe.summaryCleanupCount == 1)

        let retryManager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {
                await cleanupProbe.recordSummaryCleanup()
            },
            attachmentCleanupOperation: {},
            spotlightCleanupOperation: {}
        )
        _ = await retryManager.loadingTask?.value

        #expect(await cleanupProbe.summaryCleanupCount == 1)
        #expect(!store.hasPendingPrivacyCleanup())
    }

    @Test
    @MainActor
    func `startup cleanup preserves a privacy marker committed while cleanup is running`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "First Pending Cleanup"))
        try store.clear()
        try store.recordAttachmentCleanupSnapshot(
            .empty,
            for: store.pendingPrivacyCleanupMarkerSnapshot()
        )
        #expect(store.hasPendingPrivacyCleanup())
        let summaryGate = CommittedSummaryClearGate()

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {
                try await summaryGate.clear()
            },
            spotlightCleanupOperation: {}
        )
        await summaryGate.waitUntilStarted()

        try store.clear()
        await summaryGate.release()
        _ = await manager.loadingTask?.value

        #expect(store.hasPendingPrivacyCleanup())
    }

    @Test
    @MainActor
    func `failed clear during initial loading reloads persisted history`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let persisted = TestHelpers.sampleConversation(title: "Persisted Before Startup Clear")
        try await store.save(persisted)
        let metadataGate = InitialLoadRetryMetadataGate(store: store)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationMetadataLoader: {
                try await metadataGate.load()
            },
            clearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        await metadataGate.waitUntilFirstLoadStarted()

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(manager.conversations.map(\.id) == [persisted.id])
        await metadataGate.releaseFirstLoad()
        _ = await manager.loadingTask?.value
    }

    @Test
    @MainActor
    func `conversation created immediately after clear is persisted afterward`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        var existing = TestHelpers.sampleConversation(title: "Before Clear")
        existing.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        manager.conversations = [existing]
        try await store.save(existing)

        manager.clearAllConversations()
        manager.createNewConversation(title: "After Clear")
        let created = try #require(manager.conversations.first)
        manager.renameConversation(created, newTitle: "After Clear Updated")
        let updated = try #require(manager.conversations.first)
        manager.renameConversation(updated, newTitle: "After Clear Final")
        await manager.flushPendingSaves()

        let persisted = try await store.loadConversations()
        #expect(persisted.map(\.title) == ["After Clear Final"])
    }

    @Test
    @MainActor
    func `failed clear restores manager snapshots that were still preparing`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            clearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value
        var conversation = TestHelpers.sampleConversation(title: "Before Failed Clear")
        manager.conversations = [conversation]
        conversation.title = "Latest Manager Snapshot"
        conversation.updatedAt = Date().addingTimeInterval(1)
        manager.conversations = [conversation]
        manager.save(conversation)

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(manager.conversations.first?.title == "Latest Manager Snapshot")
        #expect(try await store.loadConversation(id: conversation.id)?.title == "Latest Manager Snapshot")
    }

    @Test
    @MainActor
    func `flush retries a summary rollback that initially failed to persist`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Restored Conversation")
        let restoreProbe = SequencedSummaryRestoreProbe()
        let summarySnapshot = {
            var digest = RecentConversationsDigest()
            digest.upsertSummary(ConversationSummary(id: conversation.id, title: conversation.title))
            return ConversationSummaryClearSnapshot(digest: digest, wasLoaded: true)
        }()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryInvalidateOperation: {
                summarySnapshot
            },
            conversationSummaryRestoreOperation: { snapshot in
                try await restoreProbe.restore(snapshot)
            },
            clearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value
        manager.conversations = [conversation]

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(await restoreProbe.invocationCount == 2)
        #expect(manager.conversations.map(\.id) == [conversation.id])
        #expect(manager.persistenceErrorMessage?.localizedCaseInsensitiveContains("summary rollback") == true)
    }

    @Test
    @MainActor
    func `older failed clear cannot reset rollback state for a newer clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Preserve Across Clears")
        let restoreGate = OverlappingClearRestoreGate()
        let summarySnapshot = ConversationSummaryClearSnapshot(
            digest: RecentConversationsDigest(),
            wasLoaded: true
        )
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryInvalidateOperation: { summarySnapshot },
            conversationSummaryRestoreOperation: { _ in
                await restoreGate.restore()
            },
            clearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value
        manager.conversations = [conversation]

        manager.clearAllConversations()
        await restoreGate.waitUntilFirstStarted()
        manager.clearAllConversations()
        await restoreGate.releaseFirst()
        await manager.flushPendingSaves()

        #expect(manager.conversations.map(\.id) == [conversation.id])
        #expect(await restoreGate.invocationCount == 2)
    }
}

private actor FailingManagerDeletionGate {
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func delete(_: UUID) async throws {
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
        throw CocoaError(.fileWriteUnknown)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseWithFailure() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor InitialLoadRetryMetadataGate {
    private let store: EncryptedConversationStore
    private var loadCount = 0
    private var firstLoadStarted = false
    private var firstLoadReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func load() async throws -> [ConversationMetadata] {
        loadCount += 1
        let metadata = try await store.loadConversationMetadata()
        guard loadCount == 1 else { return metadata }

        firstLoadStarted = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !firstLoadReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return metadata
    }

    func waitUntilFirstLoadStarted() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseFirstLoad() {
        firstLoadReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class BlockingClearOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func run() {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func hasStarted() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor CommittedSummaryClearGate {
    private var started = false
    private var released = false
    private var finished = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishedContinuations: [CheckedContinuation<Void, Never>] = []

    func clear() async throws {
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        finished = true
        for continuation in finishedContinuations {
            continuation.resume()
        }
        finishedContinuations.removeAll()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            finishedContinuations.append(continuation)
        }
    }
}

private final class SequencedManagerClearOperation: @unchecked Sendable {
    private let store: EncryptedConversationStore
    private let lock = NSLock()
    private var invocationCount = 0

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func clear() throws {
        lock.lock()
        invocationCount += 1
        let invocation = invocationCount
        lock.unlock()

        if invocation == 1 {
            try store.clear()
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private actor SpotlightCleanupGate {
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func run() async {
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}

private actor ClearFlushCompletionProbe {
    private var completed = false

    func complete() {
        completed = true
    }

    func isComplete() -> Bool {
        completed
    }
}

private actor PrivacyCleanupProbe {
    private(set) var summaryCleanupCount = 0
    private(set) var attachmentCleanupCount = 0
    private(set) var spotlightCleanupCount = 0

    func recordSummaryCleanup() {
        summaryCleanupCount += 1
    }

    func recordAttachmentCleanup() {
        attachmentCleanupCount += 1
    }

    func recordSpotlightCleanup() {
        spotlightCleanupCount += 1
    }
}

private actor SequencedSummaryRestoreProbe {
    private(set) var invocationCount = 0

    func restore(_: ConversationSummaryClearSnapshot) throws {
        invocationCount += 1
        if invocationCount == 1 {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

@MainActor
private final class OverlappingSummaryRollbackProbe {
    private let originalConversation: Conversation
    private let recreatedTitle: String
    private var invalidationCount = 0
    private(set) var restoredTitles: [String] = []

    init(originalConversation: Conversation, recreatedTitle: String) {
        self.originalConversation = originalConversation
        self.recreatedTitle = recreatedTitle
    }

    func invalidate() -> ConversationSummaryClearSnapshot {
        invalidationCount += 1
        var digest = RecentConversationsDigest()
        let title = invalidationCount == 1 ? originalConversation.title : recreatedTitle
        digest.upsertSummary(ConversationSummary(id: originalConversation.id, title: title))
        return ConversationSummaryClearSnapshot(digest: digest, wasLoaded: true)
    }

    func restore(_ snapshot: ConversationSummaryClearSnapshot) {
        restoredTitles = snapshot.digest.summaries.map(\.title)
    }
}

private actor OverlappingClearRestoreGate {
    private(set) var invocationCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func restore() async {
        invocationCount += 1
        guard invocationCount == 1 else { return }
        firstStarted = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !firstReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseFirst() {
        firstReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class ConversationClearNotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var notificationCount = 0

    var wasNotified: Bool {
        lock.withLock { notificationCount > 0 }
    }

    func record() {
        lock.withLock { notificationCount += 1 }
    }
}

private final class AttachmentCleanupReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var releaseCount: Int {
        lock.withLock { count }
    }

    func recordRelease() {
        lock.withLock {
            count += 1
        }
    }
}
