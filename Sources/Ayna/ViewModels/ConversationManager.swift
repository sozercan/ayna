//
//  ConversationManager.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
#if !os(watchOS)
    import CoreSpotlight
#endif
import Foundation
import OSLog
import SwiftUI
#if !os(watchOS)
    import UniformTypeIdentifiers
#endif

extension Notification.Name {
    static let conversationHistoryClearStarted = Notification.Name("conversationHistoryClearStarted")
    static let conversationHistoryClearCommitted = Notification.Name("conversationHistoryClearCommitted")
    static let conversationHistoryClearRolledBack = Notification.Name("conversationHistoryClearRolledBack")
}

private final class CleanupResultBox: @unchecked Sendable {
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

private struct AttachmentCleanupFencePreparation: Sendable {
    let isActive: Bool
    let errorDescription: String?
}

private struct AttachmentCleanupPreparation: Sendable {
    let snapshot: AttachmentCleanupSnapshot?
    let errorDescription: String?
    let fenceIsActive: Bool
}

@MainActor
final class ConversationManager: ObservableObject {
    private static let searchIndexWarmupLimit = 16

    @Published var conversations: [Conversation] = []
    @Published private(set) var persistenceErrorMessage: String?
    @Published var selectedConversationId: UUID? {
        didSet {
            guard selectedConversationId != oldValue, let selectedConversationId else { return }
            scheduleFullConversationLoadIfNeeded(selectedConversationId)
        }
    }

    static let newConversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let store: EncryptedConversationStore
    private let conversationLoader: @Sendable (UUID) async throws -> Conversation?
    private let conversationMetadataLoader: @Sendable () async throws -> [ConversationMetadata]
    private let persistenceCoordinator: ConversationPersistenceCoordinator
    var loadingTask: Task<Void, Never>?
    private var isLoaded = false
    private let saveDebounceDuration: Duration

    // Performance: O(1) conversation index lookup cache
    private var conversationIndexCache: [UUID: Int] = [:]

    // Conversations represented by lightweight metadata only until selected/opened.
    private var metadataOnlyConversationIds: Set<UUID> = []
    private var metadataSearchTextById: [UUID: String] = [:]
    private var fullConversationLoadTasks: [UUID: Task<Conversation?, Never>] = [:]
    private var fullConversationLoadTaskVersions: [UUID: UInt64] = [:]
    private var nextFullConversationLoadTaskVersion: UInt64 = 0
    private var persistenceSequenceById: [UUID: UInt64] = [:]
    private var persistenceTasksById: [UUID: Task<Void, Never>] = [:]
    private var persistenceRecreationAuthorizationIds: Set<UUID> = []
    private var persistenceImmediateSaveIds: Set<UUID> = []
    private var nextPersistenceSequence: UInt64 = 0
    private var managerDeletionTasks: [UUID: Task<Void, Never>] = [:]
    private var managerDeletionTaskVersions: [UUID: UInt64] = [:]
    private var latestManagerDeletionVersionById: [UUID: UInt64] = [:]
    private var latestManagerRecreationVersionById: [UUID: UInt64] = [:]
    private var nextManagerDeletionTaskVersion: UInt64 = 0
    private var nextReconciliationMutationVersion: UInt64 = 0
    private var clearConversationsTask: Task<Void, Never>?
    private var clearConversationsGeneration: UInt64 = 0
    private var clearRollbackConversationsById: [UUID: Conversation] = [:]
    private var clearRollbackConversationGenerationById: [UUID: UInt64] = [:]
    private var clearRollbackMetadataOnlyIds: Set<UUID> = []
    private var clearRollbackMetadataOnlyGenerationById: [UUID: UInt64] = [:]
    private var clearRollbackMetadataSearchTextById: [UUID: String] = [:]
    private var clearRollbackMetadataSearchTextGenerationById: [UUID: UInt64] = [:]
    private var clearRollbackSummarySnapshotsByGeneration: [UInt64: ConversationSummaryClearSnapshot] = [:]
    private var clearFailureNeedsReload = false
    private var titleRequestGenerationByConversationId: [UUID: UInt64] = [:]
    private var conversationLoadGeneration: UInt64 = 0
    private var searchIndexWarmupTask: Task<Void, Never>?
    private var searchIndexWarmupVersion: UInt64 = 0
    private let searchIndexWarmupDelay: Duration
    private let searchIndexWarmupEnabled: Bool
    private let beforePersistenceFlush: (@Sendable () async -> Void)?
    private let conversationSummaryInvalidateOperation: @MainActor @Sendable () -> ConversationSummaryClearSnapshot
    private let conversationSummaryRestoreOperation: @MainActor @Sendable (ConversationSummaryClearSnapshot) async throws -> Void
    private let conversationSummaryClearOperation: @MainActor @Sendable (String) async throws -> Void
    private let conversationSummaryRemoveOperation: @MainActor @Sendable (UUID) -> Void
    private let conversationSummaryUpdateOperation: @MainActor @Sendable (Conversation) -> Void
    private let attachmentCleanupFenceBeginOperation: @Sendable () throws -> Void
    private let attachmentCleanupSnapshotOperation: @Sendable () async throws -> AttachmentCleanupSnapshot
    private let attachmentCleanupOperation: @Sendable (AttachmentCleanupSnapshot) async throws -> Void
    private let attachmentCleanupReleaseOperation: @Sendable () -> Void
    private let spotlightCleanupOperation: @Sendable () async throws -> Void
    private let spotlightBatchIndexOperation: @Sendable ([Conversation], Bool) async throws -> Void
    private let spotlightDeleteOperation: @Sendable (UUID) async throws -> Void
    private let spotlightIndexingEnabled: Bool

    // Performance: Spotlight indexing debounce (3 seconds per conversation)
    private var indexingDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private let indexingDebounceDuration: Duration = .seconds(3)
    private var spotlightIndexGeneration: UInt64 = 0
    private let spotlightOperationQueue = OrderedAsyncOperationQueue()

    private func logManager(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.conversationManager, level: level, message: message, metadata: metadata)
    }

    // MARK: - Index Cache Management

    /// Rebuilds the entire conversation index cache. Call after bulk operations.
    private func rebuildIndexCache() {
        conversationIndexCache.removeAll(keepingCapacity: true)
        for (index, conversation) in conversations.enumerated() {
            conversationIndexCache[conversation.id] = index
        }
    }

    /// Gets the index for a conversation ID using O(1) cache lookup.
    /// Falls back to O(n) search if not in cache.
    private func getConversationIndex(for id: UUID) -> Int? {
        if let cachedIndex = conversationIndexCache[id] {
            // Verify cache is still valid
            if cachedIndex < conversations.count, conversations[cachedIndex].id == id {
                return cachedIndex
            }
            // Cache is stale, rebuild
            rebuildIndexCache()
            return conversationIndexCache[id]
        }

        // Not in cache, do linear search and cache result
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversationIndexCache[id] = index
            return index
        }

