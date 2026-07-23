@testable import Ayna
import Foundation
import Testing

@Suite("ConversationManager Privacy Regression Tests", .tags(.viewModel, .persistence), .serialized)
@MainActor
struct ConversationManagerPrivacyTests {
    private let defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: "ConversationManagerPrivacyRegressionTests") else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "ConversationManagerPrivacyRegressionTests")
        AppPreferences.use(defaults)
        defaults.set(false, forKey: "autoGenerateTitle")
    }

    @Test
    func `optimistic deletion suppresses summary until failure restores it`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Summary Rollback")
        try await store.save(conversation)
        let deleteGate = PrivacyFailingDeletionGate()
        let summaryProbe = PrivacySummaryMutationProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryRemoveOperation: { conversationId in
                summaryProbe.remove(conversationId)
            },
            conversationSummaryUpdateOperation: { conversation in
                summaryProbe.update(conversation)
            },
            deleteOperation: { conversationId in
                try await deleteGate.delete(conversationId)
            }
        )
        _ = await manager.loadingTask?.value
        let loaded = try #require(manager.conversations.first)

        manager.deleteConversation(loaded)
        await deleteGate.waitUntilStarted()

        #expect(summaryProbe.removedIds == [conversation.id])
        #expect(summaryProbe.updatedTitles.isEmpty)
        #expect(manager.conversations.isEmpty)

        await deleteGate.releaseWithFailure()
        await manager.flushPendingSaves()

        #expect(summaryProbe.updatedTitles == [conversation.title])
        #expect(manager.conversations.map(\.id) == [conversation.id])
    }

    @Test
    func `failed deletion cannot repopulate a committed overlapping clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Must Stay Cleared")
        try await store.save(conversation)
        let deleteGate = PrivacyFailingDeletionGate()
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
        manager.clearAllConversations()
        await deleteGate.releaseWithFailure()
        await manager.flushPendingSaves()

        #expect(manager.conversations.isEmpty)
        #expect(try await store.loadConversation(id: conversation.id) == nil)
    }

    @Test
    func `overlapping clear reacquires attachment fence after predecessor finishes`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let clearGate = PrivacyBlockingClearGate()
        let fenceProbe = PrivacyAttachmentFenceProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            attachmentCleanupFenceBeginOperation: {
                _ = fenceProbe.begin()
            },
            attachmentCleanupSnapshotOperation: { .empty },
            attachmentCleanupReleaseOperation: {
                fenceProbe.finish()
            },
            clearOperation: {
                clearGate.run()
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        while !clearGate.hasStarted() {
            await Task.yield()
        }
        manager.clearAllConversations()

        #expect(fenceProbe.beginCallCount == 2)
        clearGate.release()
        await manager.flushPendingSaves()

        #expect(fenceProbe.beginCallCount == 2)
        #expect(fenceProbe.releaseCount == 2)
        #expect(fenceProbe.unbalancedReleaseCount == 0)
    }

    @Test
    func `attachment snapshot enumeration runs away from the main thread`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let threadProbe = PrivacySnapshotThreadProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            attachmentCleanupFenceBeginOperation: {},
            attachmentCleanupSnapshotOperation: {
                threadProbe.recordCurrentThread()
                return .empty
            },
            clearOperation: {}
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(threadProbe.didRun)
        #expect(!threadProbe.ranOnMainThread)
    }

    @Test
    func `attachment snapshot failure rolls back without committing clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Snapshot Failure Rollback")
        try await store.save(conversation)
        let clearProbe = PrivacyClearInvocationProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            attachmentCleanupSnapshotOperation: {
                throw CocoaError(.fileReadUnknown)
            },
            clearOperation: {
                clearProbe.record()
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(!clearProbe.wasInvoked)
        #expect(manager.conversations.map(\.id) == [conversation.id])
        #expect(try await store.loadConversation(id: conversation.id)?.title == conversation.title)
        #expect(manager.persistenceErrorMessage != nil)
    }

    @Test
    func `post-commit privacy marker scan failure releases attachment fence`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let listingProbe = PrivacyMarkerScanFailureProbe()
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            backupRemovalOperation: { backupURL in
                try FileManager.default.removeItem(at: backupURL)
                listingProbe.enableFailure()
            },
            clearArtifactDirectoryContentsOperation: { directoryURL in
                try listingProbe.contents(of: directoryURL)
            }
        )
        try await store.save(TestHelpers.sampleConversation(title: "Committed Before Scan Failure"))
        let fenceProbe = PrivacyAttachmentFenceProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            attachmentCleanupFenceBeginOperation: {
                _ = fenceProbe.begin()
            },
            attachmentCleanupSnapshotOperation: { .empty },
            attachmentCleanupReleaseOperation: {
                fenceProbe.finish()
            }
        )
        _ = await manager.loadingTask?.value

        manager.clearAllConversations()
        await manager.flushPendingSaves()

        #expect(fenceProbe.releaseCount == 1)
        #expect(fenceProbe.unbalancedReleaseCount == 0)
        #expect(manager.persistenceErrorMessage != nil)
    }

    @Test
    func `failed clear preserves queued Spotlight deletion tombstone`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Queued Spotlight Deletion")
        try await store.save(conversation)
        let batchGate = PrivacySpotlightQueueGate()
        let deindexProbe = PrivacySpotlightDeindexProbe()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            spotlightBatchIndexOperation: { _, _ in
                await batchGate.run()
            },
            spotlightDeleteOperation: { conversationId in
                await deindexProbe.record(conversationId)
            },
            clearOperation: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        _ = await manager.loadingTask?.value
        await batchGate.waitUntilStarted()
        let loaded = try #require(manager.conversations.first)

        manager.deleteConversation(loaded)
        await manager.flushPendingSaves()
        #expect(try await store.loadConversation(id: conversation.id) == nil)

        manager.clearAllConversations()
        await manager.flushPendingSaves()
        await batchGate.release()

        for _ in 0 ..< 100 where await !(deindexProbe.contains(conversation.id)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await deindexProbe.contains(conversation.id))
    }

    @Test
    func `startup rebuilds Spotlight placeholders after pending cleanup clears the index`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Cleared Before Restart"))
        try store.clear()
        try store.recordAttachmentCleanupSnapshot(
            .empty,
            for: store.pendingPrivacyCleanupMarkerSnapshot()
        )
        let survivingConversation = TestHelpers.sampleConversation(title: "Created After Clear")
        try await store.save(survivingConversation)
        let indexProbe = PrivacySpotlightBatchIndexProbe()

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {},
            attachmentCleanupOperation: {},
            spotlightCleanupOperation: {},
            spotlightBatchIndexOperation: { conversations, shouldResetIndex in
                await indexProbe.record(
                    conversations: conversations,
                    shouldResetIndex: shouldResetIndex
                )
            }
        )
        _ = await manager.loadingTask?.value
        await indexProbe.waitUntilIndexed()

        #expect(await indexProbe.indexedTitles == [survivingConversation.title])
        #expect(await indexProbe.shouldResetIndex)
        #expect(manager.conversations.map(\.id) == [survivingConversation.id])
    }

    @Test
    func `startup rebuilds Spotlight when an earlier cleanup already cleared the index`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Cleared Before Interrupted Cleanup"))
        try store.clear()
        let markerSnapshot = store.pendingPrivacyCleanupMarkerSnapshot()
        try store.recordAttachmentCleanupSnapshot(.empty, for: markerSnapshot)
        try store.markSpotlightCleanupCompleted(for: markerSnapshot)
        let survivingConversation = TestHelpers.sampleConversation(title: "Survived Interrupted Cleanup")
        try await store.save(survivingConversation)
        let cleanupProbe = PrivacyCleanupCountProbe()
        let indexProbe = PrivacySpotlightBatchIndexProbe()

        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            conversationSummaryClearOperation: {},
            attachmentCleanupOperation: {},
            spotlightCleanupOperation: {
                await cleanupProbe.recordSpotlightCleanup()
            },
            spotlightBatchIndexOperation: { conversations, shouldResetIndex in
                await indexProbe.record(
                    conversations: conversations,
                    shouldResetIndex: shouldResetIndex
                )
            }
        )
        _ = await manager.loadingTask?.value
        await indexProbe.waitUntilIndexed()

        #expect(await cleanupProbe.spotlightCleanupCount == 0)
        #expect(await indexProbe.indexedTitles == [survivingConversation.title])
        #expect(await indexProbe.shouldResetIndex)
    }
}

