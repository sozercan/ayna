import Combine
import Foundation
import OSLog
import SwiftUI
#if !os(watchOS)
    import CoreSpotlight
#endif
#if !os(watchOS)
    import UniformTypeIdentifiers
#endif

extension Notification.Name {
    static let conversationHistoryClearStarted = Notification.Name("conversationHistoryClearStarted")
    static let conversationHistoryClearCommitted = Notification.Name("conversationHistoryClearCommitted")
    static let conversationHistoryClearRolledBack = Notification.Name("conversationHistoryClearRolledBack")
    static let conversationDeleteRolledBack = Notification.Name("conversationDeleteRolledBack")
}

final class CleanupResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    var succeeded: Bool {
        lock.withLock { !failed }
    }

    func markFailed() {
        lock.withLock {
            failed = true
        }
    }
}

struct AttachmentCleanupFencePreparation: Sendable {
    let isActive: Bool
    let errorDescription: String?
}

@MainActor
final class ConversationManager: ObservableObject {
    static let searchIndexWarmupLimit = 16

    actor ImmediateSaveOutcome {
        private var wasDurablySaved = false

        func markDurablySaved() {
            wasDurablySaved = true
        }

        func value() -> Bool {
            wasDurablySaved
        }
    }

    private struct SummaryOperations {
        let invalidate: @MainActor @Sendable () -> ConversationSummaryClearSnapshot
        let restore: @MainActor @Sendable (ConversationSummaryClearSnapshot) async throws -> Void
        let clear: @MainActor @Sendable (String) async throws -> Void
        let remove: @MainActor @Sendable (UUID) -> Void
        let update: @MainActor @Sendable (Conversation) -> Void
    }

    private struct AttachmentCleanupOperations {
        let fenceBegin: @Sendable () throws -> Void
        let snapshot: @Sendable () async throws -> AttachmentCleanupSnapshot
        let cleanup: @Sendable (AttachmentCleanupSnapshot) async throws -> Void
        let release: @Sendable () -> Void
    }

    private struct SpotlightOperations {
        let cleanup: @Sendable () async throws -> Void
        let batchIndex: @Sendable ([Conversation], Bool) async throws -> Void
        let delete: @Sendable (UUID) async throws -> Void
    }

    @Published var conversations: [Conversation] = []
    @Published var persistenceErrorMessage: String?
    @Published var selectedConversationId: UUID? {
        didSet {
            selectionRevision &+= 1
            guard selectedConversationId != oldValue else { return }
            if let selectedConversationId {
                scheduleFullConversationLoadIfNeeded(selectedConversationId)
            }
        }
    }

    @Published var pendingDestructivePersistenceOperations = 0
    @Published var isConversationStateAuthoritative = false
    @Published var durableConversationRevision: UInt64 = 0
    @Published var pendingSendConversationIds: [UUID] = []

    static let newConversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let store: any ConversationStoreAdapter
    let encryptedStore: EncryptedConversationStore?
    let conversationLoader: @Sendable (UUID) async throws -> Conversation?
    let conversationMetadataLoader: @Sendable () async throws -> [ConversationMetadata]
    let usesMetadataLoading: Bool
    let persistenceCoordinator: ConversationPersistenceCoordinator
    var loadingTask: Task<Void, Never>?
    var isLoaded = false
    let saveDebounceDuration: Duration
    let loadRetryBaseDelay: Duration
    let destructiveRepairRetryBaseDelay: Duration
    var loadRetryTask: Task<Void, Never>?
    var destructiveRepairTasks: [ConversationSnapshotRepairToken: Task<Void, Never>] = [:]
    var loadRetryAttempt = 0
    var selectionRevision: UInt64 = 0

    var conversationIndexCache: [UUID: Int] = [:]

