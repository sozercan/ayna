import Foundation

extension ConversationManager {
    private struct ClearCapturedState {
        let beforeClear: [Conversation]
        let conversationIds: Set<UUID>
        let selectedBeforeClear: UUID?
        let rollbackSelectionRevision: UInt64
    }

    private struct ClearExecutionContext {
        let generation: UInt64
        let reconciliationVersionAtClearStart: UInt64
        let privacyMarkersBeforeClear: PrivacyCleanupMarkerSnapshot
        let stateWasAuthoritative: Bool
        let beforeClear: [Conversation]
        let conversationIds: Set<UUID>
        let selectedBeforeClear: UUID?
        let rollbackSelectionRevision: UInt64
        let attachmentCleanupFenceActive: Bool
        let repairToken: ConversationSnapshotRepairToken
    }

    @discardableResult
    func clearAllConversations() -> Task<Void, Never> {
        persistenceErrorMessage = nil
        let previousClearTask = clearConversationsTask
        if previousClearTask != nil {
            logManager("Merging another clear request into the active clear", level: .info)
        }

        let reconciliationVersionAtClearStart = nextReconciliationMutationVersion
        guard let privacyMarkersBeforeClear = loadPrivacyMarkersBeforeClear() else {
            return Task {}
        }

        clearConversationsGeneration &+= 1
        let generation = clearConversationsGeneration
        let attachmentCleanupFencePreparation = beginAttachmentCleanupFence()
        NotificationCenter.default.post(
            name: .conversationHistoryClearStarted,
            object: self
        )

        let stateWasAuthoritative = isConversationStateAuthoritative
        let capturedState = captureAndResetStateForClear(generation: generation)

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
            capturedState.beforeClear,
            attachmentCleanupPreparation: attachmentCleanupPreparationTask
        )
        beginDestructivePersistenceOperation(receipt.repairToken)
        let context = ClearExecutionContext(
            generation: generation,
            reconciliationVersionAtClearStart: reconciliationVersionAtClearStart,
            privacyMarkersBeforeClear: privacyMarkersBeforeClear,
            stateWasAuthoritative: stateWasAuthoritative,
            beforeClear: capturedState.beforeClear,
            conversationIds: capturedState.conversationIds,
            selectedBeforeClear: capturedState.selectedBeforeClear,
            rollbackSelectionRevision: capturedState.rollbackSelectionRevision,
            attachmentCleanupFenceActive: attachmentCleanupFencePreparation.isActive,
            repairToken: receipt.repairToken
        )

