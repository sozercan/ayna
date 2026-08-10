//
//  ConversationPersistenceCoordinator.swift
//  ayna
//
//  Created on 11/24/25.
//

import Foundation
import OSLog

protocol ConversationStoreAdapter: Sendable {
    func loadConversations() async throws -> [Conversation]
    func save(_ conversation: Conversation) async throws
    func delete(_ conversationID: UUID) async throws
    func clearConversations() async throws
    func clearConversations(attachmentCleanupSnapshot: AttachmentCleanupSnapshot?) async throws
}

extension ConversationStoreAdapter {
    func clearConversations(attachmentCleanupSnapshot _: AttachmentCleanupSnapshot?) async throws {
        try await clearConversations()
    }
}

extension EncryptedConversationStore: ConversationStoreAdapter {
    func clearConversations() async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try clear()
        }.value
    }

    func clearConversations(attachmentCleanupSnapshot: AttachmentCleanupSnapshot?) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try clear(attachmentCleanupSnapshot: attachmentCleanupSnapshot)
        }.value
    }
}

struct ConversationPersistenceReconciliationState: Sendable {
    let dirtyIds: Set<UUID>
    let deletingIds: Set<UUID>
}

private final class OperationOverridingConversationStore: ConversationStoreAdapter, @unchecked Sendable {
    private let base: any ConversationStoreAdapter
    private let saveOperation: (@Sendable (Conversation) async throws -> Void)?
    private let deleteOperation: (@Sendable (UUID) async throws -> Void)?
    private let clearOperation: (@Sendable () throws -> Void)?

    init(
        base: any ConversationStoreAdapter,
        saveOperation: (@Sendable (Conversation) async throws -> Void)?,
        deleteOperation: (@Sendable (UUID) async throws -> Void)?,
        clearOperation: (@Sendable () throws -> Void)?
    ) {
        self.base = base
        self.saveOperation = saveOperation
        self.deleteOperation = deleteOperation
        self.clearOperation = clearOperation
    }

    func loadConversations() async throws -> [Conversation] {
        try await base.loadConversations()
    }

    func save(_ conversation: Conversation) async throws {
        if let saveOperation {
            try await saveOperation(conversation)
        } else {
            try await base.save(conversation)
        }
    }

    func delete(_ conversationID: UUID) async throws {
        if let deleteOperation {
            try await deleteOperation(conversationID)
        } else {
            try await base.delete(conversationID)
        }
    }

    func clearConversations() async throws {
        if let clearOperation {
            try clearOperation()
        } else {
            try await base.clearConversations()
        }
    }

    func clearConversations(attachmentCleanupSnapshot: AttachmentCleanupSnapshot?) async throws {
        if let clearOperation {
            try clearOperation()
        } else {
            try await base.clearConversations(attachmentCleanupSnapshot: attachmentCleanupSnapshot)
        }
    }
}

private struct ConversationPersistenceCompatibilityError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum ConversationSaveMode: Sendable { case coalesced, immediate }

enum ConversationSaveResult: Equatable, Sendable {
    case saved
    case failed(String)
    case superseded
}

struct PersistenceReceipt<Value: Sendable>: Sendable {
    fileprivate let task: Task<Value, Never>
    fileprivate let reconcile: (@MainActor @Sendable (Value) -> Value)?

    fileprivate init(
        task: Task<Value, Never>,
        reconcile: (@MainActor @Sendable (Value) -> Value)? = nil
    ) {
        self.task = task
        self.reconcile = reconcile
    }

    @MainActor
    var value: Value {
        get async {
            let settled = await task.value
            return reconcile?(settled) ?? settled
        }
    }
}

@MainActor
private final class PersistenceAttemptErrorBox {
    var error: (any Error)?
}

/// Opaque identity for the repair responsibility created by a destructive operation.
struct ConversationSnapshotRepairToken: Hashable, Sendable {
    fileprivate enum Kind: Hashable, Sendable {
        case delete(UUID)
        case clear
    }

    fileprivate let operationToken: UInt64
    fileprivate let kind: Kind

    func isSuperseded(by newer: Self) -> Bool {
        guard operationToken < newer.operationToken else { return false }
        switch (kind, newer.kind) {
        case (_, .clear):
            return true
        case let (.delete(id), .delete(newerID)):
            return id == newerID
        case (.clear, .delete):
            return false
        }
    }
}

/// Whether the current repair responsibility is durable, retryable, or obsolete.
enum ConversationSnapshotSettlementResult: Equatable, Sendable {
    case settled
    case failed
    case superseded
}

/// A prompt operation receipt plus the token used to settle any compensating repair.
struct DestructivePersistenceReceipt<Value: Sendable>: Sendable {
    fileprivate let receipt: PersistenceReceipt<Value>
    let repairToken: ConversationSnapshotRepairToken
    fileprivate let attemptErrorProvider: @MainActor @Sendable () -> (any Error)?

    fileprivate init(
        receipt: PersistenceReceipt<Value>,
        repairToken: ConversationSnapshotRepairToken,
        attemptErrorProvider: @escaping @MainActor @Sendable () -> (any Error)? = { nil }
    ) {
        self.receipt = receipt
        self.repairToken = repairToken
        self.attemptErrorProvider = attemptErrorProvider
    }

    @MainActor
    var value: Value {
        get async {
            await receipt.value
        }
    }

    @MainActor
    fileprivate var attemptError: (any Error)? {
        attemptErrorProvider()
    }
}

enum ConversationLoadResult: Equatable, Sendable {
    case loaded([Conversation]), failed(String), superseded
}

enum ConversationDeleteResult: Equatable, Sendable {
    case deleted, failed(Conversation?, String), superseded
}

enum ConversationClearResult: Equatable, Sendable {
    case cleared
    case committedWithCleanupFailure(String)
    case failed([Conversation], String)
    case recoveryRequired(String)
    case superseded
}

enum ConversationClearPreparationResult: Sendable {
    case prepared(AttachmentCleanupSnapshot)
    case failed(String)
}

enum ConversationDurabilityResult: Equatable, Sendable {
    case saved
    case deleted
    case failed
}

@MainActor
// swiftlint:disable:next type_body_length
final class ConversationPersistenceCoordinator {
    private enum DesiredState: Sendable { case saved(Conversation), deleted }

