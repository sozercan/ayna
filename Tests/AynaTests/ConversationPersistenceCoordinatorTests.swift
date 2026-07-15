@testable import Ayna
import Foundation
import Testing

@Suite("ConversationPersistenceCoordinator Tests", .tags(.persistence, .async), .serialized)
struct ConversationPersistenceCoordinatorTests {
    @Test
    func `flush pending saves persists all queued conversations`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )

        await coordinator.enqueueSave(TestHelpers.sampleConversation(title: "Alpha"))
        await coordinator.enqueueSave(TestHelpers.sampleConversation(title: "Beta"))
        await coordinator.flushPendingSaves()

        let loaded = try await store.loadConversations()
        #expect(Set(loaded.map(\.title)) == Set(["Alpha", "Beta"]))
    }

    @Test
    func `flush pending saves keeps the latest enqueued version`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )

        let conversationId = UUID()
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Original")
        var updated = original
        updated.title = "Updated"

        await coordinator.enqueueSave(original)
        await coordinator.enqueueSave(updated)
        await coordinator.flushPendingSaves()

        let loaded = try await store.loadConversations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Updated")
    }

    @Test
    func `flush waits for an in-flight save without cancelling it`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let saveGate = OrderedConversationSaveGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            }
        )
        let conversationId = UUID()
        let older = TestHelpers.sampleConversation(id: conversationId, title: "Older")

        await coordinator.enqueueSave(older)
        await saveGate.waitUntilFirstSaveStarted()
        let flushTask = Task {
            await coordinator.flushPendingSaves()
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await !(saveGate.firstSaveCancellationWasObserved()))
        await saveGate.releaseFirstSave()
        await flushTask.value

        #expect(await saveGate.savedTitles() == ["Older"])
    }

    @Test
    func `flush snapshot remains the save-chain tail until it finishes`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let saveGate = OrderedConversationSaveGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            }
        )
        let conversationId = UUID()
        let older = TestHelpers.sampleConversation(id: conversationId, title: "Flush snapshot")
        let newer = TestHelpers.sampleConversation(id: conversationId, title: "Later snapshot")

        await coordinator.enqueueSave(older)
        let firstFlush = Task {
            await coordinator.flushPendingSaves()
        }
        await saveGate.waitUntilFirstSaveStarted()

        await coordinator.enqueueSave(newer)
        let secondFlush = Task {
            await coordinator.flushPendingSaves()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await saveGate.saveCountValue() == 1)

        await saveGate.releaseFirstSave()
        await firstFlush.value
        await secondFlush.value

        #expect(await saveGate.savedTitles() == ["Flush snapshot", "Later snapshot"])
    }

    @Test
    func `delete suppresses delayed saves until explicit recreation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )
        var conversation = TestHelpers.sampleConversation(title: "Deleted")

        try await coordinator.delete(conversation.id)
        await coordinator.enqueueSave(conversation)
        try await coordinator.saveImmediately(conversation)
        await coordinator.flushPendingSaves()

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))

        conversation.title = "Restored from sync"
        await coordinator.enqueueSave(conversation, allowsRecreation: true)
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversation.id)?.title == "Restored from sync")
    }

    @Test
    func `derived updates do not replace pending user saves`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )
        let conversationId = UUID()
        let userUpdate = TestHelpers.sampleConversation(id: conversationId, title: "User update")
        let derivedRepair = TestHelpers.sampleConversation(id: conversationId, title: "Derived repair")

        await coordinator.enqueueSave(userUpdate)
        let enqueuedRepair = await coordinator.enqueueDerivedUpdateIfCurrent(derivedRepair)
        await coordinator.flushPendingSaves()

        #expect(!enqueuedRepair)
        #expect(try await store.loadConversation(id: conversationId)?.title == "User update")
    }

    @Test
    func `immediate save cannot be overwritten by a canceled debounced save`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0)
        )
        let conversationId = UUID()
        var stale = TestHelpers.sampleConversation(id: conversationId, title: "Stale")
        stale.messages = [Message(role: .user, content: String(repeating: "payload", count: 100_000))]
        var current = stale
        current.title = "Current"

        await coordinator.enqueueSave(stale)
        try await Task.sleep(for: .milliseconds(1))
        try await coordinator.saveImmediately(current)
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversationId)?.title == "Current")
    }

    @Test
    func `immediate save resolves the latest snapshot after its predecessor`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let saveGate = OrderedConversationSaveGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            }
        )
        let conversationId = UUID()
        let first = TestHelpers.sampleConversation(id: conversationId, title: "First")
        let immediate = TestHelpers.sampleConversation(id: conversationId, title: "Immediate")
        let latest = TestHelpers.sampleConversation(id: conversationId, title: "Latest")

        let firstTask = Task {
            try await coordinator.saveImmediately(first)
        }
        await saveGate.waitUntilFirstSaveStarted()
        let immediateTask = Task {
            try await coordinator.saveImmediately(immediate)
        }
        await saveGate.waitUntilFirstSaveCancellationObserved()
        await coordinator.enqueueSave(latest)
        await saveGate.releaseFirstSave()

        try await firstTask.value
        try await immediateTask.value

        #expect(await saveGate.savedTitles().prefix(2) == ["First", "Latest"])
    }

    @Test
    func `clear waits for in-flight saves and preserves later saves`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0)
        )
        var removed = TestHelpers.sampleConversation(title: "Must stay deleted")
        removed.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        let retained = TestHelpers.sampleConversation(title: "Created after clear")
        let removedId = removed.id

        await coordinator.enqueueSave(removed)
        try await Task.sleep(for: .milliseconds(1))
        let clearGeneration = await coordinator.clearGeneration()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [removedId])
        }
        while await coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }
        await coordinator.enqueueSave(retained)
        try await clearTask.value
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: removedId) == nil)
        #expect(try await store.loadConversation(id: retained.id)?.title == "Created after clear")
    }

    @Test
    func `delete during clear waits and removes the deferred conversation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0)
        )
        var existing = TestHelpers.sampleConversation(title: "Existing")
        existing.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        let createdThenDeleted = TestHelpers.sampleConversation(title: "Created then deleted")
        let existingId = existing.id
        let deletedId = createdThenDeleted.id

        await coordinator.enqueueSave(existing)
        try await Task.sleep(for: .milliseconds(1))
        let clearGeneration = await coordinator.clearGeneration()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [existingId])
        }
        while await coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }
        await coordinator.enqueueSave(createdThenDeleted)
        try await coordinator.delete(deletedId)
        try await clearTask.value
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversations().isEmpty)
    }

    @Test
    func `overlapping clear also removes saves deferred by the first clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0)
        )
        var existing = TestHelpers.sampleConversation(title: "Existing")
        existing.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        let deferred = TestHelpers.sampleConversation(title: "Deferred")
        let existingId = existing.id
        let deferredId = deferred.id

        await coordinator.enqueueSave(existing)
        try await Task.sleep(for: .milliseconds(1))
        let clearGeneration = await coordinator.clearGeneration()
        let firstClear = Task {
            try await coordinator.clearAll(suppressing: [existingId])
        }
        while await coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }
        await coordinator.enqueueSave(deferred)

        let secondClear = Task {
            try await coordinator.clearAll(suppressing: [deferredId])
        }
        try await firstClear.value
        try await secondClear.value
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversations().isEmpty)
    }

    @Test
    func `explicit recreation survives a concurrent delete`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0)
        )
        let conversationId = UUID()
        var original = TestHelpers.sampleConversation(id: conversationId, title: "Original")
        original.messages = [Message(role: .user, content: String(repeating: "payload", count: 100_000))]
        try await store.save(original)
        await coordinator.enqueueSave(original)
        try await Task.sleep(for: .milliseconds(1))

        let deletionGeneration = await coordinator.deletionGeneration(for: conversationId)
        let deleteTask = Task {
            try await coordinator.delete(conversationId)
        }
        while await coordinator.deletionGeneration(for: conversationId) == deletionGeneration {
            await Task.yield()
        }

        var recreation = original
        recreation.title = "Recreated from sync"
        await coordinator.enqueueSave(recreation, allowsRecreation: true)
        recreation.title = "Latest recreation edit"
        recreation.addMessage(Message(role: .user, content: "Latest message"))
        await coordinator.enqueueSave(recreation)
        try await deleteTask.value
        await coordinator.flushPendingSaves()

        let persisted = try #require(try await store.loadConversation(id: conversationId))
        #expect(persisted.title == "Latest recreation edit")
        #expect(persisted.messages.last?.content == "Latest message")
    }

    @Test
    func `failed clear preserves pre-existing delete suppression`() async throws {
        struct ExpectedClearFailure: Error {}

        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Deleted before clear")
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            clearOperation: { throw ExpectedClearFailure() }
        )

        try await coordinator.delete(conversation.id)
        await #expect(throws: ExpectedClearFailure.self) {
            try await coordinator.clearAll(suppressing: [conversation.id])
        }
        await coordinator.enqueueSave(conversation)
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversation.id) == nil)
    }

    @Test
    func `immediate recreation waits for deletion and is durable on return`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )
        let conversationId = UUID()
        var original = TestHelpers.sampleConversation(id: conversationId, title: "Original")
        original.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        try await store.save(original)
        await coordinator.enqueueSave(original)
        try await Task.sleep(for: .milliseconds(1))

        let deletionGeneration = await coordinator.deletionGeneration(for: conversationId)
        let deleteTask = Task {
            try await coordinator.delete(conversationId)
        }
        while await coordinator.deletionGeneration(for: conversationId) == deletionGeneration {
            await Task.yield()
        }

        var immediateRecreation = original
        immediateRecreation.title = "Immediate recreation"
        let immediateSnapshot = immediateRecreation
        let immediateTask = Task {
            try await coordinator.saveImmediately(immediateSnapshot, allowsRecreation: true)
        }
        await Task.yield()
        var latestRecreation = immediateSnapshot
        latestRecreation.title = "Latest recreation snapshot"
        latestRecreation.addMessage(Message(role: .user, content: "Latest queued edit"))
        await coordinator.enqueueSave(latestRecreation)
        try await immediateTask.value

        let persisted = try #require(try await store.loadConversation(id: conversationId))
        #expect(persisted.title == "Latest recreation snapshot")
        #expect(persisted.messages.last?.content == "Latest queued edit")
        try await deleteTask.value
    }

    @Test
    func `flush waits for deletion and persists its queued recreation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )
        let conversationId = UUID()
        var original = TestHelpers.sampleConversation(id: conversationId, title: "Original")
        original.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        try await store.save(original)
        await coordinator.enqueueSave(original)
        try await Task.sleep(for: .milliseconds(1))

        let deletionGeneration = await coordinator.deletionGeneration(for: conversationId)
        let deleteTask = Task {
            try await coordinator.delete(conversationId)
        }
        while await coordinator.deletionGeneration(for: conversationId) == deletionGeneration {
            await Task.yield()
        }

        var recreation = original
        recreation.title = "Recreated before shutdown"
        await coordinator.enqueueSave(recreation, allowsRecreation: true)
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversationId)?.title == "Recreated before shutdown")
        try await deleteTask.value
    }

    @Test
    func `ordinary stale save does not recreate an ID suppressed by clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0)
        )
        var removed = TestHelpers.sampleConversation(title: "Removed")
        removed.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        try await store.save(removed)
        let removedId = removed.id

        let clearGeneration = await coordinator.clearGeneration()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [removedId])
        }
        while await coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }
        await coordinator.enqueueSave(removed)
        try await clearTask.value
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: removedId) == nil)
    }

    @Test
    func `flush waits for clear and persists saves deferred behind it`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )
        var removed = TestHelpers.sampleConversation(title: "Removed")
        removed.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        let retained = TestHelpers.sampleConversation(title: "Deferred until clear finishes")
        let removedId = removed.id
        let retainedId = retained.id
        let retainedTitle = retained.title
        try await store.save(removed)

        let clearGeneration = await coordinator.clearGeneration()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [removedId])
        }
        while await coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }
        await coordinator.enqueueSave(retained)
        await coordinator.flushPendingSaves()
        try await clearTask.value

        #expect(try await store.loadConversation(id: removedId) == nil)
        #expect(try await store.loadConversation(id: retainedId)?.title == retainedTitle)
    }

    @Test
    func `repeated delete overrides a queued recreation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0)
        )
        let conversationId = UUID()
        var original = TestHelpers.sampleConversation(id: conversationId, title: "Original")
        original.messages = [Message(role: .user, content: String(repeating: "payload", count: 500_000))]
        try await store.save(original)
        await coordinator.enqueueSave(original)
        try await Task.sleep(for: .milliseconds(1))

        let deletionGeneration = await coordinator.deletionGeneration(for: conversationId)
        let firstDelete = Task { try await coordinator.delete(conversationId) }
        while await coordinator.deletionGeneration(for: conversationId) == deletionGeneration {
            await Task.yield()
        }
        var recreation = original
        recreation.title = "Should not survive"
        await coordinator.enqueueSave(recreation, allowsRecreation: true)
        let secondDelete = Task { try await coordinator.delete(conversationId) }

        try await firstDelete.value
        try await secondDelete.value
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversationId) == nil)
    }

    @Test
    func `repeated delete retries after the first deletion fails`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let deleteGate = FailingThenSuccessfulDeleteGate(store: store)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Delete Twice")
        try await store.save(conversation)

        let firstDelete = Task {
            try await coordinator.delete(conversation.id)
        }
        await deleteGate.waitUntilFirstStarted()
        let secondDelete = Task {
            try await coordinator.delete(conversation.id)
        }
        await deleteGate.releaseFirstWithFailure()

        await #expect(throws: CocoaError.self) {
            try await firstDelete.value
        }
        try await secondDelete.value
        await coordinator.flushPendingSaves()

        #expect(await deleteGate.invocationCount == 2)
        #expect(try await store.loadConversation(id: conversation.id) == nil)
    }

    @Test
    func `failed repeated delete restores queued recreation and releases suppression`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let deleteGate = SuccessfulThenFailingDeleteGate(store: store)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        let conversationId = UUID()
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Original")
        try await store.save(original)

        let firstDelete = Task {
            try await coordinator.delete(conversationId)
        }
        await deleteGate.waitUntilFirstStarted()

        var recreation = original
        recreation.title = "Queued recreation"
        await coordinator.enqueueSave(recreation, allowsRecreation: true)
        let secondDelete = Task {
            try await coordinator.delete(conversationId)
        }

        await deleteGate.releaseFirstWithSuccess()
        try await firstDelete.value
        await #expect(throws: CocoaError.self) {
            try await secondDelete.value
        }

        var latest = recreation
        latest.title = "Saved after repeated delete failure"
        await coordinator.enqueueSave(latest)
        await coordinator.flushPendingSaves()

        #expect(await deleteGate.invocationCount == 2)
        #expect(try await store.loadConversation(id: conversationId)?.title == latest.title)
    }

    @Test
    func `failed clear restores a snapshot already being persisted`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let saveGate = CancelledFirstSaveGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            },
            clearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Restore In-Flight Snapshot")

        await coordinator.enqueueSave(conversation)
        await saveGate.waitUntilFirstSaveStarted()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [conversation.id])
        }
        await saveGate.waitUntilFirstSaveCancellationObserved()

        do {
            try await clearTask.value
            Issue.record("Expected clear to fail")
        } catch {
            // Expected failure restores the in-flight snapshot.
        }
        await coordinator.flushPendingSaves()

        #expect(await saveGate.savedTitles() == ["Restore In-Flight Snapshot"])
    }

    @Test
    func `committed clear cleanup failure does not restore suppressed saves`() async throws {
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
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )
        let conversation = TestHelpers.sampleConversation(title: "Must Stay Cleared")
        try await store.save(conversation)
        await coordinator.enqueueSave(conversation)

        do {
            try await coordinator.clearAll(suppressing: [conversation.id])
            Issue.record("Expected committed clear cleanup failure")
        } catch let error as EncryptedStoreError {
            guard case .clearBackupCleanupFailed = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
        await coordinator.flushPendingSaves()

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))
    }

    @Test
    func `save failure notification observes cleared persistence state`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let notificationGate = SaveFailureNotificationGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            saveOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            },
            saveFailureNotificationOperation: { conversationId in
                await notificationGate.notify(conversationId)
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Failed Save")

        await coordinator.enqueueSave(conversation)
        let notifiedId = await notificationGate.waitUntilStarted()
        let reconciliationState = await coordinator.reconciliationState()

        #expect(notifiedId == conversation.id)
        #expect(!reconciliationState.dirtyIds.contains(conversation.id))
        await notificationGate.release()
        await coordinator.flushPendingSaves()
    }

    @Test
    func `failed deletion overlapping clear keeps ordinary saves suppressed`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let deleteGate = FailingDeletionGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            },
            clearOperation: {}
        )
        let conversation = TestHelpers.sampleConversation(title: "Must Not Return")

        let deleteTask = Task {
            try await coordinator.delete(conversation.id)
        }
        await deleteGate.waitUntilStarted()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [])
        }
        while await !(coordinator.isClearing()) {
            await Task.yield()
        }
        await deleteGate.releaseWithFailure()

        do {
            try await deleteTask.value
            Issue.record("Expected deletion to fail")
        } catch {
            // Expected: the overlapping clear still owns suppression for this ID.
        }
        try await clearTask.value
        await coordinator.enqueueSave(conversation)
        #expect(await !(coordinator.pendingConversationIds().contains(conversation.id)))
        await coordinator.flushPendingSaves()

        let loadedConversation = try await store.loadConversation(id: conversation.id)
        #expect(loadedConversation == nil)
    }

    @Test
    func `failed deletion restores the latest queued edit`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversationId = UUID()
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Persisted")
        var edited = original
        edited.title = "Queued Edit"
        edited.updatedAt = Date().addingTimeInterval(1)
        try await store.save(original)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            deleteOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        await coordinator.enqueueSave(edited)

        do {
            try await coordinator.delete(conversationId)
            Issue.record("Expected deletion to fail")
        } catch {
            // Expected: rollback must persist the queued edit before returning.
        }

        #expect(try await store.loadConversation(id: conversationId)?.title == "Queued Edit")
    }

    @Test
    func `superseded save cancellation does not publish a failure notification`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let saveGate = CancelledFirstSaveGate()
        let notificationRecorder = SaveFailureNotificationRecorder()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            },
            saveFailureNotificationOperation: { _ in
                await notificationRecorder.record()
            }
        )
        let conversationId = UUID()
        let first = TestHelpers.sampleConversation(id: conversationId, title: "First")
        let second = TestHelpers.sampleConversation(id: conversationId, title: "Second")

        await coordinator.enqueueSave(first)
        await saveGate.waitUntilFirstSaveStarted()
        await coordinator.enqueueSave(second)
        await saveGate.waitUntilFirstSaveCancellationObserved()
        await coordinator.flushPendingSaves()

        #expect(await notificationRecorder.count() == 0)
        #expect(await saveGate.savedTitles() == ["Second"])
    }
}

