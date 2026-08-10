@testable import Ayna
import Foundation
import Testing

@Suite("ConversationPersistenceCoordinator Deletion Race Tests", .tags(.persistence, .async), .serialized)
@MainActor
struct CoordinatorDeletionRaceTests {
    @Test
    func `repeated delete retry remains registered while original caller unwinds`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let deleteGate = FailingThenBlockedSuccessfulDeleteGate(store: store)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Delete Retry")
        try await store.save(conversation)

        let firstDelete = Task {
            try await coordinator.delete(conversation.id)
        }
        await deleteGate.waitUntilFirstStarted()
        let secondDelete = Task {
            try await coordinator.delete(conversation.id)
        }

        await deleteGate.releaseFirstWithFailure()
        await deleteGate.waitUntilSecondStarted()
        await #expect(throws: CocoaError.self) {
            try await firstDelete.value
        }

        #expect(await coordinator.isDeleting(conversation.id))

        await deleteGate.releaseSecondWithSuccess()
        try await secondDelete.value

        #expect(await !(coordinator.isDeleting(conversation.id)))
        #expect(try await store.loadConversation(id: conversation.id) == nil)
    }

    @Test
    func `superseded failed delete cannot restore after a successful retry`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let deleteGate = FailingThenCommittedSuccessfulDeleteGate(store: store)
        let recoverySaveRecorder = DeleteRecoverySaveRecorder(store: store, deleteGate: deleteGate)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            saveOperation: { conversation in
                try await recoverySaveRecorder.save(conversation)
            },
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        let conversationId = UUID()
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Persisted")
        var queuedSnapshot = original
        queuedSnapshot.title = "Queued snapshot"
        try await store.save(original)
        await coordinator.enqueueSave(queuedSnapshot)

        let firstDelete = Task {
            try await coordinator.delete(conversationId)
        }
        await deleteGate.waitUntilFirstStarted()
        let secondDelete = Task {
            try await coordinator.delete(conversationId)
        }

        await deleteGate.releaseFirstWithFailure()
        await deleteGate.waitUntilSecondCommitted()
        await #expect(throws: CocoaError.self) {
            try await firstDelete.value
        }

        #expect(await recoverySaveRecorder.invocationCount == 0)

        await deleteGate.releaseSecondWithSuccess()
        try await secondDelete.value
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversationId) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `repeated delete failures restore the snapshot captured by the first attempt`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let deleteGate = FailingTwiceDeleteGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        let conversationId = UUID()
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Persisted")
        var queuedSnapshot = original
        queuedSnapshot.title = "Latest queued edit"
        try await store.save(original)
        await coordinator.enqueueSave(queuedSnapshot)

        let firstDelete = Task {
            try await coordinator.delete(conversationId)
        }
        await deleteGate.waitUntilFirstStarted()
        let secondDelete = Task {
            try await coordinator.delete(conversationId)
        }

        await deleteGate.releaseFirstWithFailure()
        await #expect(throws: CocoaError.self) {
            try await firstDelete.value
        }
        await #expect(throws: CocoaError.self) {
            try await secondDelete.value
        }
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversationId)?.title == queuedSnapshot.title)
    }

    @Test(.timeLimit(.minutes(1)))
    func `overlapping deletes behind a failed clear preserve the earliest rollback`() async throws {
        struct ExpectedClearFailure: Error {}

        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversationId = UUID()
        let blockerId = UUID()
        let saveGate = ClearWaitingRollbackSaveGate(
            store: store,
            initiallyBlockedIds: [conversationId, blockerId]
        )
        let deleteGate = DeletionRaceFailingDeletionGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            },
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            },
            clearOperation: {
                throw ExpectedClearFailure()
            }
        )
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Persisted")
        var queuedSnapshot = original
        queuedSnapshot.title = "Latest queued edit"
        let expectedQueuedTitle = queuedSnapshot.title
        let blocker = TestHelpers.sampleConversation(id: blockerId, title: "Clear blocker")
        try await store.save(original)

        let targetSave = coordinator.registerImmediateSave(queuedSnapshot)
        await saveGate.waitUntilInitialSaveStarted(for: conversationId)
        let blockerSave = coordinator.registerImmediateSave(blocker)

        let clearGeneration = await coordinator.clearGeneration()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [blockerId])
        }
        while await coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }

        let initialDeleteGeneration = await coordinator.deletionGeneration(for: conversationId)
        let firstDelete = Task {
            try await coordinator.delete(conversationId)
        }
        while await coordinator.deletionGeneration(for: conversationId) == initialDeleteGeneration {
            await Task.yield()
        }

        await saveGate.releaseInitialSave(for: conversationId)
        #expect(await targetSave.value == .superseded)
        await saveGate.waitUntilInitialSaveStarted(for: blockerId)

        let firstDeleteGeneration = await coordinator.deletionGeneration(for: conversationId)
        let secondDelete = Task {
            try await coordinator.delete(conversationId)
        }
        while await coordinator.deletionGeneration(for: conversationId) == firstDeleteGeneration {
            await Task.yield()
        }

        await saveGate.releaseInitialSave(for: blockerId)
        #expect(await blockerSave.value == .superseded)
        do {
            try await clearTask.value
            Issue.record("Expected clear to fail")
        } catch {
            // The compatibility API intentionally erases the store's concrete error type.
        }

        await deleteGate.waitUntilStarted()
        await #expect(throws: CancellationError.self) {
            try await firstDelete.value
        }
        await deleteGate.releaseWithFailure()
        await #expect(throws: CocoaError.self) {
            try await secondDelete.value
        }
        await coordinator.flushPendingSaves()

        #expect(try await store.loadConversation(id: conversationId)?.title == expectedQueuedTitle)
    }

    @Test(.timeLimit(.minutes(1)))
    func `delete waiting on a superseded clear observes a newer committed clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Cleared conversation")
        let saveGate = ClearWaitingRollbackSaveGate(
            store: store,
            initiallyBlockedIds: [conversation.id]
        )
        let deleteRecorder = UnexpectedFailingDeleteRecorder()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            },
            deleteOperation: { conversationId in
                try await deleteRecorder.delete(conversationId)
            },
            clearOperation: {
                try store.clear()
            }
        )
        try await store.save(conversation)
        let save = coordinator.registerImmediateSave(conversation)
        await saveGate.waitUntilInitialSaveStarted(for: conversation.id)

        let firstClearGeneration = coordinator.clearGeneration()
        let firstClear = Task {
            try await coordinator.clearAll(suppressing: [conversation.id])
        }
        while coordinator.clearGeneration() == firstClearGeneration {
            await Task.yield()
        }

        let deleteGeneration = coordinator.deletionGeneration(for: conversation.id)
        let deletion = Task {
            try await coordinator.delete(conversation.id)
        }
        while coordinator.deletionGeneration(for: conversation.id) == deleteGeneration {
            await Task.yield()
        }

        let secondClearGeneration = coordinator.clearGeneration()
        let secondClear = Task {
            try await coordinator.clearAll(suppressing: [conversation.id])
        }
        while coordinator.clearGeneration() == secondClearGeneration {
            await Task.yield()
        }

        await saveGate.releaseInitialSave(for: conversation.id)
        #expect(await save.value == .superseded)
        try await firstClear.value
        try await secondClear.value
        do {
            try await deletion.value
        } catch {
            Issue.record("Delete should be settled by the newer committed clear: \(error)")
        }
        await coordinator.flushPendingSaves()

        #expect(await deleteRecorder.invocationCount == 0)
        #expect(try await store.loadConversation(id: conversation.id) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `successful delete discards inherited rollback before a failed retry`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let deleteGate = RaceSuccessfulThenFailingDeleteGate(store: store)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        let conversationId = UUID()
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Persisted")
        var queuedSnapshot = original
        queuedSnapshot.title = "Must not be restored"
        try await store.save(original)
        await coordinator.enqueueSave(queuedSnapshot)

        let firstDelete = Task {
            try await coordinator.delete(conversationId)
        }
        await deleteGate.waitUntilFirstStarted()
        let firstDeleteGeneration = await coordinator.deletionGeneration(for: conversationId)
        let secondDelete = Task {
            try await coordinator.delete(conversationId)
        }
        while await coordinator.deletionGeneration(for: conversationId) == firstDeleteGeneration {
            await Task.yield()
        }

        await deleteGate.releaseFirstWithSuccess()
        await #expect(throws: CancellationError.self) {
            try await firstDelete.value
        }
        await #expect(throws: CocoaError.self) {
            try await secondDelete.value
        }

        #expect(try await store.loadConversation(id: conversationId) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `superseded delete reports cancellation after a shared clear fails`() async throws {
        struct ExpectedClearFailure: Error {}

        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let saveGate = DeletionRaceOrderedConversationSaveGate()
        let deleteGate = DeletionRaceFailingDeletionGate()
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .milliseconds(0),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            },
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            },
            clearOperation: {
                throw ExpectedClearFailure()
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Delete after failed clear")
        await coordinator.enqueueSave(conversation)
        await saveGate.waitUntilFirstSaveStarted()

        let clearGeneration = coordinator.clearGeneration()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [conversation.id])
        }
        while coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }

        let initialDeleteGeneration = await coordinator.deletionGeneration(for: conversation.id)
        let firstDelete = Task {
            try await coordinator.delete(conversation.id)
        }
        while await coordinator.deletionGeneration(for: conversation.id) == initialDeleteGeneration {
            await Task.yield()
        }
        let firstDeleteGeneration = await coordinator.deletionGeneration(for: conversation.id)
        let secondDelete = Task {
            try await coordinator.delete(conversation.id)
        }
        while await coordinator.deletionGeneration(for: conversation.id) == firstDeleteGeneration {
            await Task.yield()
        }

        await saveGate.releaseFirstSave()
        do {
            try await clearTask.value
            Issue.record("Expected clear to fail")
        } catch {
            // The compatibility API intentionally erases the store's concrete error type.
        }
        await deleteGate.waitUntilStarted()
        await #expect(throws: CancellationError.self) {
            try await firstDelete.value
        }

        await deleteGate.releaseWithFailure()
        await #expect(throws: CocoaError.self) {
            try await secondDelete.value
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `superseded successful delete cancels while the retry can still fail`() async throws {
        struct ExpectedClearFailure: Error {}

        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversationId = UUID()
        let saveGate = ClearWaitingRollbackSaveGate(
            store: store,
            initiallyBlockedIds: [conversationId]
        )
        let deleteGate = SuccessfulThenBlockedFailingDeleteGate(store: store)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10),
            saveOperation: { conversation in
                try await saveGate.save(conversation)
            },
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            },
            clearOperation: {
                throw ExpectedClearFailure()
            }
        )
        let conversation = TestHelpers.sampleConversation(
            id: conversationId,
            title: "Delete after failed clear"
        )
        try await store.save(conversation)
        let saveTask = coordinator.registerImmediateSave(conversation)
        await saveGate.waitUntilInitialSaveStarted(for: conversation.id)

        let clearGeneration = await coordinator.clearGeneration()
        let clearTask = Task {
            try await coordinator.clearAll(suppressing: [conversation.id])
        }
        while await coordinator.clearGeneration() == clearGeneration {
            await Task.yield()
        }

        let initialDeleteGeneration = await coordinator.deletionGeneration(for: conversation.id)
        let firstDelete = Task {
            try await coordinator.delete(conversation.id)
        }
        while await coordinator.deletionGeneration(for: conversation.id) == initialDeleteGeneration {
            await Task.yield()
        }

        await saveGate.releaseInitialSave(for: conversation.id)
        #expect(await saveTask.value == .superseded)
        do {
            try await clearTask.value
            Issue.record("Expected clear to fail")
        } catch {
            // The compatibility API intentionally erases the store's concrete error type.
        }
        await deleteGate.waitUntilFirstStarted()

        let firstDeleteGeneration = await coordinator.deletionGeneration(for: conversation.id)
        let secondDelete = Task {
            try await coordinator.delete(conversation.id)
        }
        while await coordinator.deletionGeneration(for: conversation.id) == firstDeleteGeneration {
            await Task.yield()
        }

        await deleteGate.releaseFirstWithSuccess()
        await deleteGate.waitUntilSecondStarted()
        await #expect(throws: CancellationError.self) {
            try await firstDelete.value
        }
        #expect(await coordinator.isDeleting(conversation.id))

        await deleteGate.releaseSecondWithFailure()
        await #expect(throws: CocoaError.self) {
            try await secondDelete.value
        }
    }
}

private actor ClearWaitingRollbackSaveGate {
    private let store: EncryptedConversationStore
    private let initiallyBlockedIds: Set<UUID>
    private var invocationCounts: [UUID: Int] = [:]
    private var startedIds: Set<UUID> = []
    private var releasedIds: Set<UUID> = []
    private var startedContinuations: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(store: EncryptedConversationStore, initiallyBlockedIds: Set<UUID>) {
        self.store = store
        self.initiallyBlockedIds = initiallyBlockedIds
    }

    func save(_ conversation: Conversation) async throws {
        invocationCounts[conversation.id, default: 0] += 1
        if initiallyBlockedIds.contains(conversation.id), invocationCounts[conversation.id] == 1 {
            startedIds.insert(conversation.id)
            for continuation in startedContinuations.removeValue(forKey: conversation.id) ?? [] {
                continuation.resume()
            }
            if !releasedIds.contains(conversation.id) {
                await withCheckedContinuation { continuation in
                    releaseContinuations[conversation.id] = continuation
                }
            }
            throw CancellationError()
        }

        try await store.save(conversation)
    }

    func waitUntilInitialSaveStarted(for conversationId: UUID) async {
        guard !startedIds.contains(conversationId) else { return }
        await withCheckedContinuation { continuation in
            startedContinuations[conversationId, default: []].append(continuation)
        }
    }

    func releaseInitialSave(for conversationId: UUID) {
        releasedIds.insert(conversationId)
        releaseContinuations.removeValue(forKey: conversationId)?.resume()
    }
}

private actor DeletionRaceFailingDeletionGate {
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

private actor UnexpectedFailingDeleteRecorder {
    private(set) var invocationCount = 0

    func delete(_: UUID) async throws {
        invocationCount += 1
        throw CocoaError(.fileWriteUnknown)
    }
}

private actor SuccessfulThenBlockedFailingDeleteGate {
    private let store: EncryptedConversationStore
    private var invocationCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var secondStarted = false
    private var secondReleased = false
    private var firstStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var secondStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func delete(_ conversationId: UUID) async throws {
        invocationCount += 1
        if invocationCount == 1 {
            firstStarted = true
            for continuation in firstStartedContinuations {
                continuation.resume()
            }
            firstStartedContinuations.removeAll()
            if !firstReleased {
                await withCheckedContinuation { continuation in
                    firstReleaseContinuation = continuation
                }
            }
            try await store.delete(conversationId)
            return
        }

        secondStarted = true
        for continuation in secondStartedContinuations {
            continuation.resume()
        }
        secondStartedContinuations.removeAll()
        if !secondReleased {
            await withCheckedContinuation { continuation in
                secondReleaseContinuation = continuation
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuations.append(continuation)
        }
    }

    func waitUntilSecondStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { continuation in
            secondStartedContinuations.append(continuation)
        }
    }

    func releaseFirstWithSuccess() {
        firstReleased = true
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func releaseSecondWithFailure() {
        secondReleased = true
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }
}

private actor DeletionRaceOrderedConversationSaveGate {
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

private actor FailingTwiceDeleteGate {
    private var invocationCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var firstStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    func delete(_: UUID) async throws {
        invocationCount += 1
        if invocationCount == 1 {
            firstStarted = true
            for continuation in firstStartedContinuations {
                continuation.resume()
            }
            firstStartedContinuations.removeAll()
            if !firstReleased {
                await withCheckedContinuation { continuation in
                    firstReleaseContinuation = continuation
                }
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuations.append(continuation)
        }
    }

    func releaseFirstWithFailure() {
        firstReleased = true
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }
}

private actor FailingThenBlockedSuccessfulDeleteGate {
    private let store: EncryptedConversationStore
    private var invocationCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var secondStarted = false
    private var secondReleased = false
    private var firstStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var secondStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func delete(_ conversationId: UUID) async throws {
        invocationCount += 1
        if invocationCount == 1 {
            firstStarted = true
            for continuation in firstStartedContinuations {
                continuation.resume()
            }
            firstStartedContinuations.removeAll()
            if !firstReleased {
                await withCheckedContinuation { continuation in
                    firstReleaseContinuation = continuation
                }
            }
            throw CocoaError(.fileWriteUnknown)
        }

        secondStarted = true
        for continuation in secondStartedContinuations {
            continuation.resume()
        }
        secondStartedContinuations.removeAll()
        if !secondReleased {
            await withCheckedContinuation { continuation in
                secondReleaseContinuation = continuation
            }
        }
        try await store.delete(conversationId)
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuations.append(continuation)
        }
    }

    func waitUntilSecondStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { continuation in
            secondStartedContinuations.append(continuation)
        }
    }

    func releaseFirstWithFailure() {
        firstReleased = true
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func releaseSecondWithSuccess() {
        secondReleased = true
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }
}

private actor FailingThenCommittedSuccessfulDeleteGate {
    private let store: EncryptedConversationStore
    private var invocationCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var secondCommitted = false
    private var secondReleased = false
    private var firstStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var secondCommittedContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func delete(_ conversationId: UUID) async throws {
        invocationCount += 1
        if invocationCount == 1 {
            firstStarted = true
            for continuation in firstStartedContinuations {
                continuation.resume()
            }
            firstStartedContinuations.removeAll()
            if !firstReleased {
                await withCheckedContinuation { continuation in
                    firstReleaseContinuation = continuation
                }
            }
            throw CocoaError(.fileWriteUnknown)
        }

        try await store.delete(conversationId)
        secondCommitted = true
        for continuation in secondCommittedContinuations {
            continuation.resume()
        }
        secondCommittedContinuations.removeAll()
        if !secondReleased {
            await withCheckedContinuation { continuation in
                secondReleaseContinuation = continuation
            }
        }
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedContinuations.append(continuation)
        }
    }

    func waitUntilSecondCommitted() async {
        guard !secondCommitted else { return }
        await withCheckedContinuation { continuation in
            secondCommittedContinuations.append(continuation)
        }
    }

    func releaseFirstWithFailure() {
        firstReleased = true
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func releaseSecondWithSuccess() {
        secondReleased = true
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }
}

private actor DeleteRecoverySaveRecorder {
    private let store: EncryptedConversationStore
    private let deleteGate: FailingThenCommittedSuccessfulDeleteGate
    private(set) var invocationCount = 0

    init(store: EncryptedConversationStore, deleteGate: FailingThenCommittedSuccessfulDeleteGate) {
        self.store = store
        self.deleteGate = deleteGate
    }

    func save(_ conversation: Conversation) async throws {
        await deleteGate.waitUntilSecondCommitted()
        invocationCount += 1
        try await store.save(conversation)
    }
}

private actor RaceSuccessfulThenFailingDeleteGate {
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
