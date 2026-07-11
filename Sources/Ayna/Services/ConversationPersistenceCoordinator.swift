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
}

extension EncryptedConversationStore: ConversationStoreAdapter {
    func clearConversations() async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try clear()
        }.value
    }
}

enum ConversationSaveMode: Sendable { case coalesced, immediate }

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

enum ConversationLoadResult: Equatable, Sendable {
    case loaded([Conversation]), failed(String), superseded
}

enum ConversationDeleteResult: Equatable, Sendable {
    case deleted, failed(Conversation, String), superseded
}

enum ConversationClearResult: Equatable, Sendable {
    case cleared, failed([Conversation], String), superseded
}

@MainActor
final class ConversationPersistenceCoordinator {
    private enum DesiredState { case saved(Conversation), deleted }

    private struct DirtyIntent {
        let token: UInt64
        let root: UInt64
        let desired: DesiredState
        var isScheduled: Bool
    }

    private struct ClearLayer {
        let token: UInt64
        let changes: [UUID: DesiredState]
    }

    private let store: any ConversationStoreAdapter
    private let debounceDuration: Duration

    private var snapshot: [UUID: Conversation] = [:]
    private var storageSnapshot: [UUID: Conversation] = [:]
    private var dirty: [UUID: DirtyIntent] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var outstandingByRoot: [UInt64: Int] = [:]

    private var nextTokenValue: UInt64 = 0
    private var latestLoadToken: UInt64 = 0
    private var latestClearToken: UInt64 = 0
    private var clearLayers: [ClearLayer] = []

    private var rewriteToken: UInt64?
    private var rewriteRoot: UInt64?
    private var rewriteScheduledToken: UInt64?
    private var rewriteCoveredTokens: [UUID: UInt64] = [:]
    private var repairDeletedIDs: Set<UUID> = []

    private var ioTail = Task { @MainActor in }

    init(
        store: any ConversationStoreAdapter = EncryptedConversationStore.shared,
        debounceDuration: Duration = .milliseconds(200)
    ) {
        self.store = store
        self.debounceDuration = debounceDuration
    }

    @discardableResult
    func apply(
        _ conversation: Conversation,
        mode: ConversationSaveMode = .coalesced
    ) -> PersistenceReceipt<Void>? {
        let token = nextToken()
        let id = conversation.id

        snapshot[id] = conversation
        repairDeletedIDs.remove(id)
        cancelDebounce(for: id)
        dirty[id] = DirtyIntent(
            token: token,
            root: token,
            desired: .saved(conversation),
            isScheduled: false
        )

        ensureRewriteScheduled()
        if rewriteCoveredTokens[id] == token {
            return mode == .immediate ? PersistenceReceipt(task: ioTail) : nil
        }
        if mode == .immediate || debounceDuration <= .zero {
            return activateSave(id: id, token: token)
        }
        scheduleDebounce(id: id, token: token)
        return nil
    }