    var metadataOnlyConversationIds: Set<UUID> = []
    var metadataSearchTextById: [UUID: String] = [:]
    var durableDiskBaseline: [UUID: (conversation: Conversation, isMetadataOnly: Bool)] = [:]
    var generatingConversationIds: Set<UUID> = []
    var fullConversationLoadTasks: [UUID: Task<Conversation?, Never>] = [:]
    var fullConversationLoadTaskVersions: [UUID: UInt64] = [:]
    var nextFullConversationLoadTaskVersion: UInt64 = 0
    var persistenceSequenceById: [UUID: UInt64] = [:]
    var persistenceTasksById: [UUID: Task<Void, Never>] = [:]
    var persistenceRecreationAuthorizationIds: Set<UUID> = []
    var suppressedPersistenceIds: Set<UUID> = []
    var persistenceImmediateSaveIds: Set<UUID> = []
    var failedSaveIdsAwaitingFlushObservation: Set<UUID> = []
    var nextPersistenceSequence: UInt64 = 0
    var managerDeletionTasks: [UUID: Task<Void, Never>] = [:]
    var managerDeletionTaskVersions: [UUID: UInt64] = [:]
    var latestManagerDeletionVersionById: [UUID: UInt64] = [:]
    var latestManagerRecreationVersionById: [UUID: UInt64] = [:]
    var nextManagerDeletionTaskVersion: UInt64 = 0
    var nextReconciliationMutationVersion: UInt64 = 0
    var clearConversationsTask: Task<Void, Never>?
    var clearConversationsGeneration: UInt64 = 0
    var clearRollbackConversationsById: [UUID: Conversation] = [:]
    var clearRollbackConversationGenerationById: [UUID: UInt64] = [:]
    var clearRollbackMetadataOnlyIds: Set<UUID> = []
    var clearRollbackMetadataOnlyGenerationById: [UUID: UInt64] = [:]
    var clearRollbackMetadataSearchTextById: [UUID: String] = [:]
    var clearRollbackMetadataSearchTextGenerationById: [UUID: UInt64] = [:]
    var clearRollbackSummarySnapshotsByGeneration: [UInt64: ConversationSummaryClearSnapshot] = [:]
    var clearFailureNeedsReload = false
    var titleRequestGenerationByConversationId: [UUID: UInt64] = [:]
    var conversationLoadGeneration: UInt64 = 0
    var searchIndexWarmupTask: Task<Void, Never>?
    var searchIndexWarmupVersion: UInt64 = 0
    let searchIndexWarmupDelay: Duration
    let searchIndexWarmupEnabled: Bool
    let beforePersistenceFlush: (@Sendable () async -> Void)?
    let conversationSummaryInvalidateOperation: @MainActor @Sendable () -> ConversationSummaryClearSnapshot
    let conversationSummaryRestoreOperation: @MainActor @Sendable (ConversationSummaryClearSnapshot) async throws -> Void
    let conversationSummaryClearOperation: @MainActor @Sendable (String) async throws -> Void
    let conversationSummaryRemoveOperation: @MainActor @Sendable (UUID) -> Void
    let conversationSummaryUpdateOperation: @MainActor @Sendable (Conversation) -> Void
    let attachmentCleanupFenceBeginOperation: @Sendable () throws -> Void
    let attachmentCleanupSnapshotOperation: @Sendable () async throws -> AttachmentCleanupSnapshot
    let attachmentCleanupOperation: @Sendable (AttachmentCleanupSnapshot) async throws -> Void
    let attachmentCleanupReleaseOperation: @Sendable () -> Void
    let spotlightCleanupOperation: @Sendable () async throws -> Void
    let spotlightBatchIndexOperation: @Sendable ([Conversation], Bool) async throws -> Void
    let spotlightDeleteOperation: @Sendable (UUID) async throws -> Void
    let attachmentDeleteOperation: @MainActor @Sendable ([String]) -> Void
    var metadataAttachmentPathsById: [UUID: [String]] = [:]
    let spotlightIndexingEnabled: Bool
    var indexingDebounceTasks: [UUID: Task<Void, Never>] = [:]
    let indexingDebounceDuration: Duration = .seconds(3)
    var spotlightIndexGeneration: UInt64 = 0
    let spotlightOperationQueue = OrderedAsyncOperationQueue()