    private struct DirtyIntent {
        let token: UInt64
        let root: UInt64
        let repairRoot: UInt64?
        let desired: DesiredState
        let rollback: Conversation?
        var isScheduled: Bool
    }

    /// A proposal chain shares the durable state from before any uncommitted proposal wrote.
    private struct ProposedSaveIntent {
        let token: UInt64
        let chainRoot: UInt64
        var priorDurable: DesiredState?
        let rollback: Conversation?
    }

    private struct ClearLayer {
        let token: UInt64
        let changes: [UUID: DesiredState]
    }

    private struct CompatibilityClearOperation {
        let generation: UInt64
        let task: Task<ConversationClearResult, Never>
        let rollbackSnapshot: [UUID: Conversation]
    }

    private struct CompatibilityClearObservation {
        let generation: UInt64
        let task: Task<ConversationClearResult, Never>
    }

    private enum SnapshotRepairStatus {
        case settled
        case pending(isScheduled: Bool)
        case superseded
    }

    private let store: any ConversationStoreAdapter
    private let debounceDuration: Duration
    private var durableSnapshotObserver: (@MainActor @Sendable () -> Void)?

    private var snapshot: [UUID: Conversation] = [:]
    private var storageSnapshot: [UUID: Conversation] = [:]
    private var dirty: [UUID: DirtyIntent] = [:]
    private var proposedSaves: [UUID: ProposedSaveIntent] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var outstandingByRoot: [UInt64: Int] = [:]

    private var nextTokenValue: UInt64 = 0
    private var latestLoadToken: UInt64 = 0
    private var latestRequestedLoadToken: UInt64 = 0
    private var latestClearToken: UInt64 = 0
    private var clearLayers: [ClearLayer] = []

    private var rewriteToken: UInt64?
    private var rewriteRoot: UInt64?
    private var rewriteScheduledToken: UInt64?
    private var rewriteCoveredTokens: [UUID: UInt64] = [:]
    private var repairDeletedIDs: Set<UUID> = []

    // Compatibility state for the pre-reliability coordinator API. New app code uses
    // receipts below; these fields keep the existing performance regression suite and
    // lazy-hydration manager behavior source-compatible during the transition.
    private var compatibilitySuppressedSaveIDs: Set<UUID> = []
    private var compatibilityDeletingIDs: Set<UUID> = []
    private var compatibilityDeletionGenerations: [UUID: UInt64] = [:]
    private var compatibilityDeletionRollbacks: [UUID: Conversation] = [:]
    private var compatibilityClearGeneration: UInt64 = 0
    private var compatibilityActiveClearCount = 0
    private var compatibilityActiveClearOperation: CompatibilityClearOperation?
    // Retain the newest result after completion so waiters on an older overlapping clear can observe it.
    private var compatibilityLatestClearObservation: CompatibilityClearObservation?

    private var ioTail = Task { @MainActor in }

    init(
        store: any ConversationStoreAdapter = EncryptedConversationStore.shared,
        debounceDuration: Duration = .milliseconds(200),
        saveOperation: (@Sendable (Conversation) async throws -> Void)? = nil,
        deleteOperation: (@Sendable (UUID) async throws -> Void)? = nil,
        clearOperation: (@Sendable () throws -> Void)? = nil
    ) {
        if saveOperation != nil || deleteOperation != nil || clearOperation != nil {
            self.store = OperationOverridingConversationStore(
                base: store,
                saveOperation: saveOperation,
                deleteOperation: deleteOperation,
                clearOperation: clearOperation
            )
        } else {
            self.store = store
        }
        self.debounceDuration = debounceDuration
    }

    func observeDurableSnapshotChanges(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) {
        durableSnapshotObserver = observer
    }

    func durableConversations() -> [Conversation] {
        ordered(storageSnapshot)
    }

    // MARK: - Compatibility API

    @discardableResult
    func enqueueSave(
        _ conversation: Conversation,
        allowsRecreation: Bool = false
    ) -> PersistenceReceipt<ConversationSaveResult>? {
        if compatibilitySuppressedSaveIDs.contains(conversation.id) {
            guard allowsRecreation else { return nil }
            compatibilitySuppressedSaveIDs.remove(conversation.id)
        }
        return apply(conversation, mode: .coalesced)
    }

    func suppressSavesUntilExplicitRecreation(for conversationIDs: Set<UUID>) {
        compatibilitySuppressedSaveIDs.formUnion(conversationIDs)
    }

    func saveImmediately(
        _ conversation: Conversation,
        allowsRecreation: Bool = false
    ) async throws {
        let receipt = registerImmediateSave(
            conversation,
            allowsRecreation: allowsRecreation
        )
        try await settleImmediateSave(receipt, conversationID: conversation.id)
    }

    func registerImmediateSave(
        _ conversation: Conversation,
        allowsRecreation: Bool = false
    ) -> PersistenceReceipt<ConversationSaveResult> {
        if compatibilitySuppressedSaveIDs.contains(conversation.id) {
            guard allowsRecreation else {
                return PersistenceReceipt(task: Task { .superseded })
            }
            compatibilitySuppressedSaveIDs.remove(conversation.id)
        }
        return apply(conversation, mode: .immediate)
            ?? PersistenceReceipt(task: Task { .superseded })
    }

    func settleImmediateSave(
        _ receipt: PersistenceReceipt<ConversationSaveResult>,
        conversationID: UUID
    ) async throws {
        switch await receipt.value {
        case .saved:
            return
        case .superseded:
            guard await settleCurrentState(for: conversationID) != .failed else {
                throw ConversationPersistenceCompatibilityError(
                    message: "Failed to settle the latest conversation state"
                )
            }
        case let .failed(message):
            throw ConversationPersistenceCompatibilityError(message: message)
        }
    }

    func enqueueDerivedUpdateIfCurrent(_ conversation: Conversation) -> Bool {
        guard dirty[conversation.id] == nil,
              proposedSaves[conversation.id] == nil,
              !compatibilitySuppressedSaveIDs.contains(conversation.id)
        else {
            return false
        }
        apply(conversation, mode: .coalesced)
        return true
    }

