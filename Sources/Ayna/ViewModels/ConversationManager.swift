//
//  ConversationManager.swift
//  ayna
//
//  Created on 11/2/25.
//

// This legacy coordinator remains in one file while persistence responsibilities are extracted incrementally.
// swiftlint:disable file_length

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
    static let conversationDeleteRolledBack = Notification.Name("conversationDeleteRolledBack")
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

@MainActor
// The manager remains monolithic while persistence responsibilities are extracted incrementally.
// swiftlint:disable:next type_body_length
final class ConversationManager: ObservableObject {
    private static let searchIndexWarmupLimit = 16

    private actor ImmediateSaveOutcome {
        private var wasDurablySaved = false

        func markDurablySaved() {
            wasDurablySaved = true
        }

        func value() -> Bool {
            wasDurablySaved
        }
    }

    @Published var conversations: [Conversation] = []
    @Published private(set) var persistenceErrorMessage: String?
    @Published var selectedConversationId: UUID? {
        didSet {
            selectionRevision &+= 1
            guard selectedConversationId != oldValue else { return }
            if let selectedConversationId {
                scheduleFullConversationLoadIfNeeded(selectedConversationId)
            }
        }
    }

    @Published private(set) var pendingDestructivePersistenceOperations = 0
    @Published private(set) var isConversationStateAuthoritative = false
    @Published private(set) var durableConversationRevision: UInt64 = 0

    static let newConversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let store: any ConversationStoreAdapter
    private let encryptedStore: EncryptedConversationStore?
    private let conversationLoader: @Sendable (UUID) async throws -> Conversation?
    private let conversationMetadataLoader: @Sendable () async throws -> [ConversationMetadata]
    private let usesMetadataLoading: Bool
    private let persistenceCoordinator: ConversationPersistenceCoordinator
    var loadingTask: Task<Void, Never>?
    private var isLoaded = false
    private let saveDebounceDuration: Duration
    private let loadRetryBaseDelay: Duration
    private let destructiveRepairRetryBaseDelay: Duration
    private var loadRetryTask: Task<Void, Never>?
    private var destructiveRepairTasks: [ConversationSnapshotRepairToken: Task<Void, Never>] = [:]
    private var loadRetryAttempt = 0
    private var selectionRevision: UInt64 = 0

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
    private var failedSaveIdsAwaitingFlushObservation: Set<UUID> = []
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

