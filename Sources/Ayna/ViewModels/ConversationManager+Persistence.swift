import Foundation

extension ConversationManager {
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
            persistenceTasksById[conversation.id] = startSynchronousSaveTask(
                conversation,
                persistenceSequence: persistenceSequence
            )
            return
        }

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
            if suppressedPersistenceIds.contains(conversationToSave.id) {
                if effectiveAllowsRecreation {
                    suppressedPersistenceIds.remove(conversationToSave.id)
                } else {
                    return
                }
            }
            if requiresImmediateSave {
                if let receipt = persistenceCoordinator.apply(conversationToSave, mode: .immediate),
                   await !settleImmediateSaveReceipt(receipt, conversationID: conversationToSave.id)
                {
                    return
                }
            } else {
                persistenceCoordinator.apply(conversationToSave, mode: .coalesced)
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

    private func startSynchronousSaveTask(
        _ conversation: Conversation,
        persistenceSequence: UInt64
    ) -> Task<Void, Never> {
        let effectiveAllowsRecreation = persistenceRecreationAuthorizationIds.contains(conversation.id)
        let requiresImmediateSave = persistenceImmediateSaveIds.contains(conversation.id)
        let registeredReceipt: PersistenceReceipt<ConversationSaveResult>?
        if suppressedPersistenceIds.contains(conversation.id) {
            if effectiveAllowsRecreation {
                suppressedPersistenceIds.remove(conversation.id)
                registeredReceipt = persistenceCoordinator.apply(
                    conversation,
                    mode: requiresImmediateSave ? .immediate : .coalesced
                )
            } else {
                registeredReceipt = nil
            }
        } else {
            registeredReceipt = persistenceCoordinator.apply(
                conversation,
                mode: requiresImmediateSave ? .immediate : .coalesced
            )
        }

        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishPersistenceTask(for: conversation.id, sequence: persistenceSequence) }

            if let registeredReceipt {
                if requiresImmediateSave {
                    if await settleImmediateSaveReceipt(registeredReceipt, conversationID: conversation.id) {
                        await finishSuccessfulImmediateSave(
                            conversation,
                            persistenceSequence: persistenceSequence,
                            allowsRecreation: effectiveAllowsRecreation,
                            outcome: nil
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
        let registeredReceipt: PersistenceReceipt<ConversationSaveResult>?
        if registersSynchronously {
            if suppressedPersistenceIds.contains(conversation.id) {
                if persistenceRecreationAuthorizationIds.contains(conversation.id) {
                    suppressedPersistenceIds.remove(conversation.id)
                    registeredReceipt = persistenceCoordinator.apply(conversation, mode: .immediate)
                } else {
                    registeredReceipt = nil
                }
            } else {
                registeredReceipt = persistenceCoordinator.apply(conversation, mode: .immediate)
            }
        } else {
            registeredReceipt = nil
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishPersistenceTask(for: conversation.id, sequence: persistenceSequence) }

            if registersSynchronously {
                let effectiveAllowsRecreation = persistenceRecreationAuthorizationIds.contains(conversation.id)
                if let registeredReceipt {
                    if await settleImmediateSaveReceipt(registeredReceipt, conversationID: conversation.id) {
                        await finishSuccessfulImmediateSave(
                            conversation,
                            persistenceSequence: persistenceSequence,
                            allowsRecreation: effectiveAllowsRecreation,
                            outcome: outcome
                        )
                    }
                } else {
                    await finishSuccessfulImmediateSave(
                        conversation,
                        persistenceSequence: persistenceSequence,
                        allowsRecreation: effectiveAllowsRecreation,
                        outcome: nil
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
            if suppressedPersistenceIds.contains(conversationToSave.id) {
                if effectiveAllowsRecreation {
                    suppressedPersistenceIds.remove(conversationToSave.id)
                } else {
                    await finishSuccessfulImmediateSave(
                        conversationToSave,
                        persistenceSequence: persistenceSequence,
                        allowsRecreation: effectiveAllowsRecreation,
                        outcome: nil
                    )
                    return
                }
            }
            let receipt = persistenceCoordinator.apply(conversationToSave, mode: .immediate)
            if let receipt,
               await !settleImmediateSaveReceipt(receipt, conversationID: conversationToSave.id)
            {
                return
            }
            await finishSuccessfulImmediateSave(
                conversationToSave,
                persistenceSequence: persistenceSequence,
                allowsRecreation: effectiveAllowsRecreation,
                outcome: outcome
            )
        }
        persistenceTasksById[conversation.id] = task
        return task
    }

    private func settleImmediateSaveReceipt(
        _ receipt: PersistenceReceipt<ConversationSaveResult>,
        conversationID: UUID
    ) async -> Bool {
        switch await receipt.value {
        case .saved:
            return true
        case .superseded:
            if await persistenceCoordinator.settleCurrentState(for: conversationID) != .failed {
                return true
            }
            logManager(
                "❌ Failed to save conversation",
                level: .error,
                metadata: [
                    "id": conversationID.uuidString,
                    "error": "Failed to settle the latest conversation state",
                ]
            )
            return false
        case let .failed(error):
            logManager(
                "❌ Failed to save conversation",
                level: .error,
                metadata: ["id": conversationID.uuidString, "error": error]
            )
            return false
        }
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
        durableDiskBaseline[conversation.id] = (conversation, false)
        conversationSummaryUpdateOperation(conversation)
        #if !os(watchOS)
            indexConversation(conversation)
        #endif
    }

    func beginDestructivePersistenceOperation(
        _ repairToken: ConversationSnapshotRepairToken
    ) {
        pendingDestructivePersistenceOperations += 1
        registerDestructiveRepairToken(repairToken)
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

    func finishDestructivePersistenceOperation() {
        pendingDestructivePersistenceOperations = max(
            0,
            pendingDestructivePersistenceOperations - 1
        )
    }

    func retainDestructiveBarrierUntilRepairSettles(
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
            attachmentDeleteOperation(ownedAttachmentPaths(of: conversations[index]))
            conversations.remove(at: index)
            pendingSendConversationIds.removeAll { $0 == conversationID }
            updateCacheForRemoval(id: conversationID, at: index)
        }
        metadataAttachmentPathsById.removeValue(forKey: conversationID)
        metadataOnlyConversationIds.remove(conversationID)
        metadataSearchTextById.removeValue(forKey: conversationID)
        durableDiskBaseline.removeValue(forKey: conversationID)
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

    func conversationDidPersist(_ conversation: Conversation) {
        guard getConversationIndex(for: conversation.id) != nil else { return }
        durableDiskBaseline[conversation.id] = (conversation, metadataOnlyConversationIds.contains(conversation.id))
        conversationSummaryUpdateOperation(conversation)
    }

    func ownedAttachmentPaths(of conversation: Conversation) -> [String] {
        if metadataOnlyConversationIds.contains(conversation.id) || conversation.metadataPreview != nil {
            return metadataAttachmentPathsById[conversation.id] ?? conversation.attachmentPaths
        }
        return conversation.attachmentPaths
    }

    func settlePersistence(for conversationID: UUID) async -> ConversationDurabilityResult {
        await persistenceCoordinator.settleCurrentState(for: conversationID)
    }

    func durableConversationsForSync() -> [Conversation] {
        durableSyncSnapshot().conversations
    }

    func durableSyncSnapshot() -> (conversations: [Conversation], bodyUnavailableIDs: Set<UUID>) {
        let saved = persistenceCoordinator.durableConversations()
        guard usesMetadataLoading else { return (saved, []) }

        let savedById = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var durable: [Conversation] = []
        var bodyUnavailableIDs: Set<UUID> = []
        for conversation in conversations {
            if let savedConversation = savedById[conversation.id] {
                durable.append(savedConversation)
            } else if let baseline = durableDiskBaseline[conversation.id] {
                durable.append(baseline.conversation)
                if baseline.isMetadataOnly {
                    bodyUnavailableIDs.insert(conversation.id)
                }
            }
        }
        return (durable, bodyUnavailableIDs)
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
            await persistenceCoordinator.flush(
                excludingUnscheduledConversationIDs: excludedFailedSaveIds
            ).value

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

    func advancePersistenceSequence(for conversationId: UUID) -> UInt64 {
        failedSaveIdsAwaitingFlushObservation.remove(conversationId)
        nextPersistenceSequence &+= 1
        persistenceSequenceById[conversationId] = nextPersistenceSequence
        return nextPersistenceSequence
    }

    func invalidatePendingPersistence(for conversationId: UUID) {
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

    func delete(_ conversationId: UUID) {
        invalidatePendingPersistence(for: conversationId)
        cancelFullConversationLoad(conversationId)
        let deletionVersion = nextManagerDeletionVersion()
        let deletionReconciliationVersion = nextReconciliationVersion()
        latestManagerDeletionVersionById[conversationId] = deletionReconciliationVersion
        let rollbackSnapshot: Conversation? = if let conversation = conversationSnapshot(byId: conversationId),
                                                 !isMetadataBackedSnapshot(conversation)
        {
            resolvingInterruptedImageGeneration(in: conversation)
        } else {
            nil
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishManagerDeletionTask(for: conversationId, version: deletionVersion) }
            suppressedPersistenceIds.insert(conversationId)
            let receipt: DestructivePersistenceReceipt<ConversationDeleteResult> = if let rollbackSnapshot {
                persistenceCoordinator.delete(rollbackSnapshot)
            } else {
                persistenceCoordinator.delete(id: conversationId)
            }
            beginDestructivePersistenceOperation(receipt.repairToken)
            let result = await receipt.value
            handleDeleteResult(
                result,
                conversationId: conversationId,
                deletionReconciliationVersion: deletionReconciliationVersion,
                repairToken: receipt.repairToken
            )
        }
        registerManagerDeletionTask(task, for: conversationId, version: deletionVersion)
    }

    private func handleDeleteResult(
        _ result: ConversationDeleteResult,
        conversationId: UUID,
        deletionReconciliationVersion: UInt64,
        repairToken: ConversationSnapshotRepairToken
    ) {
        switch result {
        case .deleted:
            finishDestructivePersistenceOperation()
            removeDeletedConversationFromState(conversationId)
        case .superseded:
            retainDestructiveBarrierUntilRepairSettles(repairToken)
        case let .failed(restored, error):
            retainDestructiveBarrierUntilRepairSettles(repairToken)
            if restored != nil {
                suppressedPersistenceIds.remove(conversationId)
                if latestManagerDeletionVersionById[conversationId] == deletionReconciliationVersion {
                    latestManagerDeletionVersionById.removeValue(forKey: conversationId)
                }
            } else {
                removeDeletedConversationFromState(conversationId)
            }
            logManager(
                "❌ Failed to delete conversation",
                level: .error,
                metadata: ["id": conversationId.uuidString, "error": error]
            )
        }
    }

    private func removeDeletedConversationFromState(_ conversationId: UUID) {
        conversationSummaryRemoveOperation(conversationId)
        if let index = getConversationIndex(for: conversationId) {
            conversations.remove(at: index)
            pendingSendConversationIds.removeAll { $0 == conversationId }
            metadataOnlyConversationIds.remove(conversationId)
            metadataSearchTextById.removeValue(forKey: conversationId)
            updateCacheForRemoval(id: conversationId, at: index)
        }
        if selectedConversationId == conversationId {
            selectedConversationId = nil
        }
    }
}
