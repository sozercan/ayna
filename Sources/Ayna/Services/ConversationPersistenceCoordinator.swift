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

// swiftlint:disable:next type_name
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

enum ConversationSaveMode: Sendable { case coalesced, immediate }

enum ConversationSaveResult: Equatable, Sendable {
    case saved
    case failed(String)
    case superseded
}

struct PersistenceReceipt<Value: Sendable>: Sendable {
    let task: Task<Value, Never>
    let reconcile: (@MainActor @Sendable (Value) -> Value)?

    init(
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

struct ConversationSnapshotRepairToken: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case delete(UUID)
        case clear
    }

    let operationToken: UInt64
    let kind: Kind

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

enum ConversationSnapshotSettlementResult: Equatable, Sendable {
    case settled
    case failed
    case superseded
}

struct DestructivePersistenceReceipt<Value: Sendable>: Sendable {
    let receipt: PersistenceReceipt<Value>
    let repairToken: ConversationSnapshotRepairToken

    @MainActor
    var value: Value {
        get async {
            await receipt.value
        }
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
final class ConversationPersistenceCoordinator {
    enum DesiredState: Sendable { case saved(Conversation), deleted }

    struct DirtyIntent {
        let token: UInt64
        let root: UInt64
        let repairRoot: UInt64?
        let desired: DesiredState
        let rollback: Conversation?
        var isScheduled: Bool
    }

    struct ProposedSaveIntent {
        let token: UInt64
        let chainRoot: UInt64
        var priorDurable: DesiredState?
        let rollback: Conversation?
    }

    struct ClearLayer {
        let token: UInt64
        let changes: [UUID: DesiredState]
    }

    enum SnapshotRepairStatus {
        case settled
        case pending(isScheduled: Bool)
        case superseded
    }

    let store: any ConversationStoreAdapter
    let debounceDuration: Duration
    var durableSnapshotObserver: (@MainActor @Sendable () -> Void)?
    var durableSaveObserver: (@MainActor @Sendable (Conversation) -> Void)?

    var snapshot: [UUID: Conversation] = [:]
    var storageSnapshot: [UUID: Conversation] = [:]
    var dirty: [UUID: DirtyIntent] = [:]
    var proposedSaves: [UUID: ProposedSaveIntent] = [:]
    var debounceTasks: [UUID: Task<Void, Never>] = [:]
    var outstandingByRoot: [UInt64: Int] = [:]

    var nextTokenValue: UInt64 = 0
    var latestLoadToken: UInt64 = 0
    var latestRequestedLoadToken: UInt64 = 0
    var latestClearToken: UInt64 = 0
    var clearLayers: [ClearLayer] = []

    var rewriteToken: UInt64?
    var rewriteRoot: UInt64?
    var rewriteScheduledToken: UInt64?
    var rewriteCoveredTokens: [UUID: UInt64] = [:]
    var repairDeletedIDs: Set<UUID> = []

    var ioTail = Task { @MainActor in }

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

    func observeDurableSaves(
        _ observer: @escaping @MainActor @Sendable (Conversation) -> Void
    ) {
        durableSaveObserver = observer
    }

    func durableConversations() -> [Conversation] {
        ordered(storageSnapshot)
    }

    func pendingConversationIds() -> Set<UUID> {
        Set(dirty.keys).union(proposedSaves.keys)
    }

    func reconciliationState() -> ConversationPersistenceReconciliationState {
        let deletingIds = Set(dirty.compactMap { id, intent -> UUID? in
            if case .deleted = intent.desired {
                return id
            }
            return nil
        })
        return ConversationPersistenceReconciliationState(
            dirtyIds: pendingConversationIds(),
            deletingIds: deletingIds
        )
    }

    func appendOperation<Output: Sendable>(
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

    func finishOperation(root: UInt64) {
        guard let count = outstandingByRoot[root] else { return }
        if count == 1 {
            outstandingByRoot.removeValue(forKey: root)
        } else {
            outstandingByRoot[root] = count - 1
        }
    }

    func hasOutstanding(rootAtMost cutoff: UInt64) -> Bool {
        outstandingByRoot.contains { $0.key <= cutoff && $0.value > 0 }
    }

    func updateRepairDeletions(with changes: [UUID: DesiredState]) {
        for (id, desired) in changes {
            switch desired {
            case .saved: repairDeletedIDs.remove(id)
            case .deleted: repairDeletedIDs.insert(id)
            }
        }
    }

    func apply(
        _ desired: DesiredState,
        for id: UUID,
        to conversations: inout [UUID: Conversation]
    ) {
        switch desired {
        case let .saved(conversation): conversations[id] = conversation
        case .deleted: conversations.removeValue(forKey: id)
        }
    }

    func apply(
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

    func applyDirty(to conversations: inout [UUID: Conversation]) {
        apply(dirty.mapValues(\.desired), to: &conversations)
    }

    func dictionary(from conversations: [Conversation]) -> [UUID: Conversation] {
        Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    func orderedSnapshot() -> [Conversation] {
        ordered(snapshot)
    }

    func ordered(_ conversations: [UUID: Conversation]) -> [Conversation] {
        conversations.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func recordDurableSnapshotChange() {
        durableSnapshotObserver?()
    }

    func cancelDebounce(for id: UUID) {
        debounceTasks.removeValue(forKey: id)?.cancel()
    }

    func cancelAllDebounces() {
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll(keepingCapacity: true)
    }

    func nextToken() -> UInt64 {
        nextTokenValue &+= 1
        return nextTokenValue
    }

    func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.conversationManager, level: level, message: message, metadata: metadata)
    }
}