private actor SaveFailureNotificationRecorder {
    private var recordedCount = 0

    func record() {
        recordedCount += 1
    }

    func count() -> Int {
        recordedCount
    }
}

private actor FailingDeletionGate {
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

private actor SaveFailureNotificationGate {
    private var notifiedId: UUID?
    private var released = false
    private var startedContinuations: [CheckedContinuation<UUID, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func notify(_ conversationId: UUID) async {
        notifiedId = conversationId
        for continuation in startedContinuations {
            continuation.resume(returning: conversationId)
        }
        startedContinuations.removeAll()

        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilStarted() async -> UUID {
        if let notifiedId {
            return notifiedId
        }
        return await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor OrderedConversationSaveGate {
    private var saveCount = 0
    private var firstSaveStarted = false
    private var firstSaveCancellationObserved = false
    private var firstSaveReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var titles: [String] = []

    func save(_ conversation: Conversation) async throws {
        saveCount += 1
        if saveCount == 1 {
            firstSaveStarted = true
            for continuation in startedContinuations {
                continuation.resume()
            }
            startedContinuations.removeAll()

            while !Task.isCancelled, !firstSaveReleased {
                await Task.yield()
            }
            if Task.isCancelled {
                firstSaveCancellationObserved = true
                for continuation in cancellationContinuations {
                    continuation.resume()
                }
                cancellationContinuations.removeAll()
            }

            if !firstSaveReleased {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
        }

        titles.append(conversation.title)
    }

    func waitUntilFirstSaveCancellationObserved() async {
        guard !firstSaveCancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    func waitUntilFirstSaveStarted() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseFirstSave() {
        firstSaveReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func savedTitles() -> [String] {
        titles
    }

    func firstSaveCancellationWasObserved() -> Bool {
        firstSaveCancellationObserved
    }

    func saveCountValue() -> Int {
        saveCount
    }
}

private actor CancelledFirstSaveGate {
    private var saveCount = 0
    private var firstSaveStarted = false
    private var firstSaveCancellationObserved = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []
    private var titles: [String] = []

    func save(_ conversation: Conversation) async throws {
        saveCount += 1
        if saveCount == 1 {
            firstSaveStarted = true
            for continuation in startedContinuations {
                continuation.resume()
            }
            startedContinuations.removeAll()
            while !Task.isCancelled {
                await Task.yield()
            }
            firstSaveCancellationObserved = true
            for continuation in cancellationContinuations {
                continuation.resume()
            }
            cancellationContinuations.removeAll()
            throw CancellationError()
        }
        titles.append(conversation.title)
    }

    func waitUntilFirstSaveStarted() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func waitUntilFirstSaveCancellationObserved() async {
        guard !firstSaveCancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    func savedTitles() -> [String] {
        titles
    }
}

private actor FailingThenSuccessfulDeleteGate {
    private let store: EncryptedConversationStore
    private(set) var invocationCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func delete(_ conversationId: UUID) async throws {
        invocationCount += 1
        if invocationCount == 1 {
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
            throw CocoaError(.fileWriteUnknown)
        }
        try await store.delete(conversationId)
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseFirstWithFailure() {
        firstReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SuccessfulThenFailingDeleteGate {
    private let store: EncryptedConversationStore
    private(set) var invocationCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func delete(_ conversationId: UUID) async throws {
        invocationCount += 1
        if invocationCount == 1 {
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
            try await store.delete(conversationId)
            return
        }
        throw CocoaError(.fileWriteUnknown)
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseFirstWithSuccess() {
        firstReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