    func load() -> PersistenceReceipt<ConversationLoadResult> {
        let token = nextToken()
        latestLoadToken = token
        let store = store

        let physical: PersistenceReceipt<ConversationLoadResult> = appendOperation(root: token) { [weak self] in
            do {
                let conversations = try await store.loadConversations()
                guard let self else { return .superseded }
                self.storageSnapshot = self.dictionary(from: conversations)
                return self.finishLoad(conversations, token: token)
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

    func delete(_ conversation: Conversation) -> PersistenceReceipt<ConversationDeleteResult> {
        let token = nextToken()
        let id = conversation.id

        snapshot.removeValue(forKey: id)
        cancelDebounce(for: id)
        dirty[id] = DirtyIntent(token: token, root: token, desired: .deleted, isScheduled: true)
        ensureRewriteScheduled()

        let store = store
        let physical: PersistenceReceipt<ConversationDeleteResult> = appendOperation(root: token) { [weak self] in
            do {
                try await store.delete(id)
                guard let self else { return .superseded }
                self.storageSnapshot.removeValue(forKey: id)
                self.repairDeletedIDs.remove(id)
                return self.finishDelete(id: id, token: token, rollback: conversation, error: nil)
            } catch {
                guard let self else { return .superseded }
                return self.finishDelete(
                    id: id,
                    token: token,
                    rollback: conversation,
                    error: error.localizedDescription
                )
            }
        }
        return PersistenceReceipt(task: physical.task) { [weak self] result in
            self?.reconcileDelete(result, id: id, token: token) ?? .superseded
        }
    }

    func clear(_ conversations: [Conversation]) -> PersistenceReceipt<ConversationClearResult> {
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
        clearLayers.append(ClearLayer(token: token, changes: changes))

        latestClearToken = token
        latestLoadToken = nextToken()
        invalidateRewrite()
        cancelAllDebounces()
        dirty.removeAll()
        snapshot.removeAll()

        let store = store
        let physical: PersistenceReceipt<ConversationClearResult> = appendOperation(root: token) { [weak self] in
            do {
                try await store.clearConversations()
                guard let self else { return .superseded }
                self.storageSnapshot.removeAll()
                return self.finishClear(token: token, error: nil)
            } catch {
                guard let self else { return .superseded }
                return self.finishClear(token: token, error: error.localizedDescription)
            }
        }
        return PersistenceReceipt(task: physical.task) { [weak self] result in
            self?.reconcileClear(result, token: token) ?? .superseded
        }
    }

    func flush() -> PersistenceReceipt<Void> {
        let pendingDebounces = debounceTasks
        debounceTasks.removeAll()
        for task in pendingDebounces.values {
            task.cancel()
        }

        ensureRewriteScheduled()
        let pendingSaves = dirty.compactMap { id, intent -> (UUID, UInt64)? in
            guard !intent.isScheduled, rewriteCoveredTokens[id] != intent.token,
                  case .saved = intent.desired
            else {
                return nil
            }
            return (id, intent.token)
        }
        for (id, token) in pendingSaves {
            activateSave(id: id, token: token)
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
    private func activateSave(id: UUID, token: UInt64) -> PersistenceReceipt<Void>? {
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
                self?.storageSnapshot[id] = conversation
                self?.finishSave(id: id, token: token, error: nil)
            } catch {
                self?.finishSave(id: id, token: token, error: error.localizedDescription)
            }
        }
    }

    private func finishSave(id: UUID, token: UInt64, error: String?) {
        guard var intent = dirty[id], intent.token == token, case .saved = intent.desired else {
            return
        }

        if let error {
            intent.isScheduled = false
            dirty[id] = intent
            log("❌ Failed to save conversation", level: .error, metadata: ["id": id.uuidString, "error": error])
        } else {
            dirty.removeValue(forKey: id)
            log("💾 Saved conversation", level: .debug, metadata: ["id": id.uuidString])
        }
    }

    private func finishDelete(
        id: UUID,
        token: UInt64,
        rollback: Conversation,
        error: String?
    ) -> ConversationDeleteResult {
        guard let intent = dirty[id], intent.token == token, case .deleted = intent.desired else {
            return .superseded
        }

        guard let error else {
            dirty.removeValue(forKey: id)
            log("🗑️ Deleted conversation", level: .debug, metadata: ["id": id.uuidString])
            return .deleted
        }

        let restoreToken = nextToken()
        snapshot[id] = rollback
        repairDeletedIDs.remove(id)
        dirty[id] = DirtyIntent(
            token: restoreToken,
            root: intent.root,
            desired: .saved(rollback),
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
        if case let .failed(_, error) = result {
            return .failed(orderedSnapshot(), error)
        }
        return result
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
        case let .failed(_, error):
            guard let current = snapshot[id] else { return .superseded }
            return .failed(current, error)
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
        snapshot.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }
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