    init(
        store: (any ConversationStoreAdapter)? = nil,
        saveDebounceDuration: Duration = .milliseconds(200),
        conversationLoader: (@Sendable (UUID) async throws -> Conversation?)? = nil,
        conversationMetadataLoader: (@Sendable () async throws -> [ConversationMetadata])? = nil,
        searchIndexWarmupDelay: Duration = .seconds(1),
        searchIndexWarmupEnabled: Bool = true,
        spotlightIndexingEnabled: Bool? = nil,
        startsLoadingImmediately: Bool = true,
        beforePersistenceFlush: (@Sendable () async -> Void)? = nil,
        conversationSummaryInvalidateOperation: (@MainActor @Sendable () -> ConversationSummaryClearSnapshot)? = nil,
        conversationSummaryRestoreOperation: (@MainActor @Sendable (ConversationSummaryClearSnapshot) async throws -> Void)? = nil,
        conversationSummaryClearOperation: (@MainActor @Sendable () async throws -> Void)? = nil,
        conversationSummaryRemoveOperation: (@MainActor @Sendable (UUID) -> Void)? = nil,
        conversationSummaryUpdateOperation: (@MainActor @Sendable (Conversation) -> Void)? = nil,
        attachmentCleanupFenceBeginOperation: (@Sendable () throws -> Void)? = nil,
        attachmentCleanupSnapshotOperation: (@Sendable () throws -> AttachmentCleanupSnapshot)? = nil,
        attachmentCleanupOperation: (@Sendable () async throws -> Void)? = nil,
        attachmentCleanupReleaseOperation: (@Sendable () -> Void)? = nil,
        spotlightCleanupOperation: (@Sendable () async throws -> Void)? = nil,
        spotlightBatchIndexOperation: (@Sendable ([Conversation], Bool) async throws -> Void)? = nil,
        spotlightDeleteOperation: (@Sendable (UUID) async throws -> Void)? = nil,
        attachmentDeleteOperation: (@MainActor @Sendable ([String]) -> Void)? = nil,
        saveOperation: (@Sendable (Conversation) async throws -> Void)? = nil,
        deleteOperation: (@Sendable (UUID) async throws -> Void)? = nil,
        clearOperation: (@Sendable () throws -> Void)? = nil,
        loadRetryBaseDelay: Duration = .seconds(2),
        destructiveRepairRetryBaseDelay: Duration = .seconds(2)
    ) {
        let effectiveStore = store ?? EncryptedConversationStore.shared
        self.store = effectiveStore
        let encryptedStore = effectiveStore as? EncryptedConversationStore
        self.encryptedStore = encryptedStore
        usesMetadataLoading = encryptedStore != nil
            || conversationLoader != nil
            || conversationMetadataLoader != nil
        self.conversationLoader = conversationLoader ?? { conversationId in
            if let encryptedStore {
                return try await encryptedStore.loadConversation(id: conversationId)
            }
            return try await effectiveStore.loadConversations().first { $0.id == conversationId }
        }
        self.conversationMetadataLoader = conversationMetadataLoader ?? {
            if let encryptedStore {
                return try await encryptedStore.loadConversationMetadata()
            }
            return try await effectiveStore.loadConversations().map(ConversationMetadata.init(conversation:))
        }
        self.saveDebounceDuration = saveDebounceDuration
        self.loadRetryBaseDelay = loadRetryBaseDelay
        self.destructiveRepairRetryBaseDelay = destructiveRepairRetryBaseDelay
        self.searchIndexWarmupDelay = searchIndexWarmupDelay
        self.searchIndexWarmupEnabled = searchIndexWarmupEnabled
        self.beforePersistenceFlush = beforePersistenceFlush

        let summaryOps = Self.resolvedSummaryOperations(
            invalidate: conversationSummaryInvalidateOperation,
            restore: conversationSummaryRestoreOperation,
            clear: conversationSummaryClearOperation,
            remove: conversationSummaryRemoveOperation,
            update: conversationSummaryUpdateOperation
        )
        self.conversationSummaryInvalidateOperation = summaryOps.invalidate
        self.conversationSummaryRestoreOperation = summaryOps.restore
        self.conversationSummaryClearOperation = summaryOps.clear
        self.conversationSummaryRemoveOperation = summaryOps.remove
        self.conversationSummaryUpdateOperation = summaryOps.update

        let attachmentOps = Self.resolvedAttachmentCleanupOperations(
            fenceBegin: attachmentCleanupFenceBeginOperation,
            snapshot: attachmentCleanupSnapshotOperation,
            cleanup: attachmentCleanupOperation,
            release: attachmentCleanupReleaseOperation
        )
        self.attachmentCleanupFenceBeginOperation = attachmentOps.fenceBegin
        self.attachmentCleanupSnapshotOperation = attachmentOps.snapshot
        self.attachmentCleanupOperation = attachmentOps.cleanup
        self.attachmentCleanupReleaseOperation = attachmentOps.release

        self.spotlightIndexingEnabled = spotlightIndexingEnabled
            ?? (!RuntimeEnvironment.isRunningUnitTests
                || spotlightBatchIndexOperation != nil
                || spotlightDeleteOperation != nil)
        let spotlightOps = Self.resolvedSpotlightOperations(
            cleanup: spotlightCleanupOperation,
            batchIndex: spotlightBatchIndexOperation,
            delete: spotlightDeleteOperation
        )
        self.spotlightCleanupOperation = spotlightOps.cleanup
        self.spotlightBatchIndexOperation = spotlightOps.batchIndex
        self.spotlightDeleteOperation = spotlightOps.delete

        self.attachmentDeleteOperation = Self.resolvedAttachmentDeleteOperation(attachmentDeleteOperation)
        persistenceCoordinator = ConversationPersistenceCoordinator(
            store: effectiveStore,
            debounceDuration: saveDebounceDuration,
            saveOperation: saveOperation,
            deleteOperation: deleteOperation,
            clearOperation: clearOperation
        )
        persistenceCoordinator.observeDurableSnapshotChanges { [weak self] in
            self?.durableConversationRevision &+= 1
        }
        persistenceCoordinator.observeDurableSaves { [weak self] conversation in
            self?.conversationDidPersist(conversation)
        }
        if startsLoadingImmediately {
            loadingTask = Task {
                await loadConversations()
            }
        } else {
            isLoaded = true
            isConversationStateAuthoritative = true
        }
    }