        return nil
    }

    /// Updates the cache when a conversation is inserted at a specific index.
    private func updateCacheForInsertion(at index: Int) {
        // Update all indices >= insertion point
        for idx in index ..< conversations.count {
            conversationIndexCache[conversations[idx].id] = idx
        }
    }

    /// Updates the cache when a conversation is removed.
    private func updateCacheForRemoval(id: UUID, at index: Int) {
        conversationIndexCache.removeValue(forKey: id)
        // Update all indices > removal point
        for idx in index ..< conversations.count {
            conversationIndexCache[conversations[idx].id] = idx
        }
    }

    init(
        store: EncryptedConversationStore? = nil,
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
        deleteOperation: (@Sendable (UUID) async throws -> Void)? = nil,
        clearOperation: (@Sendable () throws -> Void)? = nil
    ) {
        let effectiveStore = store ?? .shared
        self.store = effectiveStore
        self.conversationLoader = conversationLoader ?? { conversationId in
            try await effectiveStore.loadConversation(id: conversationId)
        }
        self.conversationMetadataLoader = conversationMetadataLoader ?? {
            try await effectiveStore.loadConversationMetadata()
        }
        self.saveDebounceDuration = saveDebounceDuration
        self.searchIndexWarmupDelay = searchIndexWarmupDelay
        self.searchIndexWarmupEnabled = searchIndexWarmupEnabled
        self.beforePersistenceFlush = beforePersistenceFlush
        self.conversationSummaryInvalidateOperation = conversationSummaryInvalidateOperation ?? {
            MemoryContextProvider.shared.invalidateConversationSummariesForClear()
        }
        self.conversationSummaryRestoreOperation = conversationSummaryRestoreOperation ?? { snapshot in
            try await MemoryContextProvider.shared.restoreConversationSummariesAfterFailedClear(snapshot)
        }
        if let conversationSummaryClearOperation {
            self.conversationSummaryClearOperation = { _ in
                try await conversationSummaryClearOperation()
            }
        } else if RuntimeEnvironment.isRunningUnitTests {
            self.conversationSummaryClearOperation = { _ in }
        } else {
            self.conversationSummaryClearOperation = { cleanupToken in
                try await MemoryContextProvider.shared.clearAllConversationSummaries(
                    cleanupToken: cleanupToken
                )
            }
        }
        self.conversationSummaryRemoveOperation = conversationSummaryRemoveOperation ?? { conversationId in
            MemoryContextProvider.shared.removeConversationSummary(for: conversationId)
        }
        self.conversationSummaryUpdateOperation = conversationSummaryUpdateOperation ?? { conversation in
            MemoryContextProvider.shared.updateConversationSummary(conversation)
        }
        if let attachmentCleanupFenceBeginOperation {
            self.attachmentCleanupFenceBeginOperation = attachmentCleanupFenceBeginOperation
        } else if RuntimeEnvironment.isRunningUnitTests || attachmentCleanupSnapshotOperation != nil {
            self.attachmentCleanupFenceBeginOperation = {}
        } else {
            self.attachmentCleanupFenceBeginOperation = {
                AttachmentStorage.shared.beginCleanup()
            }
        }
        if let attachmentCleanupSnapshotOperation {
            self.attachmentCleanupSnapshotOperation = {
                try await Task.detached(priority: .utility) {
                    try attachmentCleanupSnapshotOperation()
                }.value
            }
        } else if RuntimeEnvironment.isRunningUnitTests {
            self.attachmentCleanupSnapshotOperation = { .empty }
        } else {
            self.attachmentCleanupSnapshotOperation = {
                try await Task.detached(priority: .utility) {
                    try AttachmentStorage.shared.cleanupSnapshot()
                }.value
            }
        }
        if let attachmentCleanupOperation {
            self.attachmentCleanupOperation = { _ in
                try await attachmentCleanupOperation()
            }
        } else if RuntimeEnvironment.isRunningUnitTests {
            self.attachmentCleanupOperation = { _ in }
        } else {
            self.attachmentCleanupOperation = { snapshot in
                try await Task.detached(priority: .utility) {
                    try AttachmentStorage.shared.clear(snapshot)
                }.value
            }
        }
        if let attachmentCleanupReleaseOperation {
            self.attachmentCleanupReleaseOperation = attachmentCleanupReleaseOperation
        } else if RuntimeEnvironment.isRunningUnitTests
            || attachmentCleanupFenceBeginOperation != nil
            || attachmentCleanupSnapshotOperation != nil
        {
            self.attachmentCleanupReleaseOperation = {}
        } else {
            self.attachmentCleanupReleaseOperation = {
                AttachmentStorage.shared.finishCleanup()
            }
        }
        self.spotlightIndexingEnabled = spotlightIndexingEnabled
            ?? (!RuntimeEnvironment.isRunningUnitTests
                || spotlightBatchIndexOperation != nil
                || spotlightDeleteOperation != nil)
        #if !os(watchOS)
            if let spotlightCleanupOperation {
                self.spotlightCleanupOperation = spotlightCleanupOperation
            } else if RuntimeEnvironment.isRunningUnitTests {
                self.spotlightCleanupOperation = {}
            } else {
                self.spotlightCleanupOperation = {
                    try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [
                        "co.ayna.conversations", "com.sertacozercan.ayna.conversation",
                    ])
                }
            }
            self.spotlightBatchIndexOperation = spotlightBatchIndexOperation ?? { conversations, shouldResetIndex in
                if shouldResetIndex {
                    try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [
                        "co.ayna.conversations", "com.sertacozercan.ayna.conversation",
                    ])
                }
                guard !conversations.isEmpty else { return }
                let items = conversations.map { ConversationManager.createSearchableItem(for: $0) }
                try await CSSearchableIndex.default().indexSearchableItems(items)
            }
            self.spotlightDeleteOperation = spotlightDeleteOperation ?? { conversationId in
                try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [conversationId.uuidString])
            }
        #else
            self.spotlightCleanupOperation = spotlightCleanupOperation ?? {}
            self.spotlightBatchIndexOperation = spotlightBatchIndexOperation ?? { _, _ in }
            self.spotlightDeleteOperation = spotlightDeleteOperation ?? { _ in }
        #endif
        persistenceCoordinator = ConversationPersistenceCoordinator(
            store: effectiveStore,
            debounceDuration: saveDebounceDuration,
            deleteOperation: deleteOperation,
            clearOperation: clearOperation
        )
        if startsLoadingImmediately {
            loadingTask = Task {
                await loadConversations()
            }
        } else {
            isLoaded = true
        }

        // Listen for save failures to reload data from disk
        if startsLoadingImmediately {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSaveFailure(_:)),
                name: .conversationSaveFailed,
                object: nil
            )
        }
    }

    @objc private func handleSaveFailure(_ notification: Notification) {
        guard let conversationId = notification.userInfo?["conversationId"] as? UUID else { return }

        logManager(
            "🔄 Reloading conversations after save failure",
            level: .info,
            metadata: ["failedId": conversationId.uuidString]
        )

        // Reload all conversations from disk to restore consistent state
        Task {
            await loadConversations()
        }
    }

    // MARK: - Persistence

    func save(_ conversation: Conversation, allowsRecreation: Bool = false) {
        if allowsRecreation {
            persistenceRecreationAuthorizationIds.insert(conversation.id)
        }
        let isMetadataBackedSnapshot = isMetadataBackedSnapshot(conversation)
        let activeClearTask = clearConversationsTask
        let activeDeletionTask = managerDeletionTasks[conversation.id]
        let persistenceSequence = advancePersistenceSequence(for: conversation.id)

        // Track the preparation task so lifecycle flushes cannot overtake it.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishPersistenceTask(for: conversation.id, sequence: persistenceSequence) }

            await activeClearTask?.value
            await activeDeletionTask?.value
            guard !Task.isCancelled else { return }
            guard persistenceSequenceById[conversation.id] == persistenceSequence else {
                await waitForSupersedingImmediatePersistence(
                    conversationId: conversation.id,
                    supersededSequence: persistenceSequence
                )
                return
            }
            if !isLoaded {
                _ = await loadingTask?.value
            }

            guard !Task.isCancelled,
                  let conversationToSave = await conversationPreparedForPersistence(
                      conversation,
                      isMetadataBackedSnapshot: isMetadataBackedSnapshot,
                      persistenceSequence: persistenceSequence
                  )
            else {
                return
            }
            guard persistenceSequenceById[conversation.id] == persistenceSequence else {
                await waitForSupersedingImmediatePersistence(
                    conversationId: conversation.id,
                    supersededSequence: persistenceSequence
                )
                return
            }

            let effectiveAllowsRecreation = persistenceRecreationAuthorizationIds.contains(conversation.id)
            let requiresImmediateSave = persistenceImmediateSaveIds.contains(conversation.id)
            if requiresImmediateSave {
                do {
                    try await persistenceCoordinator.saveImmediately(
                        conversationToSave,
                        allowsRecreation: effectiveAllowsRecreation
                    )
                } catch {
                    logManager(
                        "❌ Failed to save conversation immediately",
                        level: .error,
                        metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
                    )
                    return
                }
            } else {
                await persistenceCoordinator.enqueueSave(
                    conversationToSave,
                    allowsRecreation: effectiveAllowsRecreation
                )
            }
            if persistenceSequenceById[conversation.id] == persistenceSequence {
                if effectiveAllowsRecreation {
                    persistenceRecreationAuthorizationIds.remove(conversation.id)
                }
                if requiresImmediateSave {
                    persistenceImmediateSaveIds.remove(conversation.id)
                }
            }
            #if !os(watchOS)
                indexConversation(conversationToSave)
            #endif
        }
        persistenceTasksById[conversation.id] = task
    }

    @discardableResult
    func saveImmediately(_ conversation: Conversation) -> Task<Void, Never> {
        let isMetadataBackedSnapshot = isMetadataBackedSnapshot(conversation)
        let activeClearTask = clearConversationsTask
        let activeDeletionTask = managerDeletionTasks[conversation.id]
        persistenceImmediateSaveIds.insert(conversation.id)
        let persistenceSequence = advancePersistenceSequence(for: conversation.id)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishPersistenceTask(for: conversation.id, sequence: persistenceSequence) }

            await activeClearTask?.value
            await activeDeletionTask?.value
            guard !Task.isCancelled else { return }
            guard persistenceSequenceById[conversation.id] == persistenceSequence else {
                await waitForSupersedingImmediatePersistence(
                    conversationId: conversation.id,
                    supersededSequence: persistenceSequence
                )
                return
            }
            if !isLoaded {
                _ = await loadingTask?.value
            }

            guard !Task.isCancelled,
                  let conversationToSave = await conversationPreparedForPersistence(
                      conversation,
                      isMetadataBackedSnapshot: isMetadataBackedSnapshot,
                      persistenceSequence: persistenceSequence
                  )
            else {
                return
            }
            guard persistenceSequenceById[conversation.id] == persistenceSequence else {
                await waitForSupersedingImmediatePersistence(
                    conversationId: conversation.id,
                    supersededSequence: persistenceSequence
                )
                return
            }

            let effectiveAllowsRecreation = persistenceRecreationAuthorizationIds.contains(conversation.id)
            do {
                try await persistenceCoordinator.saveImmediately(
                    conversationToSave,
                    allowsRecreation: effectiveAllowsRecreation
                )
                if persistenceSequenceById[conversation.id] == persistenceSequence {
                    if effectiveAllowsRecreation {
                        persistenceRecreationAuthorizationIds.remove(conversation.id)
                    }
                    persistenceImmediateSaveIds.remove(conversation.id)
                }
                #if !os(watchOS)
                    indexConversation(conversationToSave)
                #endif
            } catch {
                logManager(
                    "❌ Failed to save conversation",
                    level: .error,
                    metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
                )
            }
        }
        persistenceTasksById[conversation.id] = task
        return task
    }

    /// Flushes all pending debounced saves immediately.
    /// Call on app termination to prevent data loss.
    func flushPendingSaves() async {
        while true {
            while let clearTask = clearConversationsTask {
                await clearTask.value
            }
            while !managerDeletionTasks.isEmpty {
                let tasks = Array(managerDeletionTasks.values)
                for task in tasks {
                    await task.value
                }
            }
            while !persistenceTasksById.isEmpty {
                let tasks = Array(persistenceTasksById.values)
                for task in tasks {
                    await task.value
                }
            }

            if !clearRollbackSummarySnapshotsByGeneration.isEmpty {
                let retryGeneration = clearConversationsGeneration
                let summaryRestored = await restoreClearRollbackSummaryIfNeeded(
                    through: retryGeneration
                )
                if summaryRestored {
                    resetClearRollbackState(through: retryGeneration)
                }
            }

            await beforePersistenceFlush?()
            let persistenceSequenceBeforeCoordinatorFlush = nextPersistenceSequence
            await persistenceCoordinator.flushPendingSaves()

            guard clearConversationsTask == nil,
                  managerDeletionTasks.isEmpty,
                  persistenceTasksById.isEmpty,
                  nextPersistenceSequence == persistenceSequenceBeforeCoordinatorFlush
            else {
                continue
            }
            return
        }
    }

    private func advancePersistenceSequence(for conversationId: UUID) -> UInt64 {
        nextPersistenceSequence &+= 1
        persistenceSequenceById[conversationId] = nextPersistenceSequence
        return nextPersistenceSequence
    }

    private func invalidatePendingPersistence(for conversationId: UUID) {
        _ = advancePersistenceSequence(for: conversationId)
        persistenceTasksById.removeValue(forKey: conversationId)?.cancel()
        persistenceRecreationAuthorizationIds.remove(conversationId)
        persistenceImmediateSaveIds.remove(conversationId)
    }

    private func finishPersistenceTask(for conversationId: UUID, sequence: UInt64) {
        guard persistenceSequenceById[conversationId] == sequence else { return }
        persistenceTasksById.removeValue(forKey: conversationId)
    }

    private func waitForSupersedingImmediatePersistence(
        conversationId: UUID,
        supersededSequence: UInt64
    ) async {
        var observedSequence = supersededSequence
        while persistenceImmediateSaveIds.contains(conversationId),
              let currentSequence = persistenceSequenceById[conversationId],
              currentSequence != observedSequence,
              let task = persistenceTasksById[conversationId]
        {
            observedSequence = currentSequence
            await task.value
        }
    }

    private func registerManagerDeletionTask(
        _ task: Task<Void, Never>,
        for conversationId: UUID,
        version: UInt64
    ) {
        managerDeletionTasks[conversationId] = task
        managerDeletionTaskVersions[conversationId] = version
    }

    private func finishManagerDeletionTask(for conversationId: UUID, version: UInt64) {
        guard managerDeletionTaskVersions[conversationId] == version else { return }
        managerDeletionTasks.removeValue(forKey: conversationId)
        managerDeletionTaskVersions.removeValue(forKey: conversationId)
    }

    private func nextManagerDeletionVersion() -> UInt64 {
        nextManagerDeletionTaskVersion &+= 1
        return nextManagerDeletionTaskVersion
    }

    private func nextReconciliationVersion() -> UInt64 {
        nextReconciliationMutationVersion &+= 1
        return nextReconciliationMutationVersion
    }

    private func isMetadataBackedSnapshot(_ conversation: Conversation) -> Bool {
        metadataOnlyConversationIds.contains(conversation.id) || conversation.metadataPreview != nil
    }

    func delete(_ conversationId: UUID) {
        invalidatePendingPersistence(for: conversationId)
        cancelFullConversationLoad(conversationId)
        let deletionVersion = nextManagerDeletionVersion()
        let deletionReconciliationVersion = nextReconciliationVersion()
        latestManagerDeletionVersionById[conversationId] = deletionReconciliationVersion
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishManagerDeletionTask(for: conversationId, version: deletionVersion) }
            do {
                try await persistenceCoordinator.delete(conversationId)
                conversationSummaryRemoveOperation(conversationId)
                if let index = getConversationIndex(for: conversationId) {
                    conversations.remove(at: index)
                    metadataOnlyConversationIds.remove(conversationId)
                    metadataSearchTextById.removeValue(forKey: conversationId)
                    updateCacheForRemoval(id: conversationId, at: index)
                }
                if selectedConversationId == conversationId {
                    selectedConversationId = nil
                }
            } catch {
                if latestManagerDeletionVersionById[conversationId] == deletionReconciliationVersion {
                    latestManagerDeletionVersionById.removeValue(forKey: conversationId)
                }
                logManager(
                    "❌ Failed to delete conversation",
                    level: .error,
                    metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
                )
            }
        }
        registerManagerDeletionTask(task, for: conversationId, version: deletionVersion)
    }

    private func loadConversations() async {
        let spotlightIndexWasCleared = await completePendingPrivacyCleanupIfNeeded()
        cancelAllFullConversationLoads()
        cancelSearchIndexWarmup()
        #if !os(watchOS)
            invalidateSpotlightIndexing()
        #endif
        conversationLoadGeneration &+= 1
        let loadGeneration = conversationLoadGeneration
        let persistenceSequenceAtLoadStart = nextPersistenceSequence
        let persistenceStateAtLoadStart = await persistenceCoordinator.reconciliationState()
        guard loadGeneration == conversationLoadGeneration,
              clearConversationsTask == nil
        else {
            return
        }
        let persistingAtLoadStart = persistenceStateAtLoadStart.dirtyIds
            .union(persistenceTasksById.keys)
        let reconciliationVersionAtLoadStart = nextReconciliationMutationVersion
        let deletingAtLoadStart = persistenceStateAtLoadStart.deletingIds
            .union(managerDeletionTasks.keys)

        do {
            let metadataFromDisk = try await conversationMetadataLoader()
            guard loadGeneration == conversationLoadGeneration,
                  clearConversationsTask == nil
            else {
                return
            }

            // Validate and fix models that no longer exist for the in-memory list.
            let availableModels = AIService.shared.customModels
            let defaultModel = AIService.shared.selectedModel

            let persistenceState = await persistenceCoordinator.reconciliationState()
            guard loadGeneration == conversationLoadGeneration,
                  clearConversationsTask == nil
            else {
                return
            }
            cancelAllFullConversationLoads()
            let dirtyIds = persistenceState.dirtyIds.union(persistenceTasksById.keys)
            let persistedDuringLoadIds = Set(persistenceSequenceById.compactMap { id, sequence in
                sequence > persistenceSequenceAtLoadStart ? id : nil
            })
            let protectedPersistenceIds = dirtyIds
                .union(persistingAtLoadStart)
                .union(persistedDuringLoadIds)
            let deletingIds = persistenceState.deletingIds
                .union(managerDeletionTasks.keys)
                .union(deletingAtLoadStart)
            let memoryById = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, new in
                DiagnosticsLogger.log(.conversationManager, level: .default, message: "Duplicate conversation ID in memory", metadata: ["id": "\(new.id)"])
                return new
            })

            var reconciled: [Conversation] = []
            reconciled.reserveCapacity(max(memoryById.count, metadataFromDisk.count))
            var nextMetadataOnlyIds: Set<UUID> = []
            var metadataIds: Set<UUID> = []
            metadataIds.reserveCapacity(metadataFromDisk.count)

            for metadata in metadataFromDisk {
                let latestDeletionVersion = latestManagerDeletionVersionById[metadata.id] ?? 0
                let latestRecreationVersion = latestManagerRecreationVersionById[metadata.id] ?? 0
                let recreationBecameCurrentAfterLoad = latestRecreationVersion > reconciliationVersionAtLoadStart
                    && latestRecreationVersion > latestDeletionVersion
                let authorizedRecreationIsPending = latestRecreationVersion > latestDeletionVersion
                    && protectedPersistenceIds.contains(metadata.id)
                if recreationBecameCurrentAfterLoad || authorizedRecreationIsPending,
                   let memoryConversation = memoryById[metadata.id]
                {
                    metadataIds.insert(metadata.id)
                    reconciled.append(memoryConversation)
                    if isMetadataBackedSnapshot(memoryConversation) {
                        nextMetadataOnlyIds.insert(metadata.id)
                    }
                    continue
                }

                let deletionBecameCurrentAfterLoad = latestDeletionVersion > reconciliationVersionAtLoadStart
                    && latestDeletionVersion > latestRecreationVersion
                guard !deletingIds.contains(metadata.id),
                      !deletionBecameCurrentAfterLoad
                else {
                    continue
                }
                metadataIds.insert(metadata.id)

                if protectedPersistenceIds.contains(metadata.id),
                   let memoryConversation = memoryById[metadata.id]
                {
                    reconciled.append(memoryConversation)
                    if isMetadataBackedSnapshot(memoryConversation) {
                        nextMetadataOnlyIds.insert(metadata.id)
                    }
                    continue
                }

                var placeholder = placeholderConversation(from: metadata)
                if !availableModels.contains(placeholder.model) {
                    placeholder.model = defaultModel
                }
                reconciled.append(placeholder)
                nextMetadataOnlyIds.insert(metadata.id)
            }

            // Add any dirty in-memory conversations not present on disk yet (e.g., newly created)
            let recreatedAfterLoadIds = Set(latestManagerRecreationVersionById.compactMap { id, version in
                let deletionVersion = latestManagerDeletionVersionById[id] ?? 0
                return version > reconciliationVersionAtLoadStart && version > deletionVersion ? id : nil
            })
            for protectedId in protectedPersistenceIds.union(recreatedAfterLoadIds) {
                if !metadataIds.contains(protectedId), let memoryConversation = memoryById[protectedId] {
                    reconciled.append(memoryConversation)
                    if isMetadataBackedSnapshot(memoryConversation) {
                        nextMetadataOnlyIds.insert(protectedId)
                    }
                }
            }

            // Sort by updated date descending to ensure correct order
            reconciled.sort { $0.updatedAt > $1.updatedAt }
            let searchIndexWarmupIds = Set(
                reconciled.lazy
                    .filter { nextMetadataOnlyIds.contains($0.id) }
                    .prefix(Self.searchIndexWarmupLimit)
                    .map(\.id)
            )

            conversations = reconciled
            metadataOnlyConversationIds = nextMetadataOnlyIds
            metadataSearchTextById = metadataFromDisk.reduce(into: [:]) { searchTextById, metadata in
                guard nextMetadataOnlyIds.contains(metadata.id) else { return }
                searchTextById[metadata.id] = metadata.searchableText
            }

            // If selected conversation no longer exists, clear selection
            if let selectedId = selectedConversationId,
               !conversations.contains(where: { $0.id == selectedId })
            {
                selectedConversationId = nil
            } else if let selectedId = selectedConversationId {
                scheduleFullConversationLoadIfNeeded(selectedId)
            }

            // Rebuild the index cache after loading and sorting
            rebuildIndexCache()

            isLoaded = true
            if searchIndexWarmupEnabled {
                scheduleSearchIndexWarmup(for: searchIndexWarmupIds)
            }

            logManager(
                "✅ Loaded \(conversations.count) conversation metadata records",
                level: .info,
                metadata: ["count": "\(conversations.count)"]
            )

            // Index loaded full conversations for Spotlight; avoid replacing a rich existing
            // index with title-only metadata placeholders.
            #if !os(watchOS)
                indexAllConversations(includingMetadataOnly: spotlightIndexWasCleared)
            #endif
        } catch {
            guard loadGeneration == conversationLoadGeneration else { return }
            if let encryptedStoreError = error as? EncryptedStoreError {
                if encryptedStoreError.clearNeedsRecovery {
                    persistenceErrorMessage = "Conversation storage needs recovery. Restart Ayna before making more changes."
                } else if encryptedStoreError.clearWasCommitted {
                    persistenceErrorMessage = "Encrypted conversation backup cleanup is incomplete. Restart Ayna to retry secure cleanup."
                }
            }
            logManager(
                "❌ Failed to load conversations",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            if conversations.isEmpty {
                conversations = []
                metadataOnlyConversationIds.removeAll()
                metadataSearchTextById.removeAll()
                conversationIndexCache.removeAll()
            }
            isLoaded = true
        }
    }

    private func scheduleSearchIndexWarmup(for conversationIds: Set<UUID>) {
        cancelSearchIndexWarmup()

        let version = searchIndexWarmupVersion
        let delay = searchIndexWarmupDelay
        let store = store
        searchIndexWarmupTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                try await store.warmConversationSearchIndex(candidateIds: conversationIds)
            } catch is CancellationError {
                // A reload or clear superseded this warmup.
            } catch {
                self?.logManager(
                    "Conversation search-index warmup failed",
                    level: .error,
                    metadata: ["error": error.localizedDescription]
                )
            }

            self?.finishSearchIndexWarmup(version: version)
        }
    }

    private func cancelSearchIndexWarmup() {
        searchIndexWarmupVersion &+= 1
        searchIndexWarmupTask?.cancel()
        searchIndexWarmupTask = nil
    }

    private func finishSearchIndexWarmup(version: UInt64) {
        guard searchIndexWarmupVersion == version else { return }
        searchIndexWarmupTask = nil
    }

    private func placeholderConversation(from metadata: ConversationMetadata) -> Conversation {
        Conversation(
            id: metadata.id,
            title: metadata.title,
            messages: [],
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            model: metadata.model,
            systemPromptMode: metadata.systemPromptMode,
            temperature: metadata.temperature,
            multiModelEnabled: metadata.multiModelEnabled,
            activeModels: metadata.activeModels,
            responseGroups: [],
            metadataPreview: metadata.lastMessagePreview.isEmpty ? nil : metadata.lastMessagePreview
        )
    }

    private func conversationPreparedForPersistence(
        _ proposedConversation: Conversation,
        isMetadataBackedSnapshot: Bool,
        persistenceSequence: UInt64
    ) async -> Conversation? {
        guard !Task.isCancelled,
              persistenceSequenceById[proposedConversation.id] == persistenceSequence
        else {
            return nil
        }
        guard isMetadataBackedSnapshot else {
            return proposedConversation
        }

        do {
            guard let loadedConversation = try await store.loadConversation(id: proposedConversation.id) else {
                logManager(
                    "⚠️ Skipping save for metadata-only conversation missing full store record",
                    level: .error,
                    metadata: ["id": proposedConversation.id.uuidString]
                )
                return nil
            }
            guard !Task.isCancelled,
                  persistenceSequenceById[proposedConversation.id] == persistenceSequence
            else {
                return nil
            }

            guard let index = getConversationIndex(for: proposedConversation.id) else {
                logManager(
                    "⚠️ Skipping metadata-only save for conversation no longer in memory",
                    level: .info,
                    metadata: ["id": proposedConversation.id.uuidString]
                )
                return nil
            }

            let latestConversation = conversations[index]
            guard metadataOnlyConversationIds.contains(proposedConversation.id)
                || latestConversation.metadataPreview != nil
            else {
                guard proposedConversation.updatedAt > latestConversation.updatedAt else {
                    return latestConversation
                }
                return mergeMetadataBackedChanges(
                    from: proposedConversation,
                    into: latestConversation
                )
            }

            let proposedIsAtLeastAsRecent = proposedConversation.updatedAt >= latestConversation.updatedAt
            let metadataSource = proposedIsAtLeastAsRecent ? proposedConversation : latestConversation
            let mergedConversation = mergeMetadataBackedChanges(
                from: metadataSource,
                into: loadedConversation
            )

            conversations[index] = mergedConversation
            metadataOnlyConversationIds.remove(proposedConversation.id)
            metadataSearchTextById.removeValue(forKey: proposedConversation.id)

            return mergedConversation
        } catch is CancellationError {
            return nil
        } catch {
            logManager(
                "❌ Failed to load metadata-only conversation before save",
                level: .error,
                metadata: ["id": proposedConversation.id.uuidString, "error": error.localizedDescription]
            )
            return nil
        }
    }

    private func mergeMetadataBackedChanges(
        from proposedConversation: Conversation,
        into loadedConversation: Conversation
    ) -> Conversation {
        var mergedConversation = loadedConversation
        let proposedIsAtLeastAsRecent = proposedConversation.updatedAt >= loadedConversation.updatedAt

        if proposedIsAtLeastAsRecent {
            mergedConversation.title = proposedConversation.title
            mergedConversation.createdAt = proposedConversation.createdAt
            mergedConversation.model = proposedConversation.model
            mergedConversation.systemPromptMode = proposedConversation.systemPromptMode
            mergedConversation.temperature = proposedConversation.temperature
            mergedConversation.multiModelEnabled = proposedConversation.multiModelEnabled
            mergedConversation.activeModels = proposedConversation.activeModels
            mergedConversation.pendingAutoSendPrompt = proposedConversation.pendingAutoSendPrompt

            var existingMessageIds = Set(mergedConversation.messages.map(\.id))
            for message in proposedConversation.messages where !existingMessageIds.contains(message.id) {
                mergedConversation.messages.append(message)
                existingMessageIds.insert(message.id)
            }

            var existingResponseGroupIds = Set(mergedConversation.responseGroups.map(\.id))
            for responseGroup in proposedConversation.responseGroups where !existingResponseGroupIds.contains(responseGroup.id) {
                mergedConversation.responseGroups.append(responseGroup)
                existingResponseGroupIds.insert(responseGroup.id)
            }

            if proposedConversation.updatedAt > mergedConversation.updatedAt {
                mergedConversation.updatedAt = proposedConversation.updatedAt
            }
        }

        mergedConversation.metadataPreview = nil
        return mergedConversation
    }

    private func scheduleFullConversationLoadIfNeeded(_ conversationId: UUID) {
        guard metadataOnlyConversationIds.contains(conversationId),
              fullConversationLoadTasks[conversationId] == nil
        else {
            return
        }

        _ = startFullConversationLoad(conversationId)
    }

    private func cancelFullConversationLoad(_ conversationId: UUID) {
        fullConversationLoadTaskVersions.removeValue(forKey: conversationId)
        fullConversationLoadTasks.removeValue(forKey: conversationId)?.cancel()
    }

    private func cancelAllFullConversationLoads() {
        for task in fullConversationLoadTasks.values {
            task.cancel()
        }
        fullConversationLoadTasks.removeAll()
        fullConversationLoadTaskVersions.removeAll()
    }

    private func startFullConversationLoad(_ conversationId: UUID) -> Task<Conversation?, Never> {
        nextFullConversationLoadTaskVersion &+= 1
        let version = nextFullConversationLoadTaskVersion
        let task = Task<Conversation?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadFullConversation(conversationId, version: version)
        }
        fullConversationLoadTasks[conversationId] = task
        fullConversationLoadTaskVersions[conversationId] = version
        return task
    }

    func isMetadataOnlyConversation(_ conversationId: UUID) -> Bool {
        metadataOnlyConversationIds.contains(conversationId)
    }

    /// Loads a metadata-backed conversation's full message history if needed.
    @discardableResult
    func ensureConversationLoaded(_ conversationId: UUID) async -> Conversation? {
        if let existingTask = fullConversationLoadTasks[conversationId] {
            return await existingTask.value
        }

        guard metadataOnlyConversationIds.contains(conversationId) else {
            return conversationSnapshot(byId: conversationId)
        }

        return await startFullConversationLoad(conversationId).value
    }

    private func loadFullConversation(
        _ conversationId: UUID,
        version: UInt64
    ) async -> Conversation? {
        defer {
            finishFullConversationLoad(conversationId, version: version)
        }

        guard metadataOnlyConversationIds.contains(conversationId) else {
            return conversationSnapshot(byId: conversationId)
        }

        do {
            guard var loadedConversation = try await conversationLoader(conversationId) else {
                return nil
            }
            guard !Task.isCancelled,
                  metadataOnlyConversationIds.contains(conversationId),
                  conversationSnapshot(byId: conversationId) != nil
            else {
                return conversationSnapshot(byId: conversationId)
            }

            let availableModels = AIService.shared.customModels
            let storageModelWasUnavailable = !availableModels.contains(loadedConversation.model)
            if storageModelWasUnavailable {
                loadedConversation.model = AIService.shared.selectedModel
            }

            let dirtyIds = await persistenceCoordinator.pendingConversationIds()
            guard !dirtyIds.contains(conversationId) else {
                return conversationSnapshot(byId: conversationId)
            }

            guard !Task.isCancelled,
                  metadataOnlyConversationIds.contains(conversationId),
                  let index = getConversationIndex(for: conversationId)
            else {
                return conversationSnapshot(byId: conversationId)
            }

            let currentConversation = conversations[index]
            var mergedConversation = mergeMetadataBackedChanges(
                from: currentConversation,
                into: loadedConversation
            )
            let appliedDefaultModelRepair = storageModelWasUnavailable
                && !availableModels.contains(mergedConversation.model)
            if appliedDefaultModelRepair {
                mergedConversation.model = loadedConversation.model
            }
            conversations[index] = mergedConversation
            metadataOnlyConversationIds.remove(conversationId)
            metadataSearchTextById.removeValue(forKey: conversationId)
            #if !os(watchOS)
                indexConversation(mergedConversation)
            #endif
            if storageModelWasUnavailable {
                _ = await persistenceCoordinator.enqueueDerivedUpdateIfCurrent(mergedConversation)
            }
            return conversationSnapshot(byId: conversationId)
        } catch is CancellationError {
            return nil
        } catch {
            logManager(
                "❌ Failed to lazy-load conversation",
                level: .error,
                metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
            )
            return nil
        }
    }

    private func finishFullConversationLoad(_ conversationId: UUID, version: UInt64) {
        guard fullConversationLoadTaskVersions[conversationId] == version else { return }
        fullConversationLoadTasks.removeValue(forKey: conversationId)
        fullConversationLoadTaskVersions.removeValue(forKey: conversationId)
    }

    private func conversationSnapshot(byId conversationId: UUID) -> Conversation? {
        guard let index = getConversationIndex(for: conversationId) else { return nil }
        return conversations[index]
    }

    /// Public method to reload conversations from storage.
    /// Used for pull-to-refresh on iOS.
    func reloadConversations() async {
        logManager("🔄 Reloading conversations from storage", level: .info)
        while let clearTask = clearConversationsTask {
            await clearTask.value
        }
        await loadConversations()
    }

    func clearAllConversations() {
        persistenceErrorMessage = nil
        let previousClearTask = clearConversationsTask
        let clearWasAlreadyActive = previousClearTask != nil
        if clearWasAlreadyActive {
            logManager("Merging another clear request into the active clear", level: .info)
        }

        let reconciliationVersionAtClearStart = nextReconciliationMutationVersion
        let privacyMarkersBeforeClear: PrivacyCleanupMarkerSnapshot
        do {
            privacyMarkersBeforeClear = try store.pendingPrivacyCleanupMarkerSnapshotThrowing()
        } catch {
            recordPersistenceError(
                "Couldn’t inspect pending privacy cleanup. Restart Ayna and try again."
            )
            return
        }
        clearConversationsGeneration &+= 1
        let generation = clearConversationsGeneration
        let attachmentCleanupFencePreparation = beginAttachmentCleanupFence()
        NotificationCenter.default.post(name: .conversationHistoryClearStarted, object: self)

        clearFailureNeedsReload = clearFailureNeedsReload || !isLoaded
        let summarySnapshot = conversationSummaryInvalidateOperation()
        clearRollbackSummarySnapshotsByGeneration[generation] = summarySnapshot
        for conversation in conversations {
            clearRollbackConversationsById[conversation.id] = conversation
            clearRollbackConversationGenerationById[conversation.id] = generation
        }
        clearRollbackMetadataOnlyIds.formUnion(metadataOnlyConversationIds)
        for conversationId in metadataOnlyConversationIds {
            clearRollbackMetadataOnlyGenerationById[conversationId] = generation
        }
        for (conversationId, searchText) in metadataSearchTextById {
            clearRollbackMetadataSearchTextById[conversationId] = searchText
            clearRollbackMetadataSearchTextGenerationById[conversationId] = generation
        }

        conversationLoadGeneration &+= 1
        isLoaded = true
        let conversationIds = Set(conversations.map(\.id))
        for conversationId in conversationIds {
            invalidatePendingPersistence(for: conversationId)
        }
        cancelAllFullConversationLoads()
        cancelSearchIndexWarmup()
        for conversationId in Array(titleRequestGenerationByConversationId.keys) {
            invalidateTitleRequest(for: conversationId)
        }
        conversations.removeAll()
        metadataOnlyConversationIds.removeAll()
        metadataSearchTextById.removeAll()
        conversationIndexCache.removeAll()
        let task = Task { [weak self] in
            await previousClearTask?.value
            guard let self else { return }
            let attachmentCleanupPreparation = await prepareAttachmentCleanup(
                fencePreparation: attachmentCleanupFencePreparation
            )
            let attachmentCleanupSnapshot = attachmentCleanupPreparation.snapshot
            let attachmentCleanupSnapshotError = attachmentCleanupPreparation.errorDescription
            let attachmentCleanupFenceActive = attachmentCleanupPreparation.fenceIsActive
            var clearCommitted = false
            var clearNeedsRecovery = false
            defer {
                if !clearCommitted, !clearNeedsRecovery {
                    NotificationCenter.default.post(
                        name: .conversationHistoryClearRolledBack,
                        object: self
                    )
                }
            }
            do {
                guard let attachmentCleanupSnapshot else {
                    throw AttachmentStorageError.missingCleanupSnapshot
                }
                try await persistenceCoordinator.clearAll(
                    suppressing: conversationIds,
                    attachmentCleanupSnapshot: attachmentCleanupSnapshot
                )
                clearCommitted = true
                NotificationCenter.default.post(name: .conversationHistoryClearCommitted, object: self)
                discardClearRollbackState(for: conversationIds, generation: generation)
                await completePostClearPrivacyCleanup(
                    attachmentCleanupSnapshot: attachmentCleanupSnapshot,
                    attachmentCleanupSnapshotError: attachmentCleanupSnapshotError,
                    privacyMarkersBeforeClear: privacyMarkersBeforeClear,
                    attachmentCleanupFenceActive: attachmentCleanupFenceActive
                )
                logManager("🧹 Cleared encrypted conversation store", level: .info)
            } catch {
                let encryptedStoreError = error as? EncryptedStoreError
                clearCommitted = encryptedStoreError?.clearWasCommitted == true
                clearNeedsRecovery = encryptedStoreError?.clearNeedsRecovery == true
                if !clearCommitted, !clearNeedsRecovery, attachmentCleanupFenceActive {
                    attachmentCleanupReleaseOperation()
                }
                if clearCommitted {
                    NotificationCenter.default.post(name: .conversationHistoryClearCommitted, object: self)
                    discardClearRollbackState(for: conversationIds, generation: generation)
                    await completePostClearPrivacyCleanup(
                        attachmentCleanupSnapshot: attachmentCleanupSnapshot,
                        attachmentCleanupSnapshotError: attachmentCleanupSnapshotError,
                        privacyMarkersBeforeClear: privacyMarkersBeforeClear,
                        attachmentCleanupFenceActive: attachmentCleanupFenceActive
                    )
                }
                logManager(
                    clearCommitted
                        ? "⚠️ Cleared conversations, but encrypted backup cleanup is incomplete"
                        : clearNeedsRecovery
                        ? "⚠️ Conversation clear requires storage recovery"
                        : "⚠️ Failed to clear conversation store",
                    level: .error,
                    metadata: ["error": error.localizedDescription]
                )
                let clearErrorMessage = if clearCommitted {
                    "Conversations were cleared, but encrypted backup cleanup failed. Restart Ayna to retry secure cleanup."
                } else if clearNeedsRecovery {
                    "Conversation storage needs recovery. Restart Ayna before making more changes."
                } else {
                    "Couldn’t clear conversations. \(error.localizedDescription)"
                }
                recordPersistenceError(clearErrorMessage)
                if !clearCommitted, clearConversationsGeneration == generation {
                    clearConversationsTask = nil
                    if clearFailureNeedsReload, !clearNeedsRecovery {
                        let summaryRestored = await restoreClearRollbackSummaryIfNeeded(
                            through: generation
                        )
                        guard clearConversationsGeneration == generation else { return }
                        resetClearRollbackState(
                            through: generation,
                            preservingSummaryDigest: !summaryRestored
                        )
                        isLoaded = false
                        await loadConversations()
                    } else {
                        let conversationsCreatedDuringClear = conversations
                        let currentIds = Set(conversationsCreatedDuringClear.map(\.id))
                        var mergedById = clearRollbackConversationsById
                        for conversation in conversationsCreatedDuringClear {
                            mergedById[conversation.id] = conversation
                        }
                        conversations = mergedById.values.sorted { $0.updatedAt > $1.updatedAt }

                        metadataOnlyConversationIds = clearRollbackMetadataOnlyIds
                        for conversation in conversationsCreatedDuringClear
                            where conversation.metadataPreview == nil
                        {
                            metadataOnlyConversationIds.remove(conversation.id)
                        }
                        metadataSearchTextById = clearRollbackMetadataSearchTextById
                        for conversation in conversationsCreatedDuringClear
                            where conversation.metadataPreview == nil
                        {
                            metadataSearchTextById.removeValue(forKey: conversation.id)
                        }
                        rebuildIndexCache()
                        isLoaded = true
                        let conversationsToRestore = clearRollbackConversationsById.values
                        let summaryRestored = await restoreClearRollbackSummaryIfNeeded(
                            through: generation
                        )
                        guard clearConversationsGeneration == generation else { return }
                        resetClearRollbackState(
                            through: generation,
                            preservingSummaryDigest: !summaryRestored
                        )
                        if !clearNeedsRecovery {
                            for conversation in conversationsToRestore where !currentIds.contains(conversation.id) {
                                save(conversation, allowsRecreation: true)
                            }
                        }
                    }
                }
            }
            if clearConversationsGeneration == generation {
                if clearCommitted {
                    discardManagerReconciliationVersions(
                        through: reconciliationVersionAtClearStart
                    )
                    resetClearRollbackState(through: generation)
                }
                clearConversationsTask = nil
            }
        }
        clearConversationsTask = task
    }

    func interruptedConversationClearWasCommitted() throws -> Bool {
        try !store.pendingPrivacyCleanupMarkerSnapshotThrowing().isEmpty
    }

    private func beginAttachmentCleanupFence() -> AttachmentCleanupFencePreparation {
        do {
            try attachmentCleanupFenceBeginOperation()
            return AttachmentCleanupFencePreparation(isActive: true, errorDescription: nil)
        } catch {
            return AttachmentCleanupFencePreparation(
                isActive: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func prepareAttachmentCleanup(
        fencePreparation: AttachmentCleanupFencePreparation
    ) async -> AttachmentCleanupPreparation {
        guard fencePreparation.isActive else {
            return AttachmentCleanupPreparation(
                snapshot: nil,
                errorDescription: fencePreparation.errorDescription,
                fenceIsActive: false
            )
        }
        do {
            let snapshot = try await attachmentCleanupSnapshotOperation()
            return AttachmentCleanupPreparation(
                snapshot: snapshot,
                errorDescription: nil,
                fenceIsActive: true
            )
        } catch {
            return AttachmentCleanupPreparation(
                snapshot: nil,
                errorDescription: error.localizedDescription,
                fenceIsActive: true
            )
        }
    }

    private func restoreClearRollbackSummaryIfNeeded(through generation: UInt64) async -> Bool {
        let generationsToRestore = clearRollbackSummarySnapshotsByGeneration.keys
            .filter { $0 <= generation }
            .sorted()
        guard !generationsToRestore.isEmpty else { return true }
        var digest = RecentConversationsDigest()
        var wasLoaded = true
        var summaryClearGeneration: UInt64 = 0
        for snapshotGeneration in generationsToRestore {
            guard let generationSnapshot = clearRollbackSummarySnapshotsByGeneration[snapshotGeneration] else { continue }
            wasLoaded = wasLoaded && generationSnapshot.wasLoaded
            summaryClearGeneration = generationSnapshot.generation
            for summary in generationSnapshot.digest.summaries {
                digest.upsertSummary(summary)
            }
        }
        let snapshot = ConversationSummaryClearSnapshot(
            digest: digest,
            wasLoaded: wasLoaded,
            generation: summaryClearGeneration
        )
        do {
            try await conversationSummaryRestoreOperation(snapshot)
            for snapshotGeneration in generationsToRestore {
                clearRollbackSummarySnapshotsByGeneration.removeValue(forKey: snapshotGeneration)
            }
            return true
        } catch {
            recordPersistenceError(
                "Conversation history was restored, but its summary rollback could not be saved. \(error.localizedDescription)"
            )
            logManager(
                "Failed to persist conversation-summary rollback",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    private func resetClearRollbackState(
        through generation: UInt64,
        preservingSummaryDigest: Bool = false
    ) {
        for (conversationId, snapshotGeneration) in clearRollbackConversationGenerationById
            where snapshotGeneration <= generation
        {
            clearRollbackConversationsById.removeValue(forKey: conversationId)
            clearRollbackConversationGenerationById.removeValue(forKey: conversationId)
        }
        for (conversationId, snapshotGeneration) in clearRollbackMetadataOnlyGenerationById
            where snapshotGeneration <= generation
        {
            clearRollbackMetadataOnlyIds.remove(conversationId)
            clearRollbackMetadataOnlyGenerationById.removeValue(forKey: conversationId)
        }
        for (conversationId, snapshotGeneration) in clearRollbackMetadataSearchTextGenerationById
            where snapshotGeneration <= generation
        {
            clearRollbackMetadataSearchTextById.removeValue(forKey: conversationId)
            clearRollbackMetadataSearchTextGenerationById.removeValue(forKey: conversationId)
        }
        if !preservingSummaryDigest {
            for snapshotGeneration in clearRollbackSummarySnapshotsByGeneration.keys
                where snapshotGeneration <= generation
            {
                clearRollbackSummarySnapshotsByGeneration.removeValue(forKey: snapshotGeneration)
            }
        }
        if clearConversationsGeneration == generation {
            clearFailureNeedsReload = false
        }
    }

    func dismissPersistenceError() {
        persistenceErrorMessage = nil
    }

    private func recordPersistenceError(_ message: String) {
        guard let existingMessage = persistenceErrorMessage, !existingMessage.isEmpty else {
            persistenceErrorMessage = message
            return
        }
        guard !existingMessage.contains(message) else { return }
        persistenceErrorMessage = "\(existingMessage) \(message)"
    }

    private func clearConversationSummariesAfterCommittedClear(
        cleanupToken: String
    ) async -> Bool {
        do {
            try await conversationSummaryClearOperation(cleanupToken)
            return true
        } catch {
            recordPersistenceError(
                "Conversations were cleared, but conversation-summary cleanup failed. Restart Ayna and clear conversations again."
            )
            logManager(
                "Failed to clear conversation summaries after committed clear",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    private func clearAttachmentsAfterCommittedClear(
        for markerSnapshot: PrivacyCleanupMarkerSnapshot,
        cleanupFenceAlreadyActive: Bool
    ) async -> Bool {
        let cleanupSnapshot: AttachmentCleanupSnapshot
        var cleanupFenceActive = cleanupFenceAlreadyActive
        do {
            switch store.attachmentCleanupPlan(for: markerSnapshot) {
            case .completed:
                if cleanupFenceActive {
                    attachmentCleanupReleaseOperation()
                }
                return true
            case let .fileNames(fileNames):
                if !cleanupFenceActive {
                    try attachmentCleanupFenceBeginOperation()
                    cleanupFenceActive = true
                }
                cleanupSnapshot = AttachmentCleanupSnapshot(fileNames: fileNames)
            case .unknown:
                throw AttachmentStorageError.missingCleanupSnapshot
            }
            try await attachmentCleanupOperation(cleanupSnapshot)
            try store.markAttachmentCleanupCompleted(for: markerSnapshot)
            if cleanupFenceActive {
                attachmentCleanupReleaseOperation()
            }
            return true
        } catch {
            if cleanupFenceActive {
                attachmentCleanupReleaseOperation()
            }
            recordPersistenceError(
                "Conversations were cleared, but attachment cleanup failed. Restart Ayna to retry secure cleanup."
            )
            logManager(
                "Failed to clear attachments after committed clear",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    private func completePendingPrivacyCleanupIfNeeded() async -> Bool {
        let markerSnapshot: PrivacyCleanupMarkerSnapshot
        do {
            markerSnapshot = try store.pendingPrivacyCleanupMarkerSnapshotThrowing()
        } catch {
            recordPersistenceError(
                "Couldn’t inspect pending privacy cleanup. Restart Ayna and try again."
            )
            return false
        }
        guard !markerSnapshot.isEmpty else { return false }
        return await completePostClearPrivacyCleanup(acknowledging: markerSnapshot)
    }

    @discardableResult
    private func completePostClearPrivacyCleanup(
        acknowledging markerSnapshot: PrivacyCleanupMarkerSnapshot? = nil,
        attachmentCleanupSnapshot: AttachmentCleanupSnapshot? = nil,
        attachmentCleanupSnapshotError: String? = nil,
        privacyMarkersBeforeClear: PrivacyCleanupMarkerSnapshot? = nil,
        attachmentCleanupFenceActive: Bool = false
    ) async -> Bool {
        let effectiveMarkerSnapshot: PrivacyCleanupMarkerSnapshot
        if let suppliedMarkerSnapshot = markerSnapshot {
            effectiveMarkerSnapshot = suppliedMarkerSnapshot
        } else {
            do {
                effectiveMarkerSnapshot = try store.pendingPrivacyCleanupMarkerSnapshotThrowing()
            } catch {
                releaseAttachmentCleanupFenceIfNeeded(attachmentCleanupFenceActive)
                recordPersistenceError(
                    "Couldn’t inspect pending privacy cleanup. Restart Ayna and try again."
                )
                return false
            }
        }
        var spotlightIndexWasCleared = false
        var attachmentSnapshotRecorded = true
        var cleanupProgressPersisted = true
        if privacyMarkersBeforeClear != nil {
            if let attachmentCleanupSnapshotError {
                attachmentSnapshotRecorded = false
                recordPersistenceError(
                    "Conversations were cleared, but attachment cleanup could not be prepared. \(attachmentCleanupSnapshotError)"
                )
            } else if let attachmentCleanupSnapshot {
                do {
                    try store.recordAttachmentCleanupSnapshot(
                        attachmentCleanupSnapshot,
                        for: effectiveMarkerSnapshot
                    )
                } catch {
                    attachmentSnapshotRecorded = false
                    recordPersistenceError(
                        "Conversations were cleared, but attachment cleanup could not be prepared. \(error.localizedDescription)"
                    )
                }
            }
        }
        let spotlightSucceeded: Bool
        if store.isSpotlightCleanupCompleted(for: effectiveMarkerSnapshot) {
            spotlightSucceeded = true
            spotlightIndexWasCleared = true
        } else {
            #if !os(watchOS)
                let spotlightCleanup = scheduleSpotlightIndexCleanupAfterCommittedClear()
                await spotlightCleanup.task.value
                spotlightSucceeded = spotlightCleanup.result.succeeded
                spotlightIndexWasCleared = spotlightSucceeded
            #else
                spotlightSucceeded = true
            #endif
            if spotlightSucceeded {
                do {
                    try store.markSpotlightCleanupCompleted(for: effectiveMarkerSnapshot)
                } catch {
                    cleanupProgressPersisted = false
                    recordPersistenceError(
                        "Conversations were cleared, but Spotlight cleanup progress could not be saved. \(error.localizedDescription)"
                    )
                }
            }
        }
        let summarySucceeded: Bool
        if store.isSummaryCleanupCompleted(for: effectiveMarkerSnapshot) {
            summarySucceeded = true
        } else {
            summarySucceeded = await clearConversationSummariesAfterCommittedClear(
                cleanupToken: effectiveMarkerSnapshot.summaryCleanupToken
            )
            if summarySucceeded {
                do {
                    try store.markSummaryCleanupCompleted(for: effectiveMarkerSnapshot)
                } catch {
                    cleanupProgressPersisted = false
                    recordPersistenceError(
                        "Conversations were cleared, but summary cleanup progress could not be saved. \(error.localizedDescription)"
                    )
                }
            }
        }
        let attachmentCleanupSucceeded: Bool
        if attachmentSnapshotRecorded {
            attachmentCleanupSucceeded = await clearAttachmentsAfterCommittedClear(
                for: effectiveMarkerSnapshot,
                cleanupFenceAlreadyActive: attachmentCleanupFenceActive
            )
        } else {
            releaseAttachmentCleanupFenceIfNeeded(attachmentCleanupFenceActive)
            attachmentCleanupSucceeded = false
        }
        guard spotlightSucceeded, summarySucceeded, attachmentCleanupSucceeded else {
            return spotlightIndexWasCleared
        }
        guard cleanupProgressPersisted else { return spotlightIndexWasCleared }
        do {
            try store.clearPendingPrivacyCleanup(effectiveMarkerSnapshot)
        } catch {
            recordPersistenceError(
                "Conversations were cleared, but the privacy-cleanup marker could not be removed. \(error.localizedDescription)"
            )
        }
        return spotlightIndexWasCleared
    }

    private func releaseAttachmentCleanupFenceIfNeeded(_ fenceIsActive: Bool) {
        if fenceIsActive {
            attachmentCleanupReleaseOperation()
        }
    }

    private func discardClearRollbackState(
        for conversationIds: Set<UUID>,
        generation: UInt64
    ) {
        for conversationId in conversationIds {
            if clearRollbackConversationGenerationById[conversationId] == generation {
                clearRollbackConversationsById.removeValue(forKey: conversationId)
                clearRollbackConversationGenerationById.removeValue(forKey: conversationId)
            }
            if clearRollbackMetadataOnlyGenerationById[conversationId] == generation {
                clearRollbackMetadataOnlyIds.remove(conversationId)
                clearRollbackMetadataOnlyGenerationById.removeValue(forKey: conversationId)
            }
            if clearRollbackMetadataSearchTextGenerationById[conversationId] == generation {
                clearRollbackMetadataSearchTextById.removeValue(forKey: conversationId)
                clearRollbackMetadataSearchTextGenerationById.removeValue(forKey: conversationId)
            }
        }
        clearRollbackSummarySnapshotsByGeneration.removeValue(forKey: generation)
        clearFailureNeedsReload = false
    }

    private func discardManagerReconciliationVersions(through version: UInt64) {
        for (conversationId, deletionVersion) in latestManagerDeletionVersionById
            where deletionVersion <= version
        {
            latestManagerDeletionVersionById.removeValue(forKey: conversationId)
        }
        for (conversationId, recreationVersion) in latestManagerRecreationVersionById
            where recreationVersion <= version
        {
            latestManagerRecreationVersionById.removeValue(forKey: conversationId)
        }
    }

    func createNewConversation(title: String = "New Conversation") {
        let defaultModel = AIService.shared.selectedModel
        let conversation = Conversation(title: title, model: defaultModel)
        conversations.insert(conversation, at: 0)
        updateCacheForInsertion(at: 0)
        save(conversation)
    }

    func insertConversationFromSync(
        _ conversation: Conversation,
        allowsRecreation: Bool = false
    ) {
        invalidateTitleRequest(for: conversation.id)
        if allowsRecreation {
            latestManagerRecreationVersionById[conversation.id] = nextReconciliationVersion()
        }
        conversations.insert(conversation, at: 0)
        updateCacheForInsertion(at: 0)
        save(conversation, allowsRecreation: allowsRecreation)
    }

    /// Start a new conversation with optional model, prompt, and system prompt.
    /// Used by deep links to create a conversation and optionally auto-send a message.
    /// - Parameters:
    ///   - model: The model to use. If nil, uses the currently selected model.
    ///   - prompt: An initial prompt to auto-send. If nil, no message is sent automatically.
    ///   - systemPrompt: A custom system prompt for this conversation. If nil, inherits global.
    /// - Returns: The created conversation.
    @discardableResult
    func startConversation(
        model: String? = nil,
        prompt: String? = nil,
        systemPrompt: String? = nil
    ) -> Conversation {
        let effectiveModel = model ?? AIService.shared.selectedModel

        // Validate model exists
        let availableModels = AIService.shared.customModels
        let validatedModel = availableModels.contains(effectiveModel)
            ? effectiveModel
            : AIService.shared.selectedModel

        var conversation = Conversation(
            title: "New Conversation",
            model: validatedModel
        )

        // Set system prompt mode
        if let systemPrompt, !systemPrompt.isEmpty {
            conversation.systemPromptMode = .custom(systemPrompt)
        }

        // Set pending auto-send prompt (will be picked up by the chat view)
        if let prompt, !prompt.isEmpty {
            conversation.pendingAutoSendPrompt = prompt
        }

        conversations.insert(conversation, at: 0)
        updateCacheForInsertion(at: 0)
        selectedConversationId = conversation.id
        save(conversation)

        logManager(
            "🔗 Started conversation via deep link",
            level: .info,
            metadata: [
                "conversationId": conversation.id.uuidString,
                "model": validatedModel,
                "hasPrompt": "\(prompt != nil)",
                "hasSystemPrompt": "\(systemPrompt != nil)"
            ]
        )

        return conversation
    }

    func deleteConversation(_ conversation: Conversation) {
        if let index = getConversationIndex(for: conversation.id) {
            let id = conversation.id
            invalidateTitleRequest(for: id)
            let rollbackConversation = conversations[index]
            let rollbackIndex = index
            let wasMetadataOnly = metadataOnlyConversationIds.contains(id)
            let rollbackSearchText = metadataSearchTextById[id]
            invalidatePendingPersistence(for: id)
            cancelFullConversationLoad(id)
            conversations.remove(at: index)
            metadataOnlyConversationIds.remove(id)
            metadataSearchTextById.removeValue(forKey: id)
            updateCacheForRemoval(id: id, at: index)
            let deletionVersion = nextManagerDeletionVersion()
            let deletionReconciliationVersion = nextReconciliationVersion()
            let clearGenerationAtDeleteStart = clearConversationsGeneration
            latestManagerDeletionVersionById[id] = deletionReconciliationVersion
            conversationSummaryRemoveOperation(id)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { finishManagerDeletionTask(for: id, version: deletionVersion) }
                do {
                    try await persistenceCoordinator.delete(id)
                    #if !os(watchOS)
                        deindexConversation(
                            id: id,
                            deletionReconciliationVersion: deletionReconciliationVersion
                        )
                    #endif
                } catch {
                    let latestRecreationVersion = latestManagerRecreationVersionById[id] ?? 0
                    let deletionTokenIsStillCurrent = latestManagerDeletionVersionById[id] == deletionReconciliationVersion
                        && deletionReconciliationVersion > latestRecreationVersion
                    if deletionTokenIsStillCurrent {
                        latestManagerDeletionVersionById.removeValue(forKey: id)
                    }
                    logManager(
                        "Conversation deletion left derived data to clean up",
                        level: .error,
                        metadata: ["id": id.uuidString, "error": error.localizedDescription]
                    )
                    finishManagerDeletionTask(for: id, version: deletionVersion)
                    let clearSupersedesDeletion = clearConversationsTask != nil
                        || clearConversationsGeneration > clearGenerationAtDeleteStart
                    if clearSupersedesDeletion {
                        clearFailureNeedsReload = true
                        let activeClearTask = clearConversationsTask
                        Task { @MainActor [weak self] in
                            await activeClearTask?.value
                            guard let self,
                                  let winningConversation = conversationSnapshot(byId: id)
                            else { return }
                            conversationSummaryUpdateOperation(winningConversation)
                        }
                        return
                    }
                    if deletionTokenIsStillCurrent {
                        if let currentIndex = getConversationIndex(for: id) {
                            conversations[currentIndex] = rollbackConversation
                        } else {
                            conversations.insert(
                                rollbackConversation,
                                at: min(rollbackIndex, conversations.count)
                            )
                        }
                        if wasMetadataOnly {
                            metadataOnlyConversationIds.insert(id)
                        }
                        if let rollbackSearchText {
                            metadataSearchTextById[id] = rollbackSearchText
                        }
                        rebuildIndexCache()
                        conversationSummaryUpdateOperation(rollbackConversation)
                        save(rollbackConversation)
                    } else {
                        await reloadConversations()
                        if let winningConversation = conversationSnapshot(byId: id) {
                            conversationSummaryUpdateOperation(winningConversation)
                        }
                    }
                }
            }
            registerManagerDeletionTask(task, for: id, version: deletionVersion)
        }
    }

    func updateConversation(_ conversation: Conversation) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index] = conversation
            save(conversation)
        }
    }

    func renameConversation(_ conversation: Conversation, newTitle: String) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].title = newTitle
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func addMessage(to conversation: Conversation, message: Message) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].addMessage(message)

            // Auto-generate title from first user message
            let autoGenerateTitle = AppPreferences.storage.object(forKey: "autoGenerateTitle") as? Bool ?? true
            let userMessageCount = conversations[index].messages.count(where: { $0.role == .user })
            let currentTitle = conversations[index].title

            if autoGenerateTitle,
               userMessageCount == 1,
               currentTitle == "New Conversation",
               message.role == .user
            {
                generateTitle(for: conversations[index])
            }

            save(conversations[index])
        }
    }

    func updateLastMessage(in conversation: Conversation, content: String) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].updateLastMessage(content)
            save(conversations[index])
        }
    }

    func updateMessage(in conversation: Conversation, messageId: UUID, update: (inout Message) -> Void) {
        if let convIndex = getConversationIndex(for: conversation.id),
           let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        {
            var message = conversations[convIndex].messages[msgIndex]
            update(&message)
            conversations[convIndex].messages[msgIndex] = message
            conversations[convIndex].updatedAt = Date()
            save(conversations[convIndex])
        }
    }

    // MARK: - Safe ID-Based Access

    /// Safely get a conversation by ID. Returns nil if not found.
    func conversation(byId id: UUID) -> Conversation? {
        if metadataOnlyConversationIds.contains(id) {
            scheduleFullConversationLoadIfNeeded(id)
        }

        if let index = getConversationIndex(for: id) {
            return conversations[index]
        }
        return nil
    }

    /// Safely update a message by IDs. Returns true if update succeeded.
    @discardableResult
    func updateMessage(
        conversationId: UUID,
        messageId: UUID,
        update: (inout Message) -> Void
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        var message = conversations[convIndex].messages[msgIndex]
        update(&message)
        conversations[convIndex].messages[msgIndex] = message
        conversations[convIndex].updatedAt = Date()
        return true
    }

    /// Safely append content to a message. Returns true if update succeeded.
    @discardableResult
    func appendToMessage(
        conversationId: UUID,
        messageId: UUID,
        chunk: String
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        conversations[convIndex].messages[msgIndex].content += chunk
        return true
    }

    /// Safely remove a message by IDs. Returns true if removal succeeded.
    @discardableResult
    func removeMessage(
        conversationId: UUID,
        messageId: UUID
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        conversations[convIndex].messages.remove(at: msgIndex)
        conversations[convIndex].updatedAt = Date()
        return true
    }

    /// Safely update a response group status by IDs. Returns true if update succeeded.
    @discardableResult
    func updateResponseGroupStatus(
        conversationId: UUID,
        responseGroupId: UUID,
        messageId: UUID,
        status: ResponseGroupStatus
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              var group = conversations[convIndex].getResponseGroup(responseGroupId)
        else {
            return false
        }
        group.updateStatus(for: messageId, status: status)
        conversations[convIndex].updateResponseGroup(group)
        return true
    }

    func clearMessages(in conversation: Conversation) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].messages.removeAll()
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Edits the content of a user message and marks it as edited.
    /// - Parameters:
    ///   - conversation: The conversation containing the message.
    ///   - messageId: The ID of the message to edit.
    ///   - newContent: The new content for the message.
    /// - Returns: True if the edit was successful, false if the message wasn't found or isn't editable.
    @discardableResult
    func editMessage(in conversation: Conversation, messageId: UUID, newContent: String) -> Bool {
        guard let convIndex = getConversationIndex(for: conversation.id),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId }),
              conversations[convIndex].messages[msgIndex].role == .user
        else {
            logManager(
                "⚠️ Cannot edit message - not found or not a user message",
                level: .default,
                metadata: ["messageId": messageId.uuidString]
            )
            return false
        }

        // Don't edit if content hasn't changed
        guard conversations[convIndex].messages[msgIndex].content != newContent else {
            return true
        }

        // Remove all messages after the edited message to avoid stale responses
        let nextIndex = conversations[convIndex].messages.index(after: msgIndex)
        if nextIndex < conversations[convIndex].messages.endIndex {
            conversations[convIndex].messages.removeSubrange(nextIndex...)
        }

        conversations[convIndex].messages[msgIndex].content = newContent
        conversations[convIndex].messages[msgIndex].isEdited = true
        conversations[convIndex].messages[msgIndex].editedAt = Date()
        conversations[convIndex].updatedAt = Date()
        save(conversations[convIndex])

        logManager(
            "✏️ Message edited",
            level: .info,
            metadata: [
                "conversationId": conversation.id.uuidString,
                "messageId": messageId.uuidString
            ]
        )

        return true
    }

    func updateModel(for conversation: Conversation, model: String) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].model = model
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func updateSystemPromptMode(for conversation: Conversation, mode: SystemPromptMode) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].systemPromptMode = mode
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    // MARK: - Multi-Model Support

    /// Toggles multi-model mode for a conversation
    func setMultiModelEnabled(for conversation: Conversation, enabled: Bool) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].multiModelEnabled = enabled
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Sets the active models for multi-model parallel queries
    func setActiveModels(for conversation: Conversation, models: [String]) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].activeModels = models
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Adds multiple messages and a response group atomically.
    /// This ensures the UI updates once with all data ready, preventing visual glitches
    /// where multi-model responses appear as separate messages briefly.
    func addMultiModelResponse(
        to conversation: Conversation,
        messages: [Message],
        responseGroup: ResponseGroup
    ) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            // Add all messages
            for message in messages {
                conversations[index].messages.append(message)
            }
            // Add the response group
            conversations[index].addResponseGroup(responseGroup)
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Adds a response group to track parallel responses
    func addResponseGroup(to conversation: Conversation, group: ResponseGroup) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].addResponseGroup(group)
            save(conversations[index])
        }
    }

    /// Updates a response group (e.g., when streaming completes)
    func updateResponseGroup(in conversation: Conversation, group: ResponseGroup) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].updateResponseGroup(group)
            save(conversations[index])
        }
    }

    /// Selects a response from a response group, enabling deferred tool execution
    func selectResponse(in conversation: Conversation, groupId: UUID, messageId: UUID) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].selectResponse(in: groupId, messageId: messageId)
            conversations[index].updatedAt = Date()
            save(conversations[index])

            logManager(
                "✅ Selected response in multi-model group",
                level: .info,
                metadata: [
                    "conversationId": conversation.id.uuidString,
                    "groupId": groupId.uuidString,
                    "selectedMessageId": messageId.uuidString
                ]
            )
        }
    }

    /// Gets the effective message history for API requests, filtering out unselected responses
    func getEffectiveHistory(for conversation: Conversation) -> [Message] {
        conversation.getEffectiveHistory()
    }

    /// Checks if a message is part of a response group
    func isPartOfResponseGroup(message: Message, in conversation: Conversation) -> Bool {
        guard let groupId = message.responseGroupId else { return false }
        return conversation.getResponseGroup(groupId) != nil
    }

    /// Gets all responses in a response group
    func getResponsesInGroup(groupId: UUID, in conversation: Conversation) -> [Message] {
        conversation.messages.filter { $0.responseGroupId == groupId }
    }

    /// Checks if a response group has a selection
    func hasSelection(groupId: UUID, in conversation: Conversation) -> Bool {
        conversation.getResponseGroup(groupId)?.hasSelection ?? false
    }

    /// Resolves the effective system prompt for a conversation based on its mode.
    /// - Returns: The system prompt string, or nil if no prompt should be used.
    func effectiveSystemPrompt(for conversation: Conversation) -> String? {
        switch conversation.systemPromptMode {
        case .inheritGlobal:
            let global = AppPreferences.globalSystemPrompt
            return global.isEmpty ? nil : global
        case let .custom(prompt):
            return prompt.isEmpty ? nil : prompt
        case .disabled:
            return nil
        }
    }

    // MARK: - Attach from App Context

    #if os(macOS)
        /// Creates a new conversation with app context from "Attach from App" feature.
        /// - Parameters:
        ///   - appName: The name of the source application
        ///   - windowTitle: The window title (optional)
        ///   - contentType: The type of content extracted
        ///   - content: The extracted content
        ///   - userMessage: The user's question about the content
        /// - Returns: The created conversation
        @discardableResult
        func createConversationWithContext(
            appName: String,
            windowTitle: String?,
            contentType: String,
            content: String,
            userMessage: String
        ) -> Conversation {
            let defaultModel = AIService.shared.selectedModel

            // Build the system message with context
            var systemContent = """
            You have been given context from the user's \(appName) application.
            """

            if let windowTitle, !windowTitle.isEmpty {
                systemContent += "\n\nWindow: \(windowTitle)"
            }

            systemContent += "\nContent Type: \(contentType)"
            systemContent += "\n\n---\n\(content)\n---"
            systemContent += "\n\nAnswer the user's question based on this context."

            // Create conversation with custom system prompt
            var conversation = Conversation(title: "New Conversation", model: defaultModel)
            conversation.systemPromptMode = .custom(systemContent)

            // Add the user message
            let message = Message(role: .user, content: userMessage)
            conversation.addMessage(message)

            // Insert and save
            conversations.insert(conversation, at: 0)
            updateCacheForInsertion(at: 0)
            save(conversation)

            // Select the new conversation
            selectedConversationId = conversation.id

            logManager(
                "✅ Created conversation with app context",
                level: .info,
                metadata: [
                    "appName": appName,
                    "contentType": contentType,
                    "contentLength": "\(content.count)"
                ]
            )

            // Post notification to trigger AI response in the view
            // Delay slightly to allow SwiftUI to instantiate the new MacChatView
            let conversationId = conversation.id
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                NotificationCenter.default.post(
                    name: .sendPendingMessage,
                    object: nil,
                    userInfo: ["conversationId": conversationId]
                )
            }

            return conversation
        }
    #endif

    private func generateTitle(for conversation: Conversation) {
        guard let firstMessage = conversation.messages.first(where: { $0.role == .user }) else {
            return
        }

        // Skip AI title generation for image generation models - use fallback instead
        let modelCapability = AIService.shared.getModelCapability(conversation.model)
        if modelCapability == .imageGeneration {
            // Use simple fallback title for image generation conversations
            let content = firstMessage.content
            let fallbackTitle = String(content.prefix(50))
            renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
            return
        }

        let content = firstMessage.content
        let titleRequestGeneration = beginTitleRequest(for: conversation.id)
        let firstMessageId = firstMessage.id

        // Use AI to generate a concise title using the same model as the conversation
        let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(content.prefix(200))\". Only respond with the title, nothing else."

        let titleMessage = Message(role: .user, content: titlePrompt)

        let accumulator = TitleAccumulator()

        AIService.shared.sendMessage(
            messages: [titleMessage],
            model: conversation.model,
            stream: false,
            tracksCurrentRequest: false,
            onChunk: { chunk in
                Task { await accumulator.append(chunk) }
            },
            onComplete: { [weak self] in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef,
                          self.titleRequestIsCurrent(
                              conversationId: conversation.id,
                              generation: titleRequestGeneration,
                              firstMessageId: firstMessageId
                          ),
                          let currentConversation = self.conversationSnapshot(byId: conversation.id)
                    else { return }
                    // Use the AI-generated title, trimmed and cleaned
                    let accumulatedTitle = await accumulator.getTitle()
                    let cleanTitle = accumulatedTitle
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "\n", with: " ")

                    if !cleanTitle.isEmpty {
                        self.renameConversation(currentConversation, newTitle: cleanTitle)
                    } else {
                        // Fallback to simple title if empty
                        let fallbackTitle = String(content.prefix(50))
                        self.renameConversation(currentConversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                    }
                }
            },
            onError: { [weak self] error in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef,
                          self.titleRequestIsCurrent(
                              conversationId: conversation.id,
                              generation: titleRequestGeneration,
                              firstMessageId: firstMessageId
                          ),
                          let currentConversation = self.conversationSnapshot(byId: conversation.id)
                    else { return }
                    // Fallback to simple title if AI fails
                    self.logManager(
                        "⚠️ Failed to generate AI title",
                        level: .error,
                        metadata: ["error": error.localizedDescription, "conversationId": conversation.id.uuidString]
                    )
                    let fallbackTitle = String(content.prefix(50))
                    self.renameConversation(currentConversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                }
            },
            onReasoning: nil
        )
    }

    private func beginTitleRequest(for conversationId: UUID) -> UInt64 {
        titleRequestGenerationByConversationId[conversationId, default: 0] &+= 1
        return titleRequestGenerationByConversationId[conversationId] ?? 0
    }

    private func invalidateTitleRequest(for conversationId: UUID) {
        titleRequestGenerationByConversationId[conversationId, default: 0] &+= 1
    }

    private func titleRequestIsCurrent(
        conversationId: UUID,
        generation: UInt64,
        firstMessageId: UUID
    ) -> Bool {
        guard titleRequestGenerationByConversationId[conversationId] == generation,
              let currentConversation = conversationSnapshot(byId: conversationId)
        else { return false }
        return currentConversation.messages.first(where: { $0.role == .user })?.id == firstMessageId
    }

    // MARK: - Spotlight Indexing

    #if !os(watchOS)
        private nonisolated static func createSearchableItem(for conversation: Conversation)
            -> CSSearchableItem
        {
            let attributeSet = CSSearchableItemAttributeSet(contentType: .aynaConversation)
            attributeSet.title = conversation.title
            attributeSet.displayName = conversation.title
            attributeSet.contentDescription = conversation.messages.last?.content
            attributeSet.creator = "Ayna"
            attributeSet.kind = "Conversation"
            attributeSet.containerTitle = "Ayna Conversations"
            attributeSet.authorNames = ["Ayna"]
            attributeSet.metadataModificationDate = Date()

            var keywords = ["Ayna", "Chat", "Conversation"]
            keywords.append(contentsOf: conversation.title.components(separatedBy: .whitespacesAndNewlines))
            attributeSet.keywords = keywords

            // Index full content
            let allContent = conversation.messages.map(\.content).joined(separator: "\n")
            attributeSet.textContent = allContent
            attributeSet.contentModificationDate = conversation.updatedAt

            return CSSearchableItem(
                uniqueIdentifier: conversation.id.uuidString,
                domainIdentifier: "com.sertacozercan.ayna.conversation",
                attributeSet: attributeSet
            )
        }

        /// Index a conversation with debouncing to avoid excessive Spotlight updates during streaming.
        /// Uses a 3-second debounce per conversation to coalesce rapid updates.
        private func indexConversation(_ conversation: Conversation) {
            guard spotlightIndexingEnabled else { return }
            let conversationId = conversation.id
            let generation = spotlightIndexGeneration

            indexingDebounceTasks[conversationId]?.cancel()
            indexingDebounceTasks[conversationId] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: indexingDebounceDuration)
                } catch {
                    return
                }

                indexingDebounceTasks.removeValue(forKey: conversationId)
                guard spotlightIndexGeneration == generation,
                      let latestConversation = getConversationIndex(for: conversationId)
                      .map({ conversations[$0] })
                else {
                    return
                }

                enqueueSpotlightIndexing(latestConversation, generation: generation)
            }
        }

        private func enqueueSpotlightIndexing(
            _ conversation: Conversation,
            generation: UInt64
        ) {
            spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                guard let self,
                      await MainActor.run(body: { self.spotlightIndexGeneration == generation })
                else {
                    return
                }

                let item = ConversationManager.createSearchableItem(for: conversation)
                do {
                    try await CSSearchableIndex.default().indexSearchableItems([item])
                } catch {
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .error,
                        message: "❌ Spotlight indexing error",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }

        /// Index a conversation immediately without debouncing.
        /// Used for final saves when streaming completes or conversation is deleted.
        private func indexConversationImmediately(_ conversation: Conversation) {
            guard spotlightIndexingEnabled else { return }
            indexingDebounceTasks[conversation.id]?.cancel()
            indexingDebounceTasks.removeValue(forKey: conversation.id)
            enqueueSpotlightIndexing(conversation, generation: spotlightIndexGeneration)
        }

        private func indexAllConversations(includingMetadataOnly: Bool = false) {
            guard spotlightIndexingEnabled else { return }
            let metadataOnlyIds = metadataOnlyConversationIds
            let conversationsToIndex = if includingMetadataOnly {
                conversations
            } else {
                conversations.filter { !metadataOnlyIds.contains($0.id) }
            }
            let shouldResetIndex = includingMetadataOnly || metadataOnlyIds.isEmpty
            let generation = spotlightIndexGeneration
            let indexOperation = spotlightBatchIndexOperation

            spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                guard let self,
                      await MainActor.run(body: { self.spotlightIndexGeneration == generation })
                else {
                    return
                }

                do {
                    // Metadata-only startup normally preserves an existing rich index. When
                    // pending privacy cleanup just cleared the domain, placeholders must be
                    // republished so surviving conversations remain discoverable.
                    try await indexOperation(conversationsToIndex, shouldResetIndex)

                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .info,
                        message: "✅ Spotlight batch indexing complete",
                        metadata: ["count": "\(conversationsToIndex.count)"]
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .error,
                        message: "❌ Spotlight batch indexing error",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }

        private func deindexConversation(
            id: UUID,
            deletionReconciliationVersion: UInt64
        ) {
            guard spotlightIndexingEnabled else { return }
            let deleteOperation = spotlightDeleteOperation
            indexingDebounceTasks[id]?.cancel()
            indexingDebounceTasks.removeValue(forKey: id)

            spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                guard let self else { return }
                let deletionIsStillCurrent = await MainActor.run {
                    let latestDeletionVersion = self.latestManagerDeletionVersionById[id] ?? 0
                    let latestRecreationVersion = self.latestManagerRecreationVersionById[id] ?? 0
                    return latestDeletionVersion == deletionReconciliationVersion
                        && deletionReconciliationVersion > latestRecreationVersion
                }
                guard deletionIsStillCurrent else {
                    return
                }

                do {
                    try await deleteOperation(id)
                } catch {
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .error,
                        message: "❌ Spotlight deletion error",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }

        private func invalidateSpotlightIndexing() {
            spotlightIndexGeneration &+= 1
            for task in indexingDebounceTasks.values {
                task.cancel()
            }
            indexingDebounceTasks.removeAll()
        }

        private func scheduleSpotlightIndexCleanupAfterCommittedClear()
            -> (task: Task<Void, Never>, result: CleanupResultBox)
        {
            invalidateSpotlightIndexing()
            let generation = spotlightIndexGeneration
            let cleanupOperation = spotlightCleanupOperation
            let result = CleanupResultBox()

            // Queue deletion behind every index submission accepted before the clear.
            // New submissions are queued afterward, so cleared content cannot be republished.
            let task = spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                do {
                    try await cleanupOperation()
                } catch {
                    result.markFailed()
                    await MainActor.run { [weak self] in
                        guard let self, spotlightIndexGeneration == generation else { return }
                        recordPersistenceError(
                            "Conversations were cleared, but Spotlight cleanup failed. \(error.localizedDescription)"
                        )
                        logManager(
                            "Failed to clear Spotlight conversation index",
                            level: .error,
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }
            return (task, result)
        }
    #endif

    nonisolated static func conversationMatchesCurrentSearchText(
        _ conversation: Conversation,
        query: String,
        metadataSearchTextById: [UUID: String]
    ) -> Bool {
        conversation.title.localizedCaseInsensitiveContains(query)
            || (metadataSearchTextById[conversation.id]?.localizedCaseInsensitiveContains(query) ?? false)
            || conversation.messages.contains { message in
                message.content.localizedCaseInsensitiveContains(query)
            }
    }

    func searchConversationsAsync(query: String, conversations: [Conversation]) async
        -> [Conversation]
    {
        guard !query.isEmpty else { return conversations }
        let metadataSearchTextById = metadataSearchTextById
        let metadataOnlyConversationIds = metadataOnlyConversationIds

        return await verifiedSearchResults(
            conversations: conversations,
            query: query,
            metadataSearchTextById: metadataSearchTextById,
            metadataOnlyConversationIds: metadataOnlyConversationIds
        )
    }

    func verifiedSearchResults(
        conversations: [Conversation],
        query: String,
        metadataSearchTextById: [UUID: String],
        metadataOnlyConversationIds: Set<UUID>
    ) async -> [Conversation] {
        var matchingIds: Set<UUID> = []
        var fullTextCandidateIds: Set<UUID> = []

        for conversation in conversations {
            if Self.conversationMatchesCurrentSearchText(
                conversation,
                query: query,
                metadataSearchTextById: metadataSearchTextById
            ) {
                matchingIds.insert(conversation.id)
                continue
            }

            let isMetadataOnly = metadataOnlyConversationIds.contains(conversation.id)
                || conversation.metadataPreview != nil
            if isMetadataOnly {
                fullTextCandidateIds.insert(conversation.id)
            }
        }

        do {
            let fullTextMatches = try await store.conversationIdsMatchingSearch(
                query: query,
                candidateIds: fullTextCandidateIds
            )
            matchingIds.formUnion(fullTextMatches)
        } catch is CancellationError {
            return []
        } catch {
            logManager(
                "Full-text conversation search failed",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
        }

        return conversations.filter { matchingIds.contains($0.id) }
    }

    func searchConversations(query: String) -> [Conversation] {
        guard !query.isEmpty else { return conversations }

        return conversations.filter { conversation in
            Self.conversationMatchesCurrentSearchText(
                conversation,
                query: query,
                metadataSearchTextById: metadataSearchTextById
            )
        }
    }
}

/// Helper actor for thread-safe title generation
private actor TitleAccumulator {
    var title = ""

    func append(_ chunk: String) {
        title += chunk
    }

    func getTitle() -> String {
        title
    }
}