    // Dependency wiring remains centralized until the manager is split into smaller collaborators.
    // swiftlint:disable:next function_body_length
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
        if let conversationSummaryInvalidateOperation {
            self.conversationSummaryInvalidateOperation = conversationSummaryInvalidateOperation
        } else if RuntimeEnvironment.isRunningUnitTests {
            self.conversationSummaryInvalidateOperation = {
                ConversationSummaryClearSnapshot(
                    digest: RecentConversationsDigest(),
                    wasLoaded: false
                )
            }
        } else {
            self.conversationSummaryInvalidateOperation = {
                MemoryContextProvider.shared.invalidateConversationSummariesForClear()
            }
        }
        if let conversationSummaryRestoreOperation {
            self.conversationSummaryRestoreOperation = conversationSummaryRestoreOperation
        } else if RuntimeEnvironment.isRunningUnitTests {
            self.conversationSummaryRestoreOperation = { _ in }
        } else {
            self.conversationSummaryRestoreOperation = { snapshot in
                try await MemoryContextProvider.shared.restoreConversationSummariesAfterFailedClear(snapshot)
            }
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
        if let conversationSummaryRemoveOperation {
            self.conversationSummaryRemoveOperation = conversationSummaryRemoveOperation
        } else if RuntimeEnvironment.isRunningUnitTests {
            self.conversationSummaryRemoveOperation = { _ in }
        } else {
            self.conversationSummaryRemoveOperation = { conversationId in
                MemoryContextProvider.shared.removeConversationSummary(for: conversationId)
            }
        }
        if let conversationSummaryUpdateOperation {
            self.conversationSummaryUpdateOperation = conversationSummaryUpdateOperation
        } else if RuntimeEnvironment.isRunningUnitTests {
            self.conversationSummaryUpdateOperation = { _ in }
        } else {
            self.conversationSummaryUpdateOperation = { conversation in
                MemoryContextProvider.shared.updateConversationSummary(conversation)
            }
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
            saveOperation: saveOperation,
            deleteOperation: deleteOperation,
            clearOperation: clearOperation
        )
        persistenceCoordinator.observeDurableSnapshotChanges { [weak self] in
            self?.durableConversationRevision &+= 1
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

    // MARK: - Persistence

    func save(_ conversation: Conversation, allowsRecreation: Bool = false) {
        if allowsRecreation {
            persistenceRecreationAuthorizationIds.insert(conversation.id)
        }
        let isMetadataBackedSnapshot = isMetadataBackedSnapshot(conversation)
        let activeClearTask = clearConversationsTask
        let activeDeletionTask = managerDeletionTasks[conversation.id]
        let persistenceSequence = advancePersistenceSequence(for: conversation.id)
        let registersSynchronously = activeDeletionTask == nil
            && !isMetadataBackedSnapshot
            && (activeClearTask == nil
                || clearRollbackConversationGenerationById[conversation.id] == nil)

        if registersSynchronously {
            let effectiveAllowsRecreation = persistenceRecreationAuthorizationIds.contains(conversation.id)
            let requiresImmediateSave = persistenceImmediateSaveIds.contains(conversation.id)
            let registeredReceipt: PersistenceReceipt<ConversationSaveResult>?
            if requiresImmediateSave {
                registeredReceipt = persistenceCoordinator.registerImmediateSave(
                    conversation,
                    allowsRecreation: effectiveAllowsRecreation
                )
            } else {
                registeredReceipt = persistenceCoordinator.enqueueSave(
                    conversation,
                    allowsRecreation: effectiveAllowsRecreation
                )
            }

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { finishPersistenceTask(for: conversation.id, sequence: persistenceSequence) }

                if let registeredReceipt {
                    if requiresImmediateSave {
                        do {
                            try await persistenceCoordinator.settleImmediateSave(
                                registeredReceipt,
                                conversationID: conversation.id
                            )
                            await finishSuccessfulImmediateSave(
                                conversation,
                                persistenceSequence: persistenceSequence,
                                allowsRecreation: effectiveAllowsRecreation,
                                outcome: nil
                            )
                        } catch {
                            logManager(
                                "❌ Failed to save conversation immediately",
                                level: .error,
                                metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
                            )
                        }
                        return
                    }

                    if case let .failed(error) = await registeredReceipt.value {
                        if persistenceSequenceById[conversation.id] == persistenceSequence {
                            failedSaveIdsAwaitingFlushObservation.insert(conversation.id)
                        }
                        logManager(
                            "❌ Failed to save conversation",
                            level: .error,
                            metadata: ["id": conversation.id.uuidString, "error": error]
                        )
                    }
                }

                guard persistenceSequenceById[conversation.id] == persistenceSequence else { return }
                if effectiveAllowsRecreation {
                    persistenceRecreationAuthorizationIds.remove(conversation.id)
                }
                #if !os(watchOS)
                    indexConversation(conversation)
                #endif
            }
            persistenceTasksById[conversation.id] = task
            return
        }

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
                persistenceCoordinator.enqueueSave(
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
        startImmediateSave(conversation)
    }

    func saveImmediatelyReportingDurability(
        _ conversation: Conversation
    ) -> Task<Bool, Never> {
        let outcome = ImmediateSaveOutcome()
        let saveTask = startImmediateSave(conversation, outcome: outcome)
        return Task { @MainActor in
            await saveTask.value
            return await outcome.value()
        }
    }

    private func startImmediateSave(
        _ conversation: Conversation,
        outcome: ImmediateSaveOutcome? = nil
    ) -> Task<Void, Never> {
        let isMetadataBackedSnapshot = isMetadataBackedSnapshot(conversation)
        let activeClearTask = clearConversationsTask
        let activeDeletionTask = managerDeletionTasks[conversation.id]
        persistenceImmediateSaveIds.insert(conversation.id)
        let persistenceSequence = advancePersistenceSequence(for: conversation.id)
        let registersSynchronously = activeDeletionTask == nil
            && !isMetadataBackedSnapshot
            && (activeClearTask == nil
                || clearRollbackConversationGenerationById[conversation.id] == nil)
        let registeredReceipt: PersistenceReceipt<ConversationSaveResult>? = if registersSynchronously {
            persistenceCoordinator.registerImmediateSave(
                conversation,
                allowsRecreation: persistenceRecreationAuthorizationIds.contains(conversation.id)
            )
        } else {
            nil
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishPersistenceTask(for: conversation.id, sequence: persistenceSequence) }

            if let registeredReceipt {
                let effectiveAllowsRecreation = persistenceRecreationAuthorizationIds.contains(conversation.id)
                do {
                    try await persistenceCoordinator.settleImmediateSave(
                        registeredReceipt,
                        conversationID: conversation.id
                    )
                    await finishSuccessfulImmediateSave(
                        conversation,
                        persistenceSequence: persistenceSequence,
                        allowsRecreation: effectiveAllowsRecreation,
                        outcome: outcome
                    )
                } catch {
                    logManager(
                        "❌ Failed to save conversation",
                        level: .error,
                        metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
                    )
                }
                return
            }

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
                await finishSuccessfulImmediateSave(
                    conversationToSave,
                    persistenceSequence: persistenceSequence,
                    allowsRecreation: effectiveAllowsRecreation,
                    outcome: outcome
                )
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

    private func finishSuccessfulImmediateSave(
        _ conversation: Conversation,
        persistenceSequence: UInt64,
        allowsRecreation: Bool,
        outcome: ImmediateSaveOutcome?
    ) async {
        if outcome != nil,
           persistenceSequenceById[conversation.id] != persistenceSequence
        {
            await waitForSupersedingImmediatePersistence(
                conversationId: conversation.id,
                supersededSequence: persistenceSequence
            )
            return
        }
        if persistenceSequenceById[conversation.id] == persistenceSequence {
            if allowsRecreation {
                persistenceRecreationAuthorizationIds.remove(conversation.id)
            }
            persistenceImmediateSaveIds.remove(conversation.id)
        }
        #if !os(watchOS)
            indexConversation(conversation)
        #endif
        if let outcome {
            await outcome.markDurablySaved()
        }
    }

    func persistProposedConversation(_ conversation: Conversation) -> Task<ConversationSaveResult, Never> {
        let receipt = persistenceCoordinator.saveProposed(conversation)
        return Task { await receipt.value }
    }

    func commitPersistedConversation(_ conversation: Conversation) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
            updateCacheForInsertion(at: 0)
        }
        metadataOnlyConversationIds.remove(conversation.id)
        metadataSearchTextById.removeValue(forKey: conversation.id)
        conversationSummaryUpdateOperation(conversation)
        #if !os(watchOS)
            indexConversation(conversation)
        #endif
    }

    private func beginDestructivePersistenceOperation(
        _ repairToken: ConversationSnapshotRepairToken
    ) {
        pendingDestructivePersistenceOperations += 1
        registerDestructiveRepairToken(repairToken)
    }

    private func beginUnregisteredDestructivePersistenceOperation() {
        pendingDestructivePersistenceOperations += 1
    }

    private func registerDestructiveRepairToken(
        _ repairToken: ConversationSnapshotRepairToken
    ) {
        let supersededTokens = destructiveRepairTasks.keys.filter {
            $0.isSuperseded(by: repairToken)
        }
        for supersededToken in supersededTokens {
            destructiveRepairTasks.removeValue(forKey: supersededToken)?.cancel()
            finishDestructivePersistenceOperation()
        }
    }

    private func finishDestructivePersistenceOperation() {
        pendingDestructivePersistenceOperations = max(
            0,
            pendingDestructivePersistenceOperations - 1
        )
    }

    private func retainDestructiveBarrierUntilRepairSettles(
        _ repairToken: ConversationSnapshotRepairToken
    ) {
        guard destructiveRepairTasks[repairToken] == nil else { return }

        let coordinator = persistenceCoordinator
        let baseDelay = destructiveRepairRetryBaseDelay
        destructiveRepairTasks[repairToken] = Task { @MainActor [weak self] in
            var retryAttempt = 0
            var retryIfNeeded = false

            while !Task.isCancelled {
                let result = await coordinator.settleCurrentSnapshot(
                    for: repairToken,
                    retryIfNeeded: retryIfNeeded
                )
                guard !Task.isCancelled, let self else { return }

                switch result {
                case .settled, .superseded:
                    guard self.destructiveRepairTasks.removeValue(forKey: repairToken) != nil else {
                        return
                    }
                    self.finishDestructivePersistenceOperation()
                    return
                case .failed:
                    let scale = 1 << min(retryAttempt, 5)
                    retryAttempt += 1
                    do {
                        try await Task.sleep(for: baseDelay * scale)
                    } catch {
                        return
                    }
                    retryIfNeeded = true
                }
            }
        }
    }

    func persistProposedDeletion(_ conversation: Conversation) -> Task<ConversationDeleteResult, Never> {
        persistProposedDeletion(persistenceCoordinator.delete(conversation))
    }

    func persistProposedDeletion(conversationID: UUID) -> Task<ConversationDeleteResult, Never> {
        persistProposedDeletion(persistenceCoordinator.delete(id: conversationID))
    }

    private func persistProposedDeletion(
        _ receipt: DestructivePersistenceReceipt<ConversationDeleteResult>
    ) -> Task<ConversationDeleteResult, Never> {
        beginDestructivePersistenceOperation(receipt.repairToken)
        return Task { @MainActor [weak self] in
            let result = await receipt.value
            guard let self else { return .superseded }
            switch result {
            case .deleted:
                self.finishDestructivePersistenceOperation()
            case .failed, .superseded:
                self.retainDestructiveBarrierUntilRepairSettles(receipt.repairToken)
            }
            return result
        }
    }

    func commitPersistedDeletion(_ conversationID: UUID) {
        let deletionReconciliationVersion = nextReconciliationVersion()
        latestManagerDeletionVersionById[conversationID] = deletionReconciliationVersion
        if let index = getConversationIndex(for: conversationID) {
            conversations.remove(at: index)
            updateCacheForRemoval(id: conversationID, at: index)
        }
        metadataOnlyConversationIds.remove(conversationID)
        metadataSearchTextById.removeValue(forKey: conversationID)
        if selectedConversationId == conversationID {
            selectedConversationId = nil
        }
        conversationSummaryRemoveOperation(conversationID)
        #if !os(watchOS)
            deindexConversation(
                id: conversationID,
                deletionReconciliationVersion: deletionReconciliationVersion
            )
        #endif
    }

    func settlePersistence(for conversationID: UUID) async -> ConversationDurabilityResult {
        await persistenceCoordinator.settleCurrentState(for: conversationID)
    }

    func durableConversationsForSync() -> [Conversation] {
        persistenceCoordinator.durableConversations()
    }

    func waitUntilConversationStateIsAuthoritative() async -> Bool {
        if isConversationStateAuthoritative {
            return true
        }
        for await authoritative in $isConversationStateAuthoritative.values {
            guard !Task.isCancelled else { return false }
            if authoritative {
                return true
            }
        }
        return false
    }

    func waitForSearchIndexWarmup() async {
        while let task = searchIndexWarmupTask {
            await task.value
        }
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
            let excludedFailedSaveIds = failedSaveIdsAwaitingFlushObservation
            failedSaveIdsAwaitingFlushObservation.subtract(excludedFailedSaveIds)
            await persistenceCoordinator.flushPendingSaves(
                excludingUnscheduledConversationIDs: excludedFailedSaveIds
            )

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
        failedSaveIdsAwaitingFlushObservation.remove(conversationId)
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

    // Loading reconciles legacy, metadata-only, and durable snapshots in one transaction.
    // swiftlint:disable:next function_body_length
    private func loadConversations(
        allowingActiveClearGeneration allowedClearGeneration: UInt64? = nil
    ) async {
        let spotlightIndexWasCleared = await completePendingPrivacyCleanupIfNeeded()
        cancelAllFullConversationLoads()
        cancelSearchIndexWarmup()
        #if !os(watchOS)
            invalidateSpotlightIndexing()
        #endif
        conversationLoadGeneration &+= 1
        let loadGeneration = conversationLoadGeneration
        func loadIsCurrent() -> Bool {
            loadGeneration == conversationLoadGeneration
                && (clearConversationsTask == nil
                    || allowedClearGeneration == clearConversationsGeneration)
        }
        let persistenceSequenceAtLoadStart = nextPersistenceSequence
        let persistenceStateAtLoadStart = persistenceCoordinator.reconciliationState()
        guard loadIsCurrent() else {
            return
        }
        let persistingAtLoadStart = persistenceStateAtLoadStart.dirtyIds
            .union(persistenceTasksById.keys)
        let reconciliationVersionAtLoadStart = nextReconciliationMutationVersion
        let deletingAtLoadStart = persistenceStateAtLoadStart.deletingIds
            .union(managerDeletionTasks.keys)

        isConversationStateAuthoritative = false
        if !usesMetadataLoading {
            await consumeCoordinatorLoad(persistenceCoordinator.load())
            return
        }

        do {
            let metadataFromDisk = try await conversationMetadataLoader()
            guard loadIsCurrent() else {
                return
            }

            // Validate and fix models that no longer exist for the in-memory list.
            let usableModels = AIService.shared.usableModels
            let availableModelSet = Set(usableModels)
            let selectedModel = AIService.shared.selectedModel
            let defaultModel = availableModelSet.contains(selectedModel)
                ? selectedModel
                : usableModels.first ?? selectedModel

            let persistenceState = persistenceCoordinator.reconciliationState()
            guard loadIsCurrent() else {
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
                _ = repairUnavailableModels(
                    in: &placeholder,
                    availableModels: availableModelSet,
                    defaultModel: defaultModel
                )
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
            isConversationStateAuthoritative = true
            loadRetryTask?.cancel()
            loadRetryTask = nil
            loadRetryAttempt = 0
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
            guard loadIsCurrent() else { return }
            isConversationStateAuthoritative = false
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
            scheduleLoadRetry()
        }
    }

    private func consumeCoordinatorLoad(
        _ receipt: PersistenceReceipt<ConversationLoadResult>
    ) async {
        switch await receipt.value {
        case let .loaded(loaded):
            loadRetryTask?.cancel()
            loadRetryTask = nil
            loadRetryAttempt = 0
            applyCoordinatorLoad(loaded)
            isLoaded = true
            isConversationStateAuthoritative = true
        case let .failed(error):
            isLoaded = true
            isConversationStateAuthoritative = false
            logManager(
                "❌ Failed to load conversations",
                level: .error,
                metadata: ["error": error]
            )
            scheduleLoadRetry()
        case .superseded:
            isLoaded = true
            isConversationStateAuthoritative = false
            scheduleLoadRetry()
        }
    }

    private func applyCoordinatorLoad(_ loaded: [Conversation]) {
        var repaired = loaded
        let usableModels = AIService.shared.usableModels
        let availableModelSet = Set(usableModels)
        let selectedModel = AIService.shared.selectedModel
        let defaultModel = availableModelSet.contains(selectedModel)
            ? selectedModel
            : usableModels.first ?? selectedModel
        var repairedIds: [UUID] = []

        for index in repaired.indices {
            guard repairUnavailableModels(
                in: &repaired[index],
                availableModels: availableModelSet,
                defaultModel: defaultModel
            ) else { continue }
            repairedIds.append(repaired[index].id)
        }
        repaired.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        cancelAllFullConversationLoads()
        cancelSearchIndexWarmup()
        conversations = repaired
        metadataOnlyConversationIds.removeAll()
        metadataSearchTextById.removeAll()
        if let selectedId = selectedConversationId,
           !conversations.contains(where: { $0.id == selectedId })
        {
            selectedConversationId = nil
        }
        rebuildIndexCache()

        for id in repairedIds {
            guard let conversation = conversation(byId: id) else { continue }
            persistenceCoordinator.apply(conversation, mode: .immediate)
        }

        logManager(
            "✅ Loaded \(conversations.count) conversations",
            level: .info,
            metadata: ["count": "\(conversations.count)"]
        )
        #if !os(watchOS)
            indexAllConversations(includingMetadataOnly: false)
        #endif
    }

    private func scheduleLoadRetry() {
        guard !isConversationStateAuthoritative, loadRetryTask == nil else { return }
        let scale = 1 << min(loadRetryAttempt, 5)
        let delay = loadRetryBaseDelay * scale
        loadRetryAttempt += 1
        loadRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.loadRetryTask = nil
            await self.loadConversations()
        }
    }

    private func repairUnavailableModels(
        in conversation: inout Conversation,
        availableModels: Set<String>,
        defaultModel: String
    ) -> Bool {
        var didRepair = false

        if !availableModels.contains(conversation.model) {
            conversation.model = defaultModel
            didRepair = true
        }

        let supportedActiveModels = conversation.activeModels.filter {
            availableModels.contains($0)
        }
        if supportedActiveModels != conversation.activeModels {
            conversation.activeModels = supportedActiveModels
            didRepair = true
        }
        if conversation.multiModelEnabled, supportedActiveModels.count < 2 {
            conversation.multiModelEnabled = false
            didRepair = true
        }

        return didRepair
    }

    private func scheduleSearchIndexWarmup(for conversationIds: Set<UUID>) {
        cancelSearchIndexWarmup()

        guard let encryptedStore else { return }

        let version = searchIndexWarmupVersion
        let delay = searchIndexWarmupDelay
        searchIndexWarmupTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                try await encryptedStore.warmConversationSearchIndex(candidateIds: conversationIds)
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
            guard let loadedConversation = try await conversationLoader(proposedConversation.id) else {
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

            let usableModels = AIService.shared.usableModels
            let availableModelSet = Set(usableModels)
            let selectedModel = AIService.shared.selectedModel
            let defaultModel = availableModelSet.contains(selectedModel)
                ? selectedModel
                : usableModels.first ?? selectedModel
            let storageConversationWasRepaired = repairUnavailableModels(
                in: &loadedConversation,
                availableModels: availableModelSet,
                defaultModel: defaultModel
            )

            let dirtyIds = persistenceCoordinator.pendingConversationIds()
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
            let mergedConversationWasRepaired = repairUnavailableModels(
                in: &mergedConversation,
                availableModels: availableModelSet,
                defaultModel: defaultModel
            )
            conversations[index] = mergedConversation
            metadataOnlyConversationIds.remove(conversationId)
            metadataSearchTextById.removeValue(forKey: conversationId)
            #if !os(watchOS)
                indexConversation(mergedConversation)
            #endif
            if storageConversationWasRepaired || mergedConversationWasRepaired {
                _ = persistenceCoordinator.enqueueDerivedUpdateIfCurrent(mergedConversation)
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
        loadRetryTask?.cancel()
        loadRetryTask = nil
        while let clearTask = clearConversationsTask {
            await clearTask.value
        }
        await loadConversations()
    }

    @discardableResult
    // Clearing coordinates storage, attachments, summaries, and Spotlight rollback.
    func clearAllConversations() -> Task<Void, Never> { // swiftlint:disable:this function_body_length
        persistenceErrorMessage = nil
        let previousClearTask = clearConversationsTask
        let clearWasAlreadyActive = previousClearTask != nil
        if clearWasAlreadyActive {
            logManager("Merging another clear request into the active clear", level: .info)
        }

        let reconciliationVersionAtClearStart = nextReconciliationMutationVersion
        let privacyMarkersBeforeClear: PrivacyCleanupMarkerSnapshot
        if let encryptedStore {
            do {
                privacyMarkersBeforeClear = try encryptedStore
                    .pendingPrivacyCleanupMarkerSnapshotThrowing()
            } catch {
                recordPersistenceError(
                    "Couldn’t inspect pending privacy cleanup. Restart Ayna and try again."
                )
                return Task {}
            }
        } else {
            privacyMarkersBeforeClear = PrivacyCleanupMarkerSnapshot(markerFileNames: [])
        }
        clearConversationsGeneration &+= 1
        let generation = clearConversationsGeneration
        let attachmentCleanupFencePreparation = beginAttachmentCleanupFence()
        NotificationCenter.default.post(
            name: .conversationHistoryClearStarted,
            object: self
        )

        let stateWasAuthoritative = isConversationStateAuthoritative
        clearFailureNeedsReload = clearFailureNeedsReload || !isLoaded
        let summarySnapshot = conversationSummaryInvalidateOperation()
        clearRollbackSummarySnapshotsByGeneration[generation] = summarySnapshot
        let beforeClear = conversations.map(resolvingInterruptedImageGeneration)
        let selectedBeforeClear = selectedConversationId
        for conversation in beforeClear {
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
        selectedConversationId = nil
        let rollbackSelectionRevision = selectionRevision
        let attachmentCleanupPreparationTask = Task { @MainActor [weak self] in
            await previousClearTask?.value
            guard let self else {
                return ConversationClearPreparationResult.failed(
                    AttachmentStorageError.missingCleanupSnapshot.localizedDescription
                )
            }
            return await prepareAttachmentCleanup(
                fencePreparation: attachmentCleanupFencePreparation
            )
        }
        let receipt = persistenceCoordinator.clear(
            beforeClear,
            attachmentCleanupPreparation: attachmentCleanupPreparationTask
        )
        beginDestructivePersistenceOperation(receipt.repairToken)
        let task = Task { @MainActor [weak self] in
            let attachmentCleanupPreparation = await attachmentCleanupPreparationTask.value
            guard let self else { return }
            let attachmentCleanupSnapshot: AttachmentCleanupSnapshot?
            let attachmentCleanupSnapshotError: String?
            switch attachmentCleanupPreparation {
            case let .prepared(snapshot):
                attachmentCleanupSnapshot = snapshot
                attachmentCleanupSnapshotError = nil
            case let .failed(error):
                attachmentCleanupSnapshot = nil
                attachmentCleanupSnapshotError = error
            }
            let attachmentCleanupFenceActive = attachmentCleanupFencePreparation.isActive
            let clearResult = await receipt.value

            switch clearResult {
            case .cleared, .committedWithCleanupFailure:
                let suppressedConversationIds = Set(
                    clearRollbackConversationGenerationById.compactMap { conversationId, rollbackGeneration in
                        rollbackGeneration <= generation ? conversationId : nil
                    }
                ).union(conversationIds)
                persistenceCoordinator.suppressSavesUntilExplicitRecreation(
                    for: suppressedConversationIds
                )
                finishDestructivePersistenceOperation()
                isConversationStateAuthoritative = true
                NotificationCenter.default.post(
                    name: .conversationHistoryClearCommitted,
                    object: self
                )
                discardClearRollbackState(for: conversationIds, generation: generation)
                await completePostClearPrivacyCleanup(
                    attachmentCleanupSnapshot: attachmentCleanupSnapshot,
                    attachmentCleanupSnapshotError: attachmentCleanupSnapshotError,
                    privacyMarkersBeforeClear: privacyMarkersBeforeClear,
                    attachmentCleanupFenceActive: attachmentCleanupFenceActive
                )
                if case let .committedWithCleanupFailure(error) = clearResult {
                    recordPersistenceError(
                        "Conversations were cleared, but encrypted backup cleanup failed. \(error)"
                    )
                }
                logManager("🧹 Cleared encrypted conversation store", level: .info)
            case let .recoveryRequired(error):
                retainDestructiveBarrierUntilRepairSettles(receipt.repairToken)
                isConversationStateAuthoritative = false
                logManager(
                    "⚠️ Conversation clear requires storage recovery",
                    level: .error,
                    metadata: ["error": error]
                )
                recordPersistenceError(
                    "Conversation storage needs recovery. Restart Ayna before making more changes."
                )
                await restoreClearRollbackInMemory(
                    restored: beforeClear,
                    generation: generation,
                    selectedBeforeClear: selectedBeforeClear,
                    rollbackSelectionRevision: rollbackSelectionRevision
                )
            case let .failed(restored, error):
                retainDestructiveBarrierUntilRepairSettles(receipt.repairToken)
                releaseAttachmentCleanupFenceIfNeeded(attachmentCleanupFenceActive)
                isConversationStateAuthoritative = stateWasAuthoritative
                NotificationCenter.default.post(
                    name: .conversationHistoryClearRolledBack,
                    object: self
                )
                recordPersistenceError("Couldn’t clear conversations. \(error)")
                logManager(
                    "⚠️ Failed to clear conversation store",
                    level: .error,
                    metadata: ["error": error]
                )
                if clearConversationsGeneration == generation {
                    if clearFailureNeedsReload {
                        let summaryRestored = await restoreClearRollbackSummaryIfNeeded(
                            through: generation
                        )
                        guard clearConversationsGeneration == generation else { return }
                        resetClearRollbackState(
                            through: generation,
                            preservingSummaryDigest: !summaryRestored
                        )
                        isLoaded = false
                        await loadConversations(
                            allowingActiveClearGeneration: generation
                        )
                    } else {
                        await restoreClearRollbackInMemory(
                            restored: restored,
                            generation: generation,
                            selectedBeforeClear: selectedBeforeClear,
                            rollbackSelectionRevision: rollbackSelectionRevision
                        )
                    }
                }
            case .superseded:
                finishDestructivePersistenceOperation()
                releaseAttachmentCleanupFenceIfNeeded(attachmentCleanupFenceActive)
            }
            if clearConversationsGeneration == generation {
                switch clearResult {
                case .cleared, .committedWithCleanupFailure:
                    discardManagerReconciliationVersions(
                        through: reconciliationVersionAtClearStart
                    )
                    resetClearRollbackState(through: generation)
                case .failed, .recoveryRequired, .superseded:
                    break
                }
                clearConversationsTask = nil
            }
        }
        clearConversationsTask = task
        return task
    }

    private func restoreClearRollbackInMemory(
        restored: [Conversation],
        generation: UInt64,
        selectedBeforeClear: UUID?,
        rollbackSelectionRevision: UInt64
    ) async {
        let conversationsCreatedDuringClear = conversations
        var mergedById = Dictionary(
            restored.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for (conversationId, conversation) in clearRollbackConversationsById
            where mergedById[conversationId] == nil
        {
            mergedById[conversationId] = conversation
        }
        for conversation in conversationsCreatedDuringClear {
            mergedById[conversation.id] = conversation
        }
        conversations = mergedById.values.sorted { $0.updatedAt > $1.updatedAt }

        metadataOnlyConversationIds = clearRollbackMetadataOnlyIds
        for conversation in conversationsCreatedDuringClear where conversation.metadataPreview == nil {
            metadataOnlyConversationIds.remove(conversation.id)
        }
        metadataSearchTextById = clearRollbackMetadataSearchTextById
        for conversation in conversationsCreatedDuringClear where conversation.metadataPreview == nil {
            metadataSearchTextById.removeValue(forKey: conversation.id)
        }
        rebuildIndexCache()
        isLoaded = true

        let summaryRestored = await restoreClearRollbackSummaryIfNeeded(through: generation)
        guard clearConversationsGeneration == generation else { return }
        resetClearRollbackState(
            through: generation,
            preservingSummaryDigest: !summaryRestored
        )
        if wasSelectedConversationStillCurrent(
            selectedBeforeClear,
            rollbackSelectionRevision: rollbackSelectionRevision
        ) {
            selectedConversationId = selectedBeforeClear
        }
    }

    private func wasSelectedConversationStillCurrent(
        _ selectedConversationId: UUID?,
        rollbackSelectionRevision: UInt64
    ) -> Bool {
        guard let selectedConversationId else { return false }
        return selectionRevision == rollbackSelectionRevision
            && conversations.contains(where: { $0.id == selectedConversationId })
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
    ) async -> ConversationClearPreparationResult {
        guard fencePreparation.isActive else {
            return .failed(
                fencePreparation.errorDescription
                    ?? AttachmentStorageError.missingCleanupSnapshot.localizedDescription
            )
        }
        do {
            let snapshot = try await attachmentCleanupSnapshotOperation()
            return .prepared(snapshot)
        } catch {
            return .failed(error.localizedDescription)
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
        guard let encryptedStore else {
            releaseAttachmentCleanupFenceIfNeeded(cleanupFenceAlreadyActive)
            return true
        }
        let cleanupSnapshot: AttachmentCleanupSnapshot
        var cleanupFenceActive = cleanupFenceAlreadyActive
        do {
            switch encryptedStore.attachmentCleanupPlan(for: markerSnapshot) {
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
            try encryptedStore.markAttachmentCleanupCompleted(for: markerSnapshot)
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
        guard let encryptedStore else { return false }
        let markerSnapshot: PrivacyCleanupMarkerSnapshot
        do {
            markerSnapshot = try encryptedStore.pendingPrivacyCleanupMarkerSnapshotThrowing()
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
        guard let encryptedStore else {
            releaseAttachmentCleanupFenceIfNeeded(attachmentCleanupFenceActive)
            return false
        }
        let effectiveMarkerSnapshot: PrivacyCleanupMarkerSnapshot
        if let suppliedMarkerSnapshot = markerSnapshot {
            effectiveMarkerSnapshot = suppliedMarkerSnapshot
        } else {
            do {
                effectiveMarkerSnapshot = try encryptedStore.pendingPrivacyCleanupMarkerSnapshotThrowing()
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
                    try encryptedStore.recordAttachmentCleanupSnapshot(
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
        if encryptedStore.isSpotlightCleanupCompleted(for: effectiveMarkerSnapshot) {
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
                    try encryptedStore.markSpotlightCleanupCompleted(for: effectiveMarkerSnapshot)
                } catch {
                    cleanupProgressPersisted = false
                    recordPersistenceError(
                        "Conversations were cleared, but Spotlight cleanup progress could not be saved. \(error.localizedDescription)"
                    )
                }
            }
        }
        let summarySucceeded: Bool
        if encryptedStore.isSummaryCleanupCompleted(for: effectiveMarkerSnapshot) {
            summarySucceeded = true
        } else {
            summarySucceeded = await clearConversationSummariesAfterCommittedClear(
                cleanupToken: effectiveMarkerSnapshot.summaryCleanupToken
            )
            if summarySucceeded {
                do {
                    try encryptedStore.markSummaryCleanupCompleted(for: effectiveMarkerSnapshot)
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
            try encryptedStore.clearPendingPrivacyCleanup(effectiveMarkerSnapshot)
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

    @discardableResult
    func deleteConversation(_ conversation: Conversation) -> Task<ConversationDeleteResult, Never>? {
        guard let index = getConversationIndex(for: conversation.id) else { return nil }

        let current = conversations[index]
        let id = current.id
        let wasSelected = selectedConversationId == id
        let wasMetadataOnly = metadataOnlyConversationIds.contains(id)
        let rollbackSearchText = metadataSearchTextById[id]
        let rollbackSnapshot = resolvingInterruptedImageGeneration(in: current)
        let deletionReconciliationVersion = nextReconciliationVersion()
        latestManagerDeletionVersionById[id] = deletionReconciliationVersion

        invalidateTitleRequest(for: id)
        invalidatePendingPersistence(for: id)
        cancelFullConversationLoad(id)

        let receipt = persistenceCoordinator.delete(rollbackSnapshot)
        beginDestructivePersistenceOperation(receipt.repairToken)

        conversations.remove(at: index)
        metadataOnlyConversationIds.remove(id)
        metadataSearchTextById.removeValue(forKey: id)
        updateCacheForRemoval(id: id, at: index)
        conversationSummaryRemoveOperation(id)
        if wasSelected {
            selectedConversationId = nil
        }
        let rollbackSelectionRevision = selectionRevision

        return Task { @MainActor [weak self] in
            let result = await receipt.value
            guard let self else { return .superseded }

            switch result {
            case .deleted:
                self.finishDestructivePersistenceOperation()
                #if !os(watchOS)
                    self.deindexConversation(
                        id: id,
                        deletionReconciliationVersion: deletionReconciliationVersion
                    )
                #endif
            case let .failed(restored, error):
                self.retainDestructiveBarrierUntilRepairSettles(receipt.repairToken)
                if self.latestManagerDeletionVersionById[id] == deletionReconciliationVersion {
                    self.latestManagerDeletionVersionById.removeValue(forKey: id)
                }
                guard let restored else {
                    self.logManager(
                        "Failed to delete conversation without a rollback snapshot",
                        level: .error,
                        metadata: ["id": id.uuidString, "error": error]
                    )
                    return result
                }
                if self.getConversationIndex(for: id) == nil {
                    let insertionIndex = min(index, self.conversations.count)
                    self.conversations.insert(restored, at: insertionIndex)
                    self.updateCacheForInsertion(at: insertionIndex)
                    if wasMetadataOnly {
                        self.metadataOnlyConversationIds.insert(id)
                    }
                    if let rollbackSearchText {
                        self.metadataSearchTextById[id] = rollbackSearchText
                    }
                    self.conversationSummaryUpdateOperation(restored)
                    var restoredSelection = false
                    if wasSelected, self.selectionRevision == rollbackSelectionRevision {
                        self.selectedConversationId = id
                        restoredSelection = true
                    }
                    #if !os(watchOS)
                        self.indexConversation(restored)
                    #endif
                    if restoredSelection {
                        NotificationCenter.default.post(
                            name: .conversationDeleteRolledBack,
                            object: nil,
                            userInfo: ["conversationId": id]
                        )
                    }
                }
                self.logManager(
                    "Failed to delete conversation; restored it in the UI",
                    level: .error,
                    metadata: ["id": id.uuidString, "error": error]
                )
            case .superseded:
                self.retainDestructiveBarrierUntilRepairSettles(receipt.repairToken)
            }
            return result
        }
    }

    private func resolvingInterruptedImageGeneration(in conversation: Conversation) -> Conversation {
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

    @discardableResult
    func updateMessage(
        in conversation: Conversation,
        messageId: UUID,
        update: (inout Message) -> Void
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversation.id),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        var message = conversations[convIndex].messages[msgIndex]
        update(&message)
        conversations[convIndex].messages[msgIndex] = message
        conversations[convIndex].updatedAt = Date()
        save(conversations[convIndex])
        return true
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
        conversations[convIndex].updatedAt = Date()
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
            requestLane: .background,
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

        guard let encryptedStore else {
            return conversations.filter { matchingIds.contains($0.id) }
        }

        do {
            let fullTextMatches = try await encryptedStore.conversationIdsMatchingSearch(
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