    private static func resolvedSummaryOperations(
        invalidate: (@MainActor @Sendable () -> ConversationSummaryClearSnapshot)?,
        restore: (@MainActor @Sendable (ConversationSummaryClearSnapshot) async throws -> Void)?,
        clear: (@MainActor @Sendable () async throws -> Void)?,
        remove: (@MainActor @Sendable (UUID) -> Void)?,
        update: (@MainActor @Sendable (Conversation) -> Void)?
    ) -> SummaryOperations {
        let isTesting = RuntimeEnvironment.isRunningUnitTests
        let resolvedInvalidate: @MainActor @Sendable () -> ConversationSummaryClearSnapshot = if let invalidate {
            invalidate
        } else if isTesting {
            {
                ConversationSummaryClearSnapshot(
                    digest: RecentConversationsDigest(),
                    wasLoaded: false
                )
            }
        } else {
            { MemoryContextProvider.shared.invalidateConversationSummariesForClear() }
        }

        let resolvedRestore: @MainActor @Sendable (ConversationSummaryClearSnapshot) async throws -> Void = if let restore {
            restore
        } else if isTesting {
            { _ in }
        } else {
            { snapshot in
                try await MemoryContextProvider.shared.restoreConversationSummariesAfterFailedClear(snapshot)
            }
        }

        let resolvedClear: @MainActor @Sendable (String) async throws -> Void = if let clear {
            { _ in try await clear() }
        } else if isTesting {
            { _ in }
        } else {
            { cleanupToken in
                try await MemoryContextProvider.shared.clearAllConversationSummaries(
                    cleanupToken: cleanupToken
                )
            }
        }

        let resolvedRemove: @MainActor @Sendable (UUID) -> Void = if let remove {
            remove
        } else if isTesting {
            { _ in }
        } else {
            { conversationId in
                MemoryContextProvider.shared.removeConversationSummary(for: conversationId)
            }
        }

        let resolvedUpdate: @MainActor @Sendable (Conversation) -> Void = if let update {
            update
        } else if isTesting {
            { _ in }
        } else {
            { conversation in
                MemoryContextProvider.shared.updateConversationSummary(conversation)
            }
        }

        return SummaryOperations(
            invalidate: resolvedInvalidate,
            restore: resolvedRestore,
            clear: resolvedClear,
            remove: resolvedRemove,
            update: resolvedUpdate
        )
    }