    func delete(_ conversationID: UUID) async throws {
        compatibilityDeletionGenerations[conversationID, default: 0] &+= 1
        let generation = compatibilityDeletionGenerations[conversationID] ?? 0
        compatibilityDeletingIDs.insert(conversationID)
        compatibilitySuppressedSaveIDs.insert(conversationID)

        let activeClear = compatibilityActiveClearOperation
        var rollback = compatibilityDeletionRollbacks[conversationID]
            ?? snapshot[conversationID]
            ?? activeClear?.rollbackSnapshot[conversationID]
        if let rollback {
            compatibilityDeletionRollbacks[conversationID] = rollback
        }

        if let activeClear {
            var observedClearGeneration = activeClear.generation
            var clearResult = await activeClear.task.value
            guard compatibilityDeletionGenerations[conversationID] == generation else {
                throw CancellationError()
            }

            while let newerClear = compatibilityLatestClearObservation,
                  newerClear.generation > observedClearGeneration
            {
                observedClearGeneration = newerClear.generation
                clearResult = await newerClear.task.value
                guard compatibilityDeletionGenerations[conversationID] == generation else {
                    throw CancellationError()
                }
            }

            rollback = compatibilityDeletionRollbacks[conversationID] ?? rollback
            switch clearResult {
            case .cleared, .committedWithCleanupFailure:
                let hasPostClearState = snapshot[conversationID] != nil
                    || storageSnapshot[conversationID] != nil
                    || dirty[conversationID] != nil
                    || proposedSaves[conversationID] != nil
                guard hasPostClearState else {
                    compatibilityDeletingIDs.remove(conversationID)
                    compatibilityDeletionRollbacks.removeValue(forKey: conversationID)
                    return
                }
            case .failed, .recoveryRequired, .superseded:
                break
            }
        }

        let deletion = delete(id: conversationID, rollback: rollback)
        let result = await deletion.value
        let attemptError = deletion.attemptError
        let isCurrentRequest = compatibilityDeletionGenerations[conversationID] == generation
        if isCurrentRequest {
            compatibilityDeletingIDs.remove(conversationID)
            compatibilityDeletionRollbacks.removeValue(forKey: conversationID)
        }

        switch result {
        case .deleted:
            return
        case .superseded:
            if let attemptError {
                throw attemptError
            }
            guard isCurrentRequest else {
                throw CancellationError()
            }
            return
        case let .failed(_, message):
            if rollback != nil {
                _ = await settleCurrentSnapshot(for: deletion.repairToken)
            }
            if compatibilityDeletionGenerations[conversationID] == generation {
                compatibilitySuppressedSaveIDs.remove(conversationID)
            }
            if let attemptError {
                throw attemptError
            }
            throw ConversationPersistenceCompatibilityError(message: message)
        }
    }

    func clearAll(
        suppressing conversationIDs: Set<UUID>,
        attachmentCleanupSnapshot: AttachmentCleanupSnapshot? = nil
    ) async throws {
        compatibilityClearGeneration &+= 1
        let generation = compatibilityClearGeneration
        compatibilityActiveClearCount += 1
        let newlySuppressedIDs = conversationIDs.subtracting(compatibilitySuppressedSaveIDs)
        compatibilitySuppressedSaveIDs.formUnion(conversationIDs)
        let conversations = orderedSnapshot()
        let receipt = makeClearReceipt(
            conversations: conversations,
            attachmentCleanupSnapshot: attachmentCleanupSnapshot
        )
        let task = Task { @MainActor in
            await receipt.value
        }
        compatibilityActiveClearOperation = CompatibilityClearOperation(
            generation: generation,
            task: task,
            rollbackSnapshot: dictionary(from: conversations)
        )
        compatibilityLatestClearObservation = CompatibilityClearObservation(
            generation: generation,
            task: task
        )
        defer {
            compatibilityActiveClearCount -= 1
            if compatibilityActiveClearOperation?.generation == generation {
                compatibilityActiveClearOperation = nil
            }
        }

        let result = await task.value
        switch result {
        case .cleared, .committedWithCleanupFailure, .superseded:
            return
        case let .recoveryRequired(message):
            throw ConversationPersistenceCompatibilityError(message: message)
        case let .failed(_, message):
            compatibilitySuppressedSaveIDs.subtract(newlySuppressedIDs)
            throw ConversationPersistenceCompatibilityError(message: message)
        }
    }

    func deletingConversationIds() -> Set<UUID> {
        compatibilityDeletingIDs
    }

    func isDeleting(_ conversationID: UUID) -> Bool {
        compatibilityDeletingIDs.contains(conversationID)
    }

    func deletionGeneration(for conversationID: UUID) -> UInt64 {
        compatibilityDeletionGenerations[conversationID] ?? 0
    }

    func isClearing() -> Bool {
        compatibilityActiveClearCount > 0
    }

    func clearGeneration() -> UInt64 {
        compatibilityClearGeneration
    }

    func flushPendingSaves(
        excludingUnscheduledConversationIDs: Set<UUID> = []
    ) async {
        await flush(
            excludingUnscheduledConversationIDs: excludingUnscheduledConversationIDs
        ).value
    }

    func pendingConversationIds() -> Set<UUID> {
        Set(dirty.keys).union(proposedSaves.keys)
    }

    func reconciliationState() -> ConversationPersistenceReconciliationState {
        ConversationPersistenceReconciliationState(
            dirtyIds: pendingConversationIds(),
            deletingIds: compatibilityDeletingIDs
        )
    }

    @discardableResult
    func apply(
        _ conversation: Conversation,
        mode: ConversationSaveMode = .coalesced
    ) -> PersistenceReceipt<ConversationSaveResult>? {
        let token = nextToken()
        let id = conversation.id
        // A normal edit refines the current desired state; it does not discharge an
        // inherited destructive repair responsibility.
        let repairRoot = dirty[id]?.repairRoot
        let root = repairRoot ?? token

        proposedSaves.removeValue(forKey: id)
        snapshot[id] = conversation
        repairDeletedIDs.remove(id)
        cancelDebounce(for: id)
        dirty[id] = DirtyIntent(
            token: token,
            root: root,
            repairRoot: repairRoot,
            desired: .saved(conversation),
            rollback: nil,
            isScheduled: false
        )

        if mode == .immediate || debounceDuration <= .zero {
            return activateSave(id: id, token: token)
        }
        ensureRewriteScheduled()
        if rewriteCoveredTokens[id] == token {
            return nil
        }
        scheduleDebounce(id: id, token: token)
        return nil
    }