private actor PrivacyFailingDeletionGate {
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

@MainActor
private final class PrivacySummaryMutationProbe {
    private(set) var removedIds: [UUID] = []
    private(set) var updatedTitles: [String] = []

    func remove(_ conversationId: UUID) {
        removedIds.append(conversationId)
    }

    func update(_ conversation: Conversation) {
        updatedTitles.append(conversation.title)
    }
}

private final class PrivacyBlockingClearGate: @unchecked Sendable {
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

private final class PrivacyAttachmentFenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeLeaseCount = 0
    private var beginCalls = 0
    private var releases = 0
    private var unbalancedReleases = 0

    var beginCallCount: Int {
        lock.withLock { beginCalls }
    }

    var releaseCount: Int {
        lock.withLock { releases }
    }

    var unbalancedReleaseCount: Int {
        lock.withLock { unbalancedReleases }
    }

    func begin() -> AttachmentCleanupSnapshot {
        lock.withLock {
            beginCalls += 1
            activeLeaseCount += 1
            return .empty
        }
    }

    func finish() {
        lock.withLock {
            guard activeLeaseCount > 0 else {
                unbalancedReleases += 1
                return
            }
            activeLeaseCount -= 1
            releases += 1
        }
    }
}

private final class PrivacySnapshotThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMainThread: Bool?

    var didRun: Bool {
        lock.withLock { recordedMainThread != nil }
    }

    var ranOnMainThread: Bool {
        lock.withLock { recordedMainThread ?? true }
    }

    func recordCurrentThread() {
        lock.withLock {
            recordedMainThread = Thread.isMainThread
        }
    }
}

