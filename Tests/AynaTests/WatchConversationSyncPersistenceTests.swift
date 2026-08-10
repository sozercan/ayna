@testable import Ayna
import Foundation
import Testing

@Suite("Watch Conversation Sync Persistence Tests", .tags(.persistence))
struct WatchConversationSyncPersistenceTests {
    @Test
    func `clear generation and pending fence survive atomically and commit once`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("sync-state.json")
        let epoch = UUID()
        let transaction = WatchConversationClearTransaction(
            baselinePrivacyMarkerToken: "baseline"
        )
        let initialState = WatchConversationSyncState(
            identity: WatchConversationSyncIdentity(epoch: epoch, generation: 7)
        )

        let firstStore = WatchConversationSyncStateStore(fileURL: fileURL)
        _ = try firstStore.load(orCreating: initialState)
        _ = try firstStore.update(initialState: initialState) { state in
            state.beginClear(transaction)
        }

        let afterRestart = try #require(
            try WatchConversationSyncStateStore(fileURL: fileURL).load()
        )
        #expect(afterRestart.identity.generation == 7)
        #expect(afterRestart.pendingClears == [transaction])

        let restartedStore = WatchConversationSyncStateStore(fileURL: fileURL)
        let committed = try restartedStore.update(initialState: initialState) { state in
            state.commitClear(id: transaction.id)
        }
        #expect(committed.identity.generation == 8)
        #expect(committed.pendingClears.isEmpty)

        let duplicateCommit = try restartedStore.update(initialState: initialState) { state in
            state.commitClear(id: transaction.id)
        }
        #expect(duplicateCommit.identity.generation == 8)
        #expect(duplicateCommit.pendingClears.isEmpty)
    }

    @Test
    func `rolled-back clear removes only its own fence without advancing generation`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("sync-state.json")
        let first = WatchConversationClearTransaction(baselinePrivacyMarkerToken: "first")
        let second = WatchConversationClearTransaction(baselinePrivacyMarkerToken: "second")
        let initialState = WatchConversationSyncState(
            identity: WatchConversationSyncIdentity(epoch: UUID(), generation: 4),
            pendingClears: [first, second]
        )
        let store = WatchConversationSyncStateStore(fileURL: fileURL)
        _ = try store.load(orCreating: initialState)

        let rolledBack = try store.update(initialState: initialState) { state in
            state.rollBackClear(id: first.id)
        }

        #expect(rolledBack.identity.generation == 4)
        #expect(rolledBack.pendingClears == [second])
    }

    @Test
    func `mutation inbox encrypts payload and survives restart`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("mutation-inbox.json")
        let keychain = InMemoryKeychainStorage()
        let keyIdentifier = UUID().uuidString
        let secret = "watch-inbox-secret-\(UUID().uuidString)"
        let message = WatchMessage(from: Message(role: .user, content: secret))
        let mutation = WatchConversationMutation(
            syncEpoch: UUID(),
            clearGeneration: 3,
            payload: .newMessage(message: message, conversationId: UUID())
        )

        let firstInbox = WatchConversationMutationInbox(
            fileURL: fileURL,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        try firstInbox.enqueue(mutation)
        try firstInbox.enqueue(mutation)
        let encryptedData = try Data(contentsOf: fileURL)
        #expect(encryptedData.range(of: Data(secret.utf8)) == nil)

        let restartedInbox = WatchConversationMutationInbox(
            fileURL: fileURL,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        #expect(try restartedInbox.load() == [mutation])

        try restartedInbox.remove(id: mutation.id)
        try restartedInbox.remove(id: mutation.id)
        #expect(
            try WatchConversationMutationInbox(
                fileURL: fileURL,
                keyIdentifier: keyIdentifier,
                keychain: keychain
            ).load().isEmpty
        )
    }

    @Test
    @MainActor
    func `failed Watch mutation save stays queued until durable retry succeeds`() async throws {
        let storeDirectory = try TestHelpers.makeTemporaryDirectory()
        let inboxDirectory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: storeDirectory)
        let saveProbe = FailFirstWatchMutationSaveProbe(store: store)
        let manager = ConversationManager(
            store: store,
            spotlightIndexingEnabled: false,
            startsLoadingImmediately: false,
            saveOperation: { conversation in
                try await saveProbe.save(conversation)
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Retryable Watch Mutation")
        manager.conversations = [conversation]

        let mutation = WatchConversationMutation(
            syncEpoch: UUID(),
            clearGeneration: 2,
            payload: .newConversation(WatchConversation(from: conversation))
        )
        let inbox = WatchConversationMutationInbox(
            fileURL: inboxDirectory.appendingPathComponent("mutation-inbox.enc"),
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        try inbox.enqueue(mutation)

        let firstSaveWasDurable = await manager
            .saveImmediatelyReportingDurability(conversation).value
        if firstSaveWasDurable {
            try inbox.remove(id: mutation.id)
        }

        #expect(!firstSaveWasDurable)
        #expect(try inbox.load() == [mutation])
        #expect(try await store.loadConversation(id: conversation.id) == nil)

        let retryWasDurable = await manager
            .saveImmediatelyReportingDurability(conversation).value
        if retryWasDurable {
            try inbox.remove(id: mutation.id)
        }

        #expect(retryWasDurable)
        #expect(try inbox.load().isEmpty)
        #expect(try await store.loadConversation(id: conversation.id)?.title == conversation.title)
        #expect(await saveProbe.attemptCount == 2)
    }

    @Test
    func `clear outcome journal survives restart until Watch acknowledges it`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("clear-journal.json")
        let transaction = WatchConversationClearTransaction(
            baselinePrivacyMarkerToken: "baseline"
        )

        let firstJournal = WatchConversationClearJournalStore(fileURL: fileURL)
        try firstJournal.recordPending(transaction)
        #expect(
            try WatchConversationClearJournalStore(fileURL: fileURL)
                .outcome(for: transaction.id) == .pending
        )

        try firstJournal.recordOutcome(.committed, for: transaction.id)
        let restartedJournal = WatchConversationClearJournalStore(fileURL: fileURL)
        #expect(try restartedJournal.outcome(for: transaction.id) == .committed)

        try restartedJournal.remove(transactionId: transaction.id)
        #expect(try restartedJournal.outcome(for: transaction.id) == nil)
    }

    @Test
    @MainActor
    func `interrupted clear recovery ignores an unchanged historical privacy marker`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let journalDirectory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try store.clear()
        let historicalMarkers = try store.pendingPrivacyCleanupMarkerSnapshotThrowing()
        let transaction = WatchConversationClearTransaction(
            baselinePrivacyMarkerToken: historicalMarkers.summaryCleanupToken
        )
        let journal = WatchConversationClearJournalStore(
            fileURL: journalDirectory.appendingPathComponent("clear-journal.json")
        )
        let manager = ConversationManager(
            store: store,
            spotlightIndexingEnabled: false,
            startsLoadingImmediately: false,
            watchConversationClearJournalStore: journal
        )

        #expect(try !manager.interruptedConversationClearWasCommitted(transaction))
    }

    @Test
    @MainActor
    func `committed clear journal remains authoritative after privacy marker cleanup`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let journalDirectory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let baseline = try store.pendingPrivacyCleanupMarkerSnapshotThrowing()
        let transaction = WatchConversationClearTransaction(
            baselinePrivacyMarkerToken: baseline.summaryCleanupToken
        )
        let journal = WatchConversationClearJournalStore(
            fileURL: journalDirectory.appendingPathComponent("clear-journal.json")
        )
        try journal.recordPending(transaction)
        try store.clear()
        let committedMarkers = try store.pendingPrivacyCleanupMarkerSnapshotThrowing()
        try journal.recordOutcome(.committed, for: transaction.id)
        try store.clearPendingPrivacyCleanup(committedMarkers)

        let manager = ConversationManager(
            store: store,
            spotlightIndexingEnabled: false,
            startsLoadingImmediately: false,
            watchConversationClearJournalStore: journal
        )

        #expect(try manager.interruptedConversationClearWasCommitted(transaction))
        manager.acknowledgeWatchConversationClear(transaction)
        #expect(try journal.outcome(for: transaction.id) == nil)
    }
}

private actor FailFirstWatchMutationSaveProbe {
    private enum ExpectedFailure: Error {
        case firstAttempt
    }

    private let store: EncryptedConversationStore
    private(set) var attemptCount = 0

    init(store: EncryptedConversationStore) {
        self.store = store
    }

    func save(_ conversation: Conversation) async throws {
        attemptCount += 1
        if attemptCount == 1 {
            throw ExpectedFailure.firstAttempt
        }
        try await store.save(conversation)
    }
}