    func saveProposed(_ conversation: Conversation) -> PersistenceReceipt<ConversationSaveResult> {
        let token = nextToken()
        let id = conversation.id
        let priorProposal = proposedSaves[id]

        let rollback: Conversation? = if let rollback = priorProposal?.rollback {
            rollback
        } else if let intent = dirty[id], case .deleted = intent.desired {
            intent.rollback
        } else {
            nil
        }

        cancelDebounce(for: id)
        proposedSaves[id] = ProposedSaveIntent(
            token: token,
            chainRoot: priorProposal?.chainRoot ?? token,
            priorDurable: priorProposal?.priorDurable,
            rollback: rollback
        )

        let chainRoot = priorProposal?.chainRoot ?? token
        let store = store
        let physical: PersistenceReceipt<ConversationSaveResult> = appendOperation(root: token) { [weak self] in
            self?.capturePriorDurableState(for: id, chainRoot: chainRoot)
            do {
                try await store.save(conversation)
                guard let self else { return .superseded }
                self.storageSnapshot[id] = conversation
                self.recordDurableSnapshotChange()
                return self.finishProposedSave(conversation, token: token, error: nil)
            } catch {
                guard let self else { return .superseded }
                let description = error.localizedDescription
                let compensationError = await self.compensateFailedProposedSave(id: id, token: token)
                return self.finishProposedSave(
                    conversation,
                    token: token,
                    error: description,
                    compensationError: compensationError
                )
            }
        }
        return PersistenceReceipt(task: physical.task) { [weak self] result in
            self?.reconcileProposedSave(result, conversation: conversation, token: token) ?? .superseded
        }
    }

    func load() -> PersistenceReceipt<ConversationLoadResult> {
        let token = nextToken()
        latestLoadToken = token
        latestRequestedLoadToken = token
        let store = store

        let physical: PersistenceReceipt<ConversationLoadResult> = appendOperation(root: token) { [weak self] in
            do {
                let conversations = try await store.loadConversations()
                guard let self else { return .superseded }
                let isLatestRequestedLoad = self.latestRequestedLoadToken == token
                let result = self.finishLoad(conversations, token: token)
                if isLatestRequestedLoad {
                    self.storageSnapshot = self.dictionary(from: conversations)
                    if case .loaded = result {
                        self.recordDurableSnapshotChange()
                    }
                }
                return result
            } catch {
                guard let self, self.latestLoadToken == token else { return .superseded }
                self.log("❌ Failed to load conversations", level: .error, metadata: ["error": error.localizedDescription])
                return .failed(error.localizedDescription)
            }
        }
        return PersistenceReceipt(task: physical.task) { [weak self] result in
            self?.reconcileLoad(result, token: token) ?? .superseded
        }
    }

    func delete(_ conversation: Conversation) -> DestructivePersistenceReceipt<ConversationDeleteResult> {
        delete(id: conversation.id, rollback: conversation)
    }

    func delete(id: UUID) -> DestructivePersistenceReceipt<ConversationDeleteResult> {
        delete(id: id, rollback: nil)
    }

    private func delete(
        id: UUID,
        rollback: Conversation?
    ) -> DestructivePersistenceReceipt<ConversationDeleteResult> {
        let token = nextToken()
        let attemptErrorBox = PersistenceAttemptErrorBox()

        proposedSaves.removeValue(forKey: id)
        snapshot.removeValue(forKey: id)
        cancelDebounce(for: id)
        dirty[id] = DirtyIntent(
            token: token,
            root: token,
            repairRoot: token,
            desired: .deleted,
            rollback: rollback,
            isScheduled: false
        )
        ensureRewriteScheduled()

        let physical = activateDelete(
            id: id,
            token: token,
            attemptErrorBox: attemptErrorBox
        ) ?? PersistenceReceipt(
            task: Task { .superseded }
        )
        let receipt = PersistenceReceipt(task: physical.task) { [weak self] result in
            self?.reconcileDelete(result, id: id, token: token) ?? .superseded
        }
        return DestructivePersistenceReceipt(
            receipt: receipt,
            repairToken: ConversationSnapshotRepairToken(
                operationToken: token,
                kind: .delete(id)
            ),
            attemptErrorProvider: { attemptErrorBox.error }
        )
    }

    func clear(_ conversations: [Conversation]) -> DestructivePersistenceReceipt<ConversationClearResult> {
        makeClearReceipt(conversations: conversations, attachmentCleanupSnapshot: nil)
    }

    func clear(
        _ conversations: [Conversation],
        attachmentCleanupSnapshot: AttachmentCleanupSnapshot?
    ) -> DestructivePersistenceReceipt<ConversationClearResult> {
        makeClearReceipt(
            conversations: conversations,
            attachmentCleanupSnapshot: attachmentCleanupSnapshot
        )
    }

    func clear(
        _ conversations: [Conversation],
        attachmentCleanupPreparation: Task<ConversationClearPreparationResult, Never>
    ) -> DestructivePersistenceReceipt<ConversationClearResult> {
        makeClearReceipt(
            conversations: conversations,
            attachmentCleanupSnapshot: nil,
            attachmentCleanupPreparation: attachmentCleanupPreparation
        )
    }