private final class PrivacyMarkerScanFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    func enableFailure() {
        lock.withLock { shouldFail = true }
    }

    func contents(of directoryURL: URL) throws -> [URL] {
        let failureEnabled = lock.withLock { shouldFail }
        if failureEnabled {
            throw CocoaError(.fileReadNoPermission)
        }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
    }
}

private final class PrivacyClearInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    var wasInvoked: Bool {
        lock.withLock { invocationCount > 0 }
    }

    func record() {
        lock.withLock {
            invocationCount += 1
        }
    }
}

private actor PrivacySpotlightQueueGate {
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

private actor PrivacySpotlightDeindexProbe {
    private var conversationIds: Set<UUID> = []

    func record(_ conversationId: UUID) {
        conversationIds.insert(conversationId)
    }

    func contains(_ conversationId: UUID) -> Bool {
        conversationIds.contains(conversationId)
    }
}

private actor PrivacySpotlightBatchIndexProbe {
    private(set) var indexedTitles: [String] = []
    private(set) var shouldResetIndex = false
    private var indexingContinuations: [CheckedContinuation<Void, Never>] = []

    func record(conversations: [Conversation], shouldResetIndex: Bool) {
        indexedTitles = conversations.map(\.title)
        self.shouldResetIndex = shouldResetIndex
        for continuation in indexingContinuations {
            continuation.resume()
        }
        indexingContinuations.removeAll()
    }

    func waitUntilIndexed() async {
        guard indexedTitles.isEmpty else { return }
        await withCheckedContinuation { continuation in
            indexingContinuations.append(continuation)
        }
    }
}

private actor PrivacyCleanupCountProbe {
    private(set) var spotlightCleanupCount = 0

    func recordSpotlightCleanup() {
        spotlightCleanupCount += 1
    }
}
