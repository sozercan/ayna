import Foundation

extension ConversationPersistenceCoordinator {
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

    func finishSave(
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

    func finishProposedSave(
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

    func capturePriorDurableState(for id: UUID, chainRoot: UInt64) {
        guard var proposed = proposedSaves[id], proposed.chainRoot == chainRoot,
              proposed.priorDurable == nil
        else {
            return
        }

        proposed.priorDurable = storageSnapshot[id].map(DesiredState.saved) ?? .deleted
        proposedSaves[id] = proposed
    }

    func compensateFailedProposedSave(id: UUID, token: UInt64) async -> String? {
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

    func reconcileProposedSave(
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

    func finishDelete(
        id: UUID,
        token: UInt64,
        rollback: Conversation?,
        error: String?
    ) -> ConversationDeleteResult {
        if error == nil {
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

    func finishClear(token: UInt64, error: String?) -> ConversationClearResult {
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

    func finishLoad(_ conversations: [Conversation], token: UInt64) -> ConversationLoadResult {
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

    func reconcileLoad(
        _ result: ConversationLoadResult,
        token: UInt64
    ) -> ConversationLoadResult {
        guard latestLoadToken == token else { return .superseded }
        if case .loaded = result {
            return .loaded(orderedSnapshot())
        }
        return result
    }

    func reconcileClear(
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

    func reconcileDelete(
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

    func ensureRewriteScheduled() {
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

    func invalidateRewrite() {
        rewriteToken = nil
        rewriteRoot = nil
        rewriteScheduledToken = nil
        rewriteCoveredTokens.removeAll(keepingCapacity: true)
    }
}