    private static func resolvedAttachmentCleanupOperations(
        fenceBegin: (@Sendable () throws -> Void)?,
        snapshot: (@Sendable () throws -> AttachmentCleanupSnapshot)?,
        cleanup: (@Sendable () async throws -> Void)?,
        release: (@Sendable () -> Void)?
    ) -> AttachmentCleanupOperations {
        let isTesting = RuntimeEnvironment.isRunningUnitTests
        let resolvedFenceBegin: @Sendable () throws -> Void = if let fenceBegin {
            fenceBegin
        } else if isTesting || snapshot != nil {
            {}
        } else {
            { AttachmentStorage.shared.beginCleanup() }
        }

        let resolvedSnapshot: @Sendable () async throws -> AttachmentCleanupSnapshot = if let snapshot {
            {
                try await Task.detached(priority: .utility) {
                    try snapshot()
                }.value
            }
        } else if isTesting {
            { .empty }
        } else {
            {
                try await Task.detached(priority: .utility) {
                    try AttachmentStorage.shared.cleanupSnapshot()
                }.value
            }
        }

        let resolvedCleanup: @Sendable (AttachmentCleanupSnapshot) async throws -> Void = if let cleanup {
            { _ in try await cleanup() }
        } else if isTesting {
            { _ in }
        } else {
            { cleanupSnapshot in
                try await Task.detached(priority: .utility) {
                    try AttachmentStorage.shared.clear(cleanupSnapshot)
                }.value
            }
        }

        let resolvedRelease: @Sendable () -> Void = if let release {
            release
        } else if isTesting || fenceBegin != nil || snapshot != nil {
            {}
        } else {
            { AttachmentStorage.shared.finishCleanup() }
        }

        return AttachmentCleanupOperations(
            fenceBegin: resolvedFenceBegin,
            snapshot: resolvedSnapshot,
            cleanup: resolvedCleanup,
            release: resolvedRelease
        )
    }