    private func makeClearReceipt(
        conversations: [Conversation],
        attachmentCleanupSnapshot: AttachmentCleanupSnapshot?,
        attachmentCleanupPreparation: Task<ConversationClearPreparationResult, Never>? = nil
    ) -> DestructivePersistenceReceipt<ConversationClearResult> {
        let ownedSnapshot = dictionary(from: conversations)
        let priorDirty = dirty
        let token = nextToken()
        var changes = snapshot.mapValues { DesiredState.saved($0) }
        for id in repairDeletedIDs {
            changes[id] = .deleted
        }
        for (id, intent) in priorDirty {
            changes[id] = intent.desired
        }
        for (id, conversation) in ownedSnapshot {
            changes[id] = .saved(conversation)
        }
        for id in proposedSaves.keys where changes[id] == nil {
            changes[id] = .deleted
        }
        clearLayers.append(ClearLayer(token: token, changes: changes))

        latestClearToken = token
        latestLoadToken = nextToken()
        invalidateRewrite()
        cancelAllDebounces()
        dirty.removeAll()
        proposedSaves.removeAll()
        snapshot.removeAll()

        let store = store
        let physical: PersistenceReceipt<ConversationClearResult> = appendOperation(root: token) { [weak self] in
            let effectiveAttachmentCleanupSnapshot: AttachmentCleanupSnapshot?
            if let attachmentCleanupPreparation {
                switch await attachmentCleanupPreparation.value {
                case let .prepared(snapshot):
                    effectiveAttachmentCleanupSnapshot = snapshot
                case let .failed(error):
                    guard let self else { return .superseded }
                    return self.finishClear(token: token, error: error)
                }
            } else {
                effectiveAttachmentCleanupSnapshot = attachmentCleanupSnapshot
            }
            do {
                try await store.clearConversations(
                    attachmentCleanupSnapshot: effectiveAttachmentCleanupSnapshot
                )
                guard let self else { return .superseded }
                self.storageSnapshot.removeAll()
                self.recordDurableSnapshotChange()
                return self.finishClear(token: token, error: nil)
            } catch {
                guard let self else { return .superseded }
                if let encryptedStoreError = error as? EncryptedStoreError,
                   encryptedStoreError.clearWasCommitted
                {
                    self.storageSnapshot.removeAll()
                    self.recordDurableSnapshotChange()
                    return switch self.finishClear(token: token, error: nil) {
                    case .cleared:
                        .committedWithCleanupFailure(error.localizedDescription)
                    case .superseded:
                        .superseded
                    case .committedWithCleanupFailure, .failed, .recoveryRequired:
                        .superseded
                    }
                }
                if let encryptedStoreError = error as? EncryptedStoreError,
                   encryptedStoreError.clearNeedsRecovery
                {
                    _ = self.finishClear(token: token, error: error.localizedDescription)
                    return .recoveryRequired(error.localizedDescription)
                }
                return self.finishClear(token: token, error: error.localizedDescription)
            }
        }
        let receipt = PersistenceReceipt(task: physical.task) { [weak self] result in
            self?.reconcileClear(result, token: token) ?? .superseded
        }
        return DestructivePersistenceReceipt(
            receipt: receipt,
            repairToken: ConversationSnapshotRepairToken(
                operationToken: token,
                kind: .clear
            )
        )
    }

    func flush(
        excludingUnscheduledConversationIDs: Set<UUID> = []
    ) -> PersistenceReceipt<Void> {
        let pendingDebounces = debounceTasks
        debounceTasks.removeAll()
        for task in pendingDebounces.values {
            task.cancel()
        }

        ensureRewriteScheduled()
        let pendingIntents = dirty.compactMap { id, intent -> (UUID, UInt64, DesiredState)? in
            guard proposedSaves[id] == nil,
                  !intent.isScheduled,
                  rewriteCoveredTokens[id] != intent.token,
                  !excludingUnscheduledConversationIDs.contains(id)
            else {
                return nil
            }
            return (id, intent.token, intent.desired)
        }
        for (id, token, desired) in pendingIntents {
            switch desired {
            case .saved:
                activateSave(id: id, token: token)
            case .deleted:
                activateDelete(id: id, token: token)
            }
        }

        let cutoff = nextTokenValue
        let task = Task { @MainActor [weak self] in
            while let self, self.hasOutstanding(rootAtMost: cutoff) {
                let tail = self.ioTail
                await tail.value
            }
        }
        return PersistenceReceipt(task: task)
    }

    /// Waits for the repair attempt already associated with a destructive operation.
    /// When `retryIfNeeded` is true, schedules at most one new attempt before waiting.
    func settleCurrentSnapshot(
        for repairToken: ConversationSnapshotRepairToken,
        retryIfNeeded: Bool = false
    ) async -> ConversationSnapshotSettlementResult {
        var status = snapshotRepairStatus(for: repairToken)
        switch status {
        case .settled:
            return .settled
        case .superseded:
            return .superseded
        case let .pending(isScheduled):
            if !isScheduled {
                guard retryIfNeeded else { return .failed }
                scheduleSnapshotRepair(for: repairToken)
                status = snapshotRepairStatus(for: repairToken)
                switch status {
                case .settled:
                    return .settled
                case .superseded:
                    return .superseded
                case let .pending(isScheduled) where !isScheduled:
                    return .failed
                case .pending:
                    break
                }
            }
        }

        let repairTail = ioTail
        await repairTail.value

        switch snapshotRepairStatus(for: repairToken) {
        case .settled:
            return .settled
        case .superseded:
            return .superseded
        case .pending:
            return .failed
        }
    }

    func settleCurrentState(for id: UUID) async -> ConversationDurabilityResult {
        let acceptedRootCutoff = nextTokenValue
        var attemptedTokens: Set<UInt64> = []

        while true {
            var observedToken: UInt64?
            if let intent = dirty[id] {
                let token = intent.token
                observedToken = token
                if !intent.isScheduled {
                    guard attemptedTokens.insert(token).inserted else {
                        return .failed
                    }
                    switch intent.desired {
                    case .saved:
                        _ = activateSave(id: id, token: token)
                    case .deleted:
                        _ = activateDelete(id: id, token: token)
                    }
                }
            }

            let tail = ioTail
            await tail.value

            if hasOutstanding(rootAtMost: acceptedRootCutoff) {
                continue
            }

            if let remaining = dirty[id] {
                if remaining.token == observedToken,
                   !remaining.isScheduled,
                   attemptedTokens.contains(remaining.token)
                {
                    return .failed
                }
                continue
            }

            return storageSnapshot[id] == nil ? .deleted : .saved
        }
    }

    private func snapshotRepairStatus(
        for repairToken: ConversationSnapshotRepairToken
    ) -> SnapshotRepairStatus {
        if latestClearToken > repairToken.operationToken {
            return .superseded
        }

        switch repairToken.kind {
        case let .delete(id):
            guard let intent = dirty[id] else {
                return snapshot[id] == nil ? .superseded : .settled
            }
            guard intent.repairRoot == repairToken.operationToken else {
                return .superseded
            }
            let isCoveredByRewrite = rewriteCoveredTokens[id] == intent.token
            return .pending(isScheduled: intent.isScheduled || isCoveredByRewrite)
        case .clear:
            guard rewriteToken != nil, rewriteRoot == repairToken.operationToken else {
                return .settled
            }
            return .pending(isScheduled: rewriteScheduledToken != nil)
        }
    }

