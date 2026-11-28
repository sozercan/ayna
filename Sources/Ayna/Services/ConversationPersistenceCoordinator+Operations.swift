import Foundation

extension ConversationPersistenceCoordinator {
    @discardableResult
    func apply(
        _ conversation: Conversation,
        mode: ConversationSaveMode = .coalesced
    ) -> PersistenceReceipt<ConversationSaveResult>? {
        let token = nextToken()
        let id = conversation.id
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
                self.durableSaveObserver?(conversation)
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
            token: token
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
            )
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
        // swiftlint:disable:next large_tuple
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

    func scheduleDebounce(id: UUID, token: UInt64) {
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
    func activateDelete(
        id: UUID,
        token: UInt64
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
    func activateSave(
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
                self.durableSaveObserver?(conversation)
                return self.finishSave(id: id, token: token, error: nil)
            } catch {
                guard let self else { return .superseded }
                let description = error.localizedDescription
                return self.finishSave(id: id, token: token, error: description)
            }
        }
    }
}