    private static func resolvedSpotlightOperations(
        cleanup: (@Sendable () async throws -> Void)?,
        batchIndex: (@Sendable ([Conversation], Bool) async throws -> Void)?,
        delete: (@Sendable (UUID) async throws -> Void)?
    ) -> SpotlightOperations {
        #if !os(watchOS)
            let resolvedCleanup: @Sendable () async throws -> Void = if let cleanup {
                cleanup
            } else if RuntimeEnvironment.isRunningUnitTests {
                {}
            } else {
                {
                    try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [
                        "co.ayna.conversations", "com.sertacozercan.ayna.conversation",
                    ])
                }
            }
            let resolvedBatchIndex: @Sendable ([Conversation], Bool) async throws -> Void = batchIndex ?? { conversations, shouldResetIndex in
                if shouldResetIndex {
                    try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [
                        "co.ayna.conversations", "com.sertacozercan.ayna.conversation",
                    ])
                }
                guard !conversations.isEmpty else { return }
                let items = conversations.map { ConversationManager.createSearchableItem(for: $0) }
                try await CSSearchableIndex.default().indexSearchableItems(items)
            }
            let resolvedDelete: @Sendable (UUID) async throws -> Void = delete ?? { conversationId in
                try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [conversationId.uuidString])
            }
            return SpotlightOperations(
                cleanup: resolvedCleanup,
                batchIndex: resolvedBatchIndex,
                delete: resolvedDelete
            )
        #else
            return SpotlightOperations(
                cleanup: cleanup ?? {},
                batchIndex: batchIndex ?? { _, _ in },
                delete: delete ?? { _ in }
            )
        #endif
    }

    static func resolvedAttachmentDeleteOperation(
        _ injected: (@MainActor @Sendable ([String]) -> Void)?
    ) -> @MainActor @Sendable ([String]) -> Void {
        if let injected {
            return injected
        }
        if RuntimeEnvironment.isRunningUnitTests {
            return { _ in }
        }
        return { paths in
            for path in paths {
                AttachmentStorage.shared.delete(path: path)
            }
        }
    }

    func logManager(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.conversationManager, level: level, message: message, metadata: metadata)
    }

    func rebuildIndexCache() {
        conversationIndexCache.removeAll(keepingCapacity: true)
        for (index, conversation) in conversations.enumerated() {
            conversationIndexCache[conversation.id] = index
        }
    }

    func getConversationIndex(for id: UUID) -> Int? {
        if let cachedIndex = conversationIndexCache[id] {
            if cachedIndex < conversations.count, conversations[cachedIndex].id == id {
                return cachedIndex
            }
            rebuildIndexCache()
            return conversationIndexCache[id]
        }

        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversationIndexCache[id] = index
            return index
        }

        return nil
    }

    func updateCacheForInsertion(at index: Int) {
        for idx in index ..< conversations.count {
            conversationIndexCache[conversations[idx].id] = idx
        }
    }

    func updateCacheForRemoval(id: UUID, at index: Int) {
        conversationIndexCache.removeValue(forKey: id)
        for idx in index ..< conversations.count {
            conversationIndexCache[conversations[idx].id] = idx
        }
    }

    func conversationSnapshot(byId conversationId: UUID) -> Conversation? {
        guard let index = getConversationIndex(for: conversationId) else { return nil }
        return conversations[index]
    }

    func modifyConversation(at index: Int, _ body: (inout Conversation) -> Void) {
        body(&conversations[index])
    }

    func nextReconciliationVersion() -> UInt64 {
        nextReconciliationMutationVersion &+= 1
        return nextReconciliationMutationVersion
    }

    func isMetadataBackedSnapshot(_ conversation: Conversation) -> Bool {
        metadataOnlyConversationIds.contains(conversation.id) || conversation.metadataPreview != nil
    }

    func resolvingInterruptedImageGeneration(in conversation: Conversation) -> Conversation {
        var restored = conversation
        var interruptedMessageIDs: Set<UUID> = []
        for index in restored.messages.indices {
            let message = restored.messages[index]
            guard message.role == .assistant,
                  message.mediaType == .image,
                  message.imageData == nil,
                  message.imagePath == nil,
                  message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            interruptedMessageIDs.insert(message.id)
            restored.messages[index].content = "Image generation stopped"
        }
        guard !interruptedMessageIDs.isEmpty else { return restored }

        for groupIndex in restored.responseGroups.indices {
            for responseIndex in restored.responseGroups[groupIndex].responses.indices
                where interruptedMessageIDs.contains(
                    restored.responseGroups[groupIndex].responses[responseIndex].id
                ) && restored.responseGroups[groupIndex].responses[responseIndex].status == .streaming
            {
                restored.responseGroups[groupIndex].responses[responseIndex].status = .failed
            }
        }
        return restored
    }

    func dismissPersistenceError() {
        persistenceErrorMessage = nil
    }

    func recordPersistenceError(_ message: String) {
        guard let existingMessage = persistenceErrorMessage, !existingMessage.isEmpty else {
            persistenceErrorMessage = message
            return
        }
        guard !existingMessage.contains(message) else { return }
        persistenceErrorMessage = "\(existingMessage) \(message)"
    }
}