    private func scheduleSnapshotRepair(
        for repairToken: ConversationSnapshotRepairToken
    ) {
        switch repairToken.kind {
        case let .delete(id):
            guard let intent = dirty[id], intent.repairRoot == repairToken.operationToken else { return }
            switch intent.desired {
            case .saved:
                ensureRewriteScheduled()
                if rewriteCoveredTokens[id] != intent.token {
                    activateSave(id: id, token: intent.token)
                }
            case .deleted:
                activateDelete(id: id, token: intent.token)
            }
        case .clear:
            ensureRewriteScheduled()
        }
    }

    private func scheduleDebounce(id: UUID, token: UInt64) {
        let duration = debounceDuration
        debounceTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.activateSave(id: id, token: token)
        }
    }

    @discardableResult
    private func activateDelete(
        id: UUID,
        token: UInt64,
        attemptErrorBox: PersistenceAttemptErrorBox? = nil
    ) -> PersistenceReceipt<ConversationDeleteResult>? {
        guard var intent = dirty[id], intent.token == token, !intent.isScheduled,
              case .deleted = intent.desired
        else {
            return nil
        }

        intent.isScheduled = true
        dirty[id] = intent
        let registeredRollback = intent.rollback
        let store = store
        return appendOperation(root: intent.root) { [weak self] in
            do {
                try await store.delete(id)
                guard let self else { return .superseded }
                self.storageSnapshot.removeValue(forKey: id)
                self.repairDeletedIDs.remove(id)
                self.recordDurableSnapshotChange()
                return self.finishDelete(id: id, token: token, rollback: registeredRollback, error: nil)
            } catch {
                guard let self else { return .superseded }
                attemptErrorBox?.error = error
                let rollback: Conversation? = if let currentIntent = self.dirty[id],
                                                  currentIntent.token == token,
                                                  case .deleted = currentIntent.desired
                {
                    currentIntent.rollback
                } else {
                    registeredRollback
                }
                return self.finishDelete(
                    id: id,
                    token: token,
                    rollback: rollback,
                    error: error.localizedDescription
                )
            }
        }
    }

    @discardableResult
    private func activateSave(
        id: UUID,
        token: UInt64
    ) -> PersistenceReceipt<ConversationSaveResult>? {
        guard var intent = dirty[id], intent.token == token, !intent.isScheduled,
              case let .saved(conversation) = intent.desired
        else {
            return nil
        }

        cancelDebounce(for: id)
        intent.isScheduled = true
        dirty[id] = intent

        let store = store
        return appendOperation(root: intent.root) { [weak self] in
            do {
                try await store.save(conversation)
                guard let self else { return .superseded }
                self.storageSnapshot[id] = conversation
                self.recordDurableSnapshotChange()
                return self.finishSave(id: id, token: token, error: nil)
            } catch {
                guard let self else { return .superseded }
                let description = error.localizedDescription
                return self.finishSave(id: id, token: token, error: description)
            }
        }
    }

    private func finishSave(
        id: UUID,
        token: UInt64,
        error: String?
    ) -> ConversationSaveResult {
        guard proposedSaves[id].map({ $0.token <= token }) ?? true,
              var intent = dirty[id], intent.token == token, case .saved = intent.desired
        else {
            return .superseded
        }

        if let error {
            intent.isScheduled = false
            dirty[id] = intent
            log("❌ Failed to save conversation", level: .error, metadata: ["id": id.uuidString, "error": error])
            return .failed(error)
        } else {
            dirty.removeValue(forKey: id)
            log("💾 Saved conversation", level: .debug, metadata: ["id": id.uuidString])
            return .saved
        }
    }

    private func finishProposedSave(
        _ conversation: Conversation,
        token: UInt64,
        error: String?,
        compensationError: String? = nil
    ) -> ConversationSaveResult {
        let id = conversation.id
        guard let proposed = proposedSaves[id], proposed.token == token,
              latestClearToken <= token
        else {
            return .superseded
        }

        // Physical success is not committed until the receipt reconciles. Retaining the
        // intent lets a newer proposal inherit this chain's true pre-proposal durable state.
        guard let error else {
            return .saved
        }

        proposedSaves.removeValue(forKey: id)
        let priorState = proposedPriorState(for: proposed)
        restoreSupersededIntentAfterFailedProposedSave(
            id: id,
            token: token,
            rollback: proposed.rollback
        )
        if dirty[id] == nil, let priorState {
            apply(priorState, for: id, to: &snapshot)
            if compensationError != nil {
                retainFailedProposedCompensation(priorState, id: id, token: token)
            }
        }

        var metadata = ["id": id.uuidString, "error": error]
        if let compensationError {
            metadata["compensationError"] = compensationError
        }
        log("❌ Failed to save proposed conversation", level: .error, metadata: metadata)
        return .failed(error)
    }

    /// Capture after FIFO predecessors finish so an older accepted save can become the baseline.
    private func capturePriorDurableState(for id: UUID, chainRoot: UInt64) {
        guard var proposed = proposedSaves[id], proposed.chainRoot == chainRoot,
              proposed.priorDurable == nil
        else {
            return
        }

        proposed.priorDurable = storageSnapshot[id].map(DesiredState.saved) ?? .deleted
        proposedSaves[id] = proposed
    }

    /// Restore storage before the failed proposal receipt can let its caller decline the UI commit.
    private func compensateFailedProposedSave(id: UUID, token: UInt64) async -> String? {
        guard let proposed = proposedSaves[id], proposed.token == token,
              latestClearToken <= token,
              let priorState = proposedPriorState(for: proposed),
              !storageSnapshotMatches(priorState, id: id)
        else {
            return nil
        }

        do {
            switch priorState {
            case let .saved(conversation):
                try await store.save(conversation)
            case .deleted:
                try await store.delete(id)
            }
        } catch {
            return error.localizedDescription
        }

        apply(priorState, for: id, to: &storageSnapshot)
        recordDurableSnapshotChange()
        log("↩️ Restored durable state after failed proposed save", level: .info, metadata: ["id": id.uuidString])
        return nil
    }

    private func proposedPriorState(for proposed: ProposedSaveIntent) -> DesiredState? {
        if let rollback = proposed.rollback {
            return .saved(rollback)
        }
        return proposed.priorDurable
    }

    private func storageSnapshotMatches(_ desired: DesiredState, id: UUID) -> Bool {
        switch desired {
        case let .saved(conversation):
            storageSnapshot[id] == conversation
        case .deleted:
            storageSnapshot[id] == nil
        }
    }

    private func retainFailedProposedCompensation(
        _ desired: DesiredState,
        id: UUID,
        token: UInt64
    ) {
        guard dirty[id] == nil else { return }

        switch desired {
        case .saved:
            repairDeletedIDs.remove(id)
        case .deleted:
            repairDeletedIDs.insert(id)
        }
        dirty[id] = DirtyIntent(
            token: token,
            root: token,
            repairRoot: nil,
            desired: desired,
            rollback: nil,
            isScheduled: false
        )

        switch desired {
        case .saved:
            activateSave(id: id, token: token)
        case .deleted:
            activateDelete(id: id, token: token)
        }
    }

    private func restoreSupersededIntentAfterFailedProposedSave(
        id: UUID,
        token: UInt64,
        rollback: Conversation?
    ) {
        guard var intent = dirty[id], intent.token < token else { return }

        switch intent.desired {
        case let .saved(conversation):
            snapshot[id] = conversation
            repairDeletedIDs.remove(id)
            if storageSnapshot[id] == conversation {
                dirty.removeValue(forKey: id)
            } else if !intent.isScheduled || outstandingByRoot[intent.root] == nil {
                intent.isScheduled = false
                dirty[id] = intent
                activateSave(id: id, token: intent.token)
            }
        case .deleted:
            if let rollback {
                snapshot[id] = rollback
                repairDeletedIDs.remove(id)
                dirty[id] = DirtyIntent(
                    token: intent.token,
                    root: intent.root,
                    repairRoot: intent.repairRoot ?? intent.root,
                    desired: .saved(rollback),
                    rollback: nil,
                    isScheduled: false
                )
                if storageSnapshot[id] == rollback {
                    dirty.removeValue(forKey: id)
                } else {
                    activateSave(id: id, token: intent.token)
                }
            } else {
                snapshot.removeValue(forKey: id)
                if !intent.isScheduled || outstandingByRoot[intent.root] == nil {
                    intent.isScheduled = false
                    dirty[id] = intent
                    activateDelete(id: id, token: intent.token)
                }
            }
        }
    }

    private func reconcileProposedSave(
        _ result: ConversationSaveResult,
        conversation: Conversation,
        token: UInt64
    ) -> ConversationSaveResult {
        let id = conversation.id
        guard latestClearToken <= token,
              dirty[id].map({ $0.token <= token }) ?? true,
              proposedSaves[id].map({ $0.token <= token }) ?? true
        else {
            return .superseded
        }

        guard case .saved = result else { return result }

        if let proposed = proposedSaves[id] {
            guard proposed.token == token else { return .superseded }
            proposedSaves.removeValue(forKey: id)
            if let intent = dirty[id], intent.token < token {
                dirty.removeValue(forKey: id)
            }
            snapshot[id] = conversation
            repairDeletedIDs.remove(id)
            cancelDebounce(for: id)
            log("💾 Saved proposed conversation", level: .debug, metadata: ["id": id.uuidString])
            return .saved
        }

        return snapshot[id] == conversation ? .saved : .superseded
    }

    private func finishDelete(
        id: UUID,
        token: UInt64,
        rollback: Conversation?,
        error: String?
    ) -> ConversationDeleteResult {
        if error == nil {
            compatibilityDeletionRollbacks.removeValue(forKey: id)
            if let currentIntent = dirty[id],
               currentIntent.token > token,
               case .deleted = currentIntent.desired,
               currentIntent.rollback != nil
            {
                dirty[id] = DirtyIntent(
                    token: currentIntent.token,
                    root: currentIntent.root,
                    repairRoot: currentIntent.repairRoot,
                    desired: currentIntent.desired,
                    rollback: nil,
                    isScheduled: currentIntent.isScheduled
                )
            }
        }

        guard proposedSaves[id].map({ $0.token <= token }) ?? true,
              var intent = dirty[id], intent.token == token, case .deleted = intent.desired
        else {
            return .superseded
        }

        guard let error else {
            dirty.removeValue(forKey: id)
            log("🗑️ Deleted conversation", level: .debug, metadata: ["id": id.uuidString])
            return .deleted
        }

        guard let rollback else {
            intent.isScheduled = false
            dirty[id] = intent
            repairDeletedIDs.insert(id)
            log(
                "❌ Failed to delete conversation by ID; scheduled retry",
                level: .error,
                metadata: ["id": id.uuidString, "error": error]
            )
            return .failed(nil, error)
        }

        let restoreToken = nextToken()
        snapshot[id] = rollback
        repairDeletedIDs.remove(id)
        dirty[id] = DirtyIntent(
            token: restoreToken,
            root: intent.root,
            repairRoot: intent.repairRoot ?? intent.root,
            desired: .saved(rollback),
            rollback: nil,
            isScheduled: false
        )
        ensureRewriteScheduled()
        if rewriteCoveredTokens[id] != restoreToken {
            activateSave(id: id, token: restoreToken)
        }

        log("❌ Failed to delete conversation; restored latest edit", level: .error, metadata: ["id": id.uuidString, "error": error])
        return .failed(rollback, error)
    }

    private func finishClear(token: UInt64, error: String?) -> ConversationClearResult {
        guard let layerIndex = clearLayers.firstIndex(where: { $0.token == token }) else {
            return .superseded
        }
        let isLatest = latestClearToken == token

        guard let error else {
            clearLayers.removeFirst(layerIndex + 1)
            repairDeletedIDs.removeAll()
            log("🧹 Cleared encrypted conversation store", level: .info)
            return isLatest ? .cleared : .superseded
        }
        guard isLatest else { return .superseded }

        var restored = storageSnapshot
        for layer in clearLayers.prefix(layerIndex + 1) {
            updateRepairDeletions(with: layer.changes)
            apply(layer.changes, to: &restored)
        }
        let dirtyChanges = dirty.mapValues(\.desired)
        updateRepairDeletions(with: dirtyChanges)
        apply(dirtyChanges, to: &restored)
        snapshot = restored
        clearLayers.removeFirst(layerIndex + 1)

        rewriteToken = nextToken()
        rewriteRoot = token
        ensureRewriteScheduled()

        let ordered = orderedSnapshot()
        log("⚠️ Clear failed; scheduled storage repair", level: .error, metadata: ["error": error, "count": "\(ordered.count)"])
        return .failed(ordered, error)
    }

    private func finishLoad(_ conversations: [Conversation], token: UInt64) -> ConversationLoadResult {
        guard latestLoadToken == token else { return .superseded }

        if rewriteToken == nil {
            var reconciled = dictionary(from: conversations)
            applyDirty(to: &reconciled)
            snapshot = reconciled
        }

        let ordered = orderedSnapshot()
        log("✅ Loaded \(ordered.count) conversations", level: .info, metadata: ["count": "\(ordered.count)"])
        return .loaded(ordered)
    }

    private func reconcileLoad(
        _ result: ConversationLoadResult,
        token: UInt64
    ) -> ConversationLoadResult {
        guard latestLoadToken == token else { return .superseded }
        if case .loaded = result {
            return .loaded(orderedSnapshot())
        }
        return result
    }

    private func reconcileClear(
        _ result: ConversationClearResult,
        token: UInt64
    ) -> ConversationClearResult {
        guard latestClearToken == token else { return .superseded }
        switch result {
        case let .failed(_, error):
            return .failed(orderedSnapshot(), error)
        case .cleared, .committedWithCleanupFailure, .recoveryRequired, .superseded:
            return result
        }
    }

    private func reconcileDelete(
        _ result: ConversationDeleteResult,
        id: UUID,
        token: UInt64
    ) -> ConversationDeleteResult {
        guard latestClearToken <= token else { return .superseded }
        switch result {
        case .deleted:
            return snapshot[id] == nil ? .deleted : .superseded
        case let .failed(rollback, error):
            if let current = snapshot[id] {
                return .failed(current, error)
            }
            guard rollback == nil,
                  let intent = dirty[id], intent.repairRoot == token,
                  case .deleted = intent.desired
            else {
                return .superseded
            }
            return .failed(nil, error)
        case .superseded:
            return .superseded
        }
    }

    private func ensureRewriteScheduled() {
        guard let token = rewriteToken, let root = rewriteRoot, rewriteScheduledToken == nil else { return }

        let conversations = orderedSnapshot()
        let coveredTokens = dirty.mapValues(\.token)
        rewriteScheduledToken = token
        rewriteCoveredTokens = coveredTokens
        let store = store

        _ = appendOperation(root: root) { [weak self] in
            var firstError: String?

            do {
                try await store.clearConversations()
            } catch {
                firstError = error.localizedDescription
            }

            for conversation in conversations {
                do {
                    try await store.save(conversation)
                } catch where firstError == nil {
                    firstError = error.localizedDescription
                } catch {}
            }

            self?.finishRewrite(
                token: token,
                conversations: conversations,
                coveredTokens: coveredTokens,
                error: firstError
            )
        }
    }

    private func finishRewrite(
        token: UInt64,
        conversations: [Conversation],
        coveredTokens: [UUID: UInt64],
        error: String?
    ) {
        guard rewriteToken == token else { return }

        rewriteScheduledToken = nil
        rewriteCoveredTokens.removeAll(keepingCapacity: true)

        guard let error else {
            rewriteToken = nil
            rewriteRoot = nil
            repairDeletedIDs.removeAll()
            storageSnapshot = dictionary(from: conversations)
            for (id, coveredToken) in coveredTokens {
                guard let intent = dirty[id], intent.token == coveredToken,
                      case .saved = intent.desired
                else {
                    continue
                }
                dirty.removeValue(forKey: id)
                cancelDebounce(for: id)
            }
            recordDurableSnapshotChange()
            log("✅ Repaired conversation storage after failed clear", level: .info)
            return
        }

        log("❌ Failed to repair conversation storage", level: .error, metadata: ["error": error])
    }

    private func invalidateRewrite() {
        rewriteToken = nil
        rewriteRoot = nil
        rewriteScheduledToken = nil
        rewriteCoveredTokens.removeAll(keepingCapacity: true)
    }

    private func appendOperation<Output: Sendable>(
        root: UInt64,
        _ operation: @escaping @MainActor @Sendable () async -> Output
    ) -> PersistenceReceipt<Output> {
        outstandingByRoot[root, default: 0] += 1
        let predecessor = ioTail
        let task = Task { @MainActor in
            await predecessor.value
            let output = await operation()
            self.finishOperation(root: root)
            return output
        }
        ioTail = Task { @MainActor in
            _ = await task.value
        }
        return PersistenceReceipt(task: task)
    }

    private func finishOperation(root: UInt64) {
        guard let count = outstandingByRoot[root] else { return }
        if count == 1 {
            outstandingByRoot.removeValue(forKey: root)
        } else {
            outstandingByRoot[root] = count - 1
        }
    }

    private func hasOutstanding(rootAtMost cutoff: UInt64) -> Bool {
        outstandingByRoot.contains { $0.key <= cutoff && $0.value > 0 }
    }

    private func updateRepairDeletions(with changes: [UUID: DesiredState]) {
        for (id, desired) in changes {
            switch desired {
            case .saved: repairDeletedIDs.remove(id)
            case .deleted: repairDeletedIDs.insert(id)
            }
        }
    }

    private func apply(
        _ desired: DesiredState,
        for id: UUID,
        to conversations: inout [UUID: Conversation]
    ) {
        switch desired {
        case let .saved(conversation): conversations[id] = conversation
        case .deleted: conversations.removeValue(forKey: id)
        }
    }

    private func apply(
        _ changes: [UUID: DesiredState],
        to conversations: inout [UUID: Conversation]
    ) {
        for (id, desired) in changes {
            switch desired {
            case let .saved(conversation): conversations[id] = conversation
            case .deleted: conversations.removeValue(forKey: id)
            }
        }
    }

    private func applyDirty(to conversations: inout [UUID: Conversation]) {
        apply(dirty.mapValues(\.desired), to: &conversations)
    }

    private func dictionary(from conversations: [Conversation]) -> [UUID: Conversation] {
        Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    private func orderedSnapshot() -> [Conversation] {
        ordered(snapshot)
    }

    private func ordered(_ conversations: [UUID: Conversation]) -> [Conversation] {
        conversations.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func recordDurableSnapshotChange() {
        durableSnapshotObserver?()
    }

    private func cancelDebounce(for id: UUID) {
        debounceTasks.removeValue(forKey: id)?.cancel()
    }

    private func cancelAllDebounces() {
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll(keepingCapacity: true)
    }

    private func nextToken() -> UInt64 {
        nextTokenValue &+= 1
        return nextTokenValue
    }

    private func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.conversationManager, level: level, message: message, metadata: metadata)
    }
}