        let task = Task { @MainActor [weak self] in
            let attachmentCleanupPreparation = await attachmentCleanupPreparationTask.value
            guard let self else { return }
            let clearResult = await receipt.value
            await self.handleClearResult(
                clearResult,
                attachmentCleanupPreparation: attachmentCleanupPreparation,
                context: context
            )
        }
        clearConversationsTask = task
        return task
    }

    private func loadPrivacyMarkersBeforeClear() -> PrivacyCleanupMarkerSnapshot? {
        guard let encryptedStore else {
            return PrivacyCleanupMarkerSnapshot(markerFileNames: [])
        }
        do {
            return try encryptedStore.pendingPrivacyCleanupMarkerSnapshotThrowing()
        } catch {
            recordPersistenceError(
                "Couldn’t inspect pending privacy cleanup. Restart Ayna and try again."
            )
            return nil
        }
    }

    private func captureAndResetStateForClear(
        generation: UInt64
    ) -> ClearCapturedState {
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
        pendingSendConversationIds.removeAll()
        metadataOnlyConversationIds.removeAll()
        metadataSearchTextById.removeAll()
        conversationIndexCache.removeAll()
        selectedConversationId = nil
        return ClearCapturedState(
            beforeClear: beforeClear,
            conversationIds: conversationIds,
            selectedBeforeClear: selectedBeforeClear,
            rollbackSelectionRevision: selectionRevision
        )
    }

    private func handleClearResult(
        _ clearResult: ConversationClearResult,
        attachmentCleanupPreparation: ConversationClearPreparationResult,
        context: ClearExecutionContext
    ) async {
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

        switch clearResult {
        case .cleared, .committedWithCleanupFailure:
            let suppressedConversationIds = Set(
                clearRollbackConversationGenerationById.compactMap { conversationId, rollbackGeneration in
                    rollbackGeneration <= context.generation ? conversationId : nil
                }
            ).union(context.conversationIds)
            suppressedPersistenceIds.formUnion(suppressedConversationIds)
            finishDestructivePersistenceOperation()
            isConversationStateAuthoritative = true
            NotificationCenter.default.post(
                name: .conversationHistoryClearCommitted,
                object: self
            )
            discardClearRollbackState(for: context.conversationIds, generation: context.generation)
            await completePostClearPrivacyCleanup(
                attachmentCleanupSnapshot: attachmentCleanupSnapshot,
                attachmentCleanupSnapshotError: attachmentCleanupSnapshotError,
                privacyMarkersBeforeClear: context.privacyMarkersBeforeClear,
                attachmentCleanupFenceActive: context.attachmentCleanupFenceActive
            )
            if case let .committedWithCleanupFailure(error) = clearResult {
                recordPersistenceError(
                    "Conversations were cleared, but encrypted backup cleanup failed. \(error)"
                )
            }
            logManager("🧹 Cleared encrypted conversation store", level: .info)
        case let .recoveryRequired(error):
            retainDestructiveBarrierUntilRepairSettles(context.repairToken)
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
                restored: context.beforeClear,
                generation: context.generation,
                selectedBeforeClear: context.selectedBeforeClear,
                rollbackSelectionRevision: context.rollbackSelectionRevision
            )
        case let .failed(restored, error):
            await handleFailedClear(
                restored: restored,
                error: error,
                context: context
            )
        case .superseded:
            finishDestructivePersistenceOperation()
            releaseAttachmentCleanupFenceIfNeeded(context.attachmentCleanupFenceActive)
        }

        if clearConversationsGeneration == context.generation {
            switch clearResult {
            case .cleared, .committedWithCleanupFailure:
                durableDiskBaseline.removeAll()
                discardManagerReconciliationVersions(
                    through: context.reconciliationVersionAtClearStart
                )
                resetClearRollbackState(through: context.generation)
            case .failed, .recoveryRequired, .superseded:
                break
            }
            clearConversationsTask = nil
        }
    }

    private func handleFailedClear(
        restored: [Conversation],
        error: String,
        context: ClearExecutionContext
    ) async {
        retainDestructiveBarrierUntilRepairSettles(context.repairToken)
        releaseAttachmentCleanupFenceIfNeeded(context.attachmentCleanupFenceActive)
        isConversationStateAuthoritative = context.stateWasAuthoritative
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
        guard clearConversationsGeneration == context.generation else { return }
        if clearFailureNeedsReload {
            let summaryRestored = await restoreClearRollbackSummaryIfNeeded(
                through: context.generation
            )
            guard clearConversationsGeneration == context.generation else { return }
            resetClearRollbackState(
                through: context.generation,
                preservingSummaryDigest: !summaryRestored
            )
            isLoaded = false
            await loadConversations(
                allowingActiveClearGeneration: context.generation
            )
        } else {
            await restoreClearRollbackInMemory(
                restored: restored,
                generation: context.generation,
                selectedBeforeClear: context.selectedBeforeClear,
                rollbackSelectionRevision: context.rollbackSelectionRevision
            )
        }
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

    func restoreClearRollbackSummaryIfNeeded(through generation: UInt64) async -> Bool {
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

    func resetClearRollbackState(
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

    func completePendingPrivacyCleanupIfNeeded() async -> Bool {
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
}
