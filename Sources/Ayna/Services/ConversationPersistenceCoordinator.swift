//
//  ConversationPersistenceCoordinator.swift
//  ayna
//
//  Created on 11/24/25.
//

import Foundation
import os.log

/// Notification posted when a conversation save fails (contains conversationId in userInfo)
extension Notification.Name {
    static let conversationSaveFailed = Notification.Name("conversationSaveFailed")
}

struct ConversationPersistenceReconciliationState: Sendable {
    let dirtyIds: Set<UUID>
    let deletingIds: Set<UUID>
}

/// Actor that coordinates conversation persistence to prevent race conditions.
/// All save operations are serialized per conversation, with debouncing to
/// coalesce rapid successive saves.
actor ConversationPersistenceCoordinator {
    private struct DeferredSave: Sendable {
        let conversation: Conversation
        let allowsRecreation: Bool
    }

    private var pendingSaves: [UUID: Conversation] = [:]
    private var activeSaveTasks: [UUID: Task<Void, Error>] = [:]
    private var activeSaveTaskVersions: [UUID: UInt64] = [:]
    private var nextSaveTaskVersion: UInt64 = 0
    private var immediateSaveRequestVersions: [UUID: UInt64] = [:]
    private var nextImmediateSaveRequestVersion: UInt64 = 0
    private var latestSnapshotById: [UUID: Conversation] = [:]
    private var latestSnapshotVersionById: [UUID: UInt64] = [:]
    private var nextLatestSnapshotVersion: UInt64 = 0
    private var persistingConversationIds: Set<UUID> = []
    private var persistingConversations: [UUID: Conversation] = [:]
    private var suppressedSaveIds: Set<UUID> = []
    private var deletionTasks: [UUID: Task<Void, Error>] = [:]
    private var deletionGenerationById: [UUID: UInt64] = [:]
    private var deletionOverridesRecreationIds: Set<UUID> = []
    private var pendingRecreations: [UUID: Conversation] = [:]
    private var activeClearTask: Task<Void, Error>?
    private var clearRequestGeneration: UInt64 = 0
    private var latestCommittedClearGeneration: UInt64 = 0
    private var clearSuppressedIds: Set<UUID> = []
    private var clearNewlySuppressedIds: Set<UUID> = []
    private var savesPendingAfterClear: [UUID: DeferredSave] = [:]
    private var savesToRestoreIfClearFails: [UUID: DeferredSave] = [:]
    private var recoveryBlockedConversationIds: Set<UUID> = []
    private var failedDeletionSuppressionsHeldByClear: Set<UUID> = []
    private let store: EncryptedConversationStore
    private let saveOperation: @Sendable (Conversation) async throws -> Void
    private let deleteOperation: @Sendable (UUID) async throws -> Void
    private let clearOperation: @Sendable (AttachmentCleanupSnapshot?) throws -> Void
    private let saveFailureNotificationOperation: @Sendable (UUID) async -> Void
    private let debounceDuration: Duration

    init(
        store: EncryptedConversationStore = .shared,
        debounceDuration: Duration = .milliseconds(200),
        saveOperation: (@Sendable (Conversation) async throws -> Void)? = nil,
        deleteOperation: (@Sendable (UUID) async throws -> Void)? = nil,
        clearOperation: (@Sendable () throws -> Void)? = nil,
        saveFailureNotificationOperation: (@Sendable (UUID) async -> Void)? = nil
    ) {
        self.store = store
        self.saveOperation = saveOperation ?? { conversation in
            try await store.save(conversation)
        }
        self.deleteOperation = deleteOperation ?? { conversationId in
            try await store.delete(conversationId)
        }
        if let clearOperation {
            self.clearOperation = { _ in try clearOperation() }
        } else {
            self.clearOperation = { snapshot in
                try store.clear(attachmentCleanupSnapshot: snapshot)
            }
        }
        self.saveFailureNotificationOperation = saveFailureNotificationOperation ?? { conversationId in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .conversationSaveFailed,
                    object: nil,
                    userInfo: ["conversationId": conversationId]
                )
            }
        }
        self.debounceDuration = debounceDuration
    }

    /// Enqueue a conversation for saving with debouncing.
    /// Multiple rapid saves for the same conversation will be coalesced.
    func enqueueSave(_ conversation: Conversation, allowsRecreation: Bool = false) {
        if activeClearTask != nil {
            deferSaveUntilAfterClear(conversation, allowsRecreation: allowsRecreation)
            return
        }

        if deletionOverridesRecreationIds.contains(conversation.id) {
            return
        }
        if deletionTasks[conversation.id] != nil {
            if allowsRecreation || pendingRecreations[conversation.id] != nil {
                pendingRecreations[conversation.id] = conversation
                _ = recordLatestSnapshotIfImmediateRequestActive(conversation)
            }
            return
        }
        if allowsRecreation {
            suppressedSaveIds.remove(conversation.id)
        } else if suppressedSaveIds.contains(conversation.id) {
            return
        }

        pendingSaves[conversation.id] = conversation
        _ = recordLatestSnapshotIfImmediateRequestActive(conversation)
        scheduleDebouncedSave(for: conversation.id)
    }

    /// Save immediately without debouncing.
    /// Any older save for this conversation is allowed to finish first so it
    /// cannot overwrite the immediate snapshot afterward.
    func saveImmediately(_ conversation: Conversation, allowsRecreation: Bool = false) async throws {
        nextImmediateSaveRequestVersion &+= 1
        let requestVersion = nextImmediateSaveRequestVersion
        immediateSaveRequestVersions[conversation.id] = requestVersion
        let requestClearGeneration = clearRequestGeneration
        let requestDeletionGeneration = deletionGenerationById[conversation.id] ?? 0
        _ = recordLatestSnapshot(conversation)
        defer {
            if immediateSaveRequestVersions[conversation.id] == requestVersion {
                immediateSaveRequestVersions.removeValue(forKey: conversation.id)
                latestSnapshotById.removeValue(forKey: conversation.id)
                latestSnapshotVersionById.removeValue(forKey: conversation.id)
            }
        }

        if activeClearTask != nil {
            deferSaveUntilAfterClear(conversation, allowsRecreation: allowsRecreation)
            while let activeClearTask {
                try await activeClearTask.value
                await Task.yield()
            }
        }

        guard immediateSaveRequestVersions[conversation.id] == requestVersion,
              clearRequestGeneration == requestClearGeneration,
              (deletionGenerationById[conversation.id] ?? 0) == requestDeletionGeneration,
              !deletionOverridesRecreationIds.contains(conversation.id)
        else {
            return
        }

        if deletionTasks[conversation.id] != nil {
            if allowsRecreation || pendingRecreations[conversation.id] != nil {
                pendingRecreations[conversation.id] = conversation
                _ = recordLatestSnapshotIfImmediateRequestActive(conversation)
            }
            while let deletionTask = deletionTasks[conversation.id] {
                try await deletionTask.value
                await Task.yield()
            }
        }

        guard immediateSaveRequestVersions[conversation.id] == requestVersion,
              clearRequestGeneration == requestClearGeneration,
              (deletionGenerationById[conversation.id] ?? 0) == requestDeletionGeneration,
              !deletionOverridesRecreationIds.contains(conversation.id)
        else {
            return
        }

        if allowsRecreation {
            suppressedSaveIds.remove(conversation.id)
        } else if suppressedSaveIds.contains(conversation.id) {
            return
        }

        pendingSaves.removeValue(forKey: conversation.id)
        let previousTask = activeSaveTasks[conversation.id]
        previousTask?.cancel()

        let version = nextTaskVersion()
        let task = Task<Void, Error> { [weak self] in
            if let previousTask {
                _ = try? await previousTask.value
            }
            guard let self else { return }
            guard let latestConversation = await self.immediateConversationToPersist(
                conversationId: conversation.id,
                requestVersion: requestVersion,
                fallback: conversation
            ) else {
                return
            }
            try await self.persistConversation(
                latestConversation,
                successMessage: "💾 Saved conversation immediately",
                failureMessage: "❌ Failed to save conversation immediately"
            )
        }
        activeSaveTasks[conversation.id] = task
        activeSaveTaskVersions[conversation.id] = version

        do {
            try await task.value
            finishSaveTask(for: conversation.id, version: version)
        } catch {
            finishSaveTask(for: conversation.id, version: version)
            throw error
        }
    }

    /// Queues a storage-derived repair only when no user save is pending or in flight.
    @discardableResult
    func enqueueDerivedUpdateIfCurrent(_ conversation: Conversation) -> Bool {
        guard !Task.isCancelled,
              !suppressedSaveIds.contains(conversation.id),
              pendingSaves[conversation.id] == nil,
              activeSaveTasks[conversation.id] == nil,
              !persistingConversationIds.contains(conversation.id)
        else {
            return false
        }

        enqueueSave(conversation)
        return true
    }

    /// Delete a conversation after any older save finishes. Explicit sync
    /// recreation received during deletion is queued and starts afterward.
    func delete(_ conversationId: UUID) async throws {
        let snapshotToRestoreOnFailure = pendingRecreations[conversationId]
            ?? pendingSaves[conversationId]
            ?? latestSnapshotById[conversationId]
            ?? persistingConversations[conversationId]
        let clearGenerationAtDeleteStart = clearRequestGeneration
        deletionGenerationById[conversationId, default: 0] &+= 1
        purgeLatestSnapshot(for: conversationId)
        if let activeClearTask {
            mergeClearRequest(suppressing: [conversationId])
            do {
                try await activeClearTask.value
                return
            } catch {
                // The clear failed and restored save eligibility; finish the explicit delete below.
            }
        }

        if let existingDeletion = deletionTasks[conversationId] {
            deletionOverridesRecreationIds.insert(conversationId)
            pendingRecreations.removeValue(forKey: conversationId)
            suppressedSaveIds.insert(conversationId)
            _ = try? await existingDeletion.value

            deletionOverridesRecreationIds.insert(conversationId)
            suppressedSaveIds.insert(conversationId)
            pendingRecreations.removeValue(forKey: conversationId)
            pendingSaves.removeValue(forKey: conversationId)
            if let recreationTask = activeSaveTasks.removeValue(forKey: conversationId) {
                activeSaveTaskVersions.removeValue(forKey: conversationId)
                recreationTask.cancel()
                _ = try? await recreationTask.value
            }
            do {
                try await deleteOperation(conversationId)
                deletionOverridesRecreationIds.remove(conversationId)
            } catch {
                await recoverFromFailedDeletion(
                    conversationId,
                    snapshotToRestoreOnFailure: snapshotToRestoreOnFailure,
                    clearGenerationAtDeleteStart: clearGenerationAtDeleteStart,
                    error: error
                )
                throw error
            }
            suppressedSaveIds.insert(conversationId)
            return
        }

        suppressedSaveIds.insert(conversationId)
        pendingSaves.removeValue(forKey: conversationId)

        let previousTask = activeSaveTasks.removeValue(forKey: conversationId)
        activeSaveTaskVersions.removeValue(forKey: conversationId)
        previousTask?.cancel()
        let deleteOperation = deleteOperation
        let deletionTask = Task<Void, Error> {
            if let previousTask {
                _ = try? await previousTask.value
            }
            try await deleteOperation(conversationId)
        }
        deletionTasks[conversationId] = deletionTask

        do {
            try await deletionTask.value
            deletionTasks.removeValue(forKey: conversationId)
            if deletionOverridesRecreationIds.contains(conversationId) {
                pendingRecreations.removeValue(forKey: conversationId)
                suppressedSaveIds.insert(conversationId)
            } else if let recreation = pendingRecreations.removeValue(forKey: conversationId) {
                suppressedSaveIds.remove(conversationId)
                enqueueSave(recreation, allowsRecreation: true)
            }
        } catch {
            await recoverFromFailedDeletion(
                conversationId,
                snapshotToRestoreOnFailure: snapshotToRestoreOnFailure,
                clearGenerationAtDeleteStart: clearGenerationAtDeleteStart,
                error: error
            )
            throw error
        }
    }

    private func recoverFromFailedDeletion(
        _ conversationId: UUID,
        snapshotToRestoreOnFailure: Conversation?,
        clearGenerationAtDeleteStart: UInt64,
        error: Error
    ) async {
        deletionTasks.removeValue(forKey: conversationId)
        deletionOverridesRecreationIds.remove(conversationId)
        let clearOwnsSuppression = activeClearTask != nil
            || clearSuppressedIds.contains(conversationId)
            || latestCommittedClearGeneration > clearGenerationAtDeleteStart
            || recoveryBlockedConversationIds.contains(conversationId)
            || ((error as? EncryptedStoreError)?.clearNeedsRecovery == true)
        if clearOwnsSuppression {
            suppressedSaveIds.insert(conversationId)
            let recreation = pendingRecreations.removeValue(forKey: conversationId)
            if activeClearTask != nil {
                let conversationToRestore = recreation ?? snapshotToRestoreOnFailure
                if let conversationToRestore,
                   savesToRestoreIfClearFails[conversationId] == nil
                {
                    savesToRestoreIfClearFails[conversationId] = DeferredSave(
                        conversation: conversationToRestore,
                        allowsRecreation: recreation != nil
                    )
                }
                failedDeletionSuppressionsHeldByClear.insert(conversationId)
            }
        } else {
            suppressedSaveIds.remove(conversationId)
            let conversationToRestore = pendingRecreations.removeValue(forKey: conversationId)
                ?? snapshotToRestoreOnFailure
            if let conversationToRestore {
                do {
                    try await persistConversation(
                        conversationToRestore,
                        successMessage: "💾 Restored conversation after failed deletion",
                        failureMessage: "❌ Failed to restore conversation after failed deletion"
                    )
                } catch {
                    pendingSaves[conversationId] = conversationToRestore
                    scheduleDebouncedSave(for: conversationId)
                }
            }
        }
    }

    /// Clears persisted conversations while deferring saves created after the clear began.
    func clearAll(
        suppressing conversationIds: Set<UUID>,
        attachmentCleanupSnapshot: AttachmentCleanupSnapshot? = nil
    ) async throws {
        clearRequestGeneration &+= 1
        mergeClearRequest(suppressing: conversationIds.union(deletionTasks.keys))
        if let activeClearTask {
            try await activeClearTask.value
            return
        }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performClear(attachmentCleanupSnapshot: attachmentCleanupSnapshot)
        }
        activeClearTask = task
        try await task.value
    }

    /// IDs currently being deleted and therefore excluded from reload reconciliation.
    func deletingConversationIds() -> Set<UUID> {
        Set(deletionTasks.keys)
    }

    func isDeleting(_ conversationId: UUID) -> Bool {
        deletionTasks[conversationId] != nil
    }

    func deletionGeneration(for conversationId: UUID) -> UInt64 {
        deletionGenerationById[conversationId] ?? 0
    }

    func isClearing() -> Bool {
        activeClearTask != nil
    }

    func clearGeneration() -> UInt64 {
        clearRequestGeneration
    }

    /// Flush all pending saves immediately, bypassing the debounce timer.
    /// Call this on app termination to prevent data loss.
    func flushPendingSaves() async {
        while true {
            while let activeClearTask {
                _ = try? await activeClearTask.value
            }

            let deletions = Array(deletionTasks.values)
            for deletion in deletions {
                _ = try? await deletion.value
            }
            if !deletions.isEmpty {
                await Task.yield()
            }

            let tasks = activeSaveTasks.compactMap { conversationId, task in
                activeSaveTaskVersions[conversationId].map { version in
                    (conversationId, task, version)
                }
            }
            // Only cancel tasks whose snapshot is still pending in the debounce
            // queue. Once a task has removed its snapshot, it may already be in
            // the cancellation-aware store write and must be allowed to commit.
            for (conversationId, task, _) in tasks where pendingSaves[conversationId] != nil {
                task.cancel()
            }

            // A task already persisting is deliberately allowed to finish. A task
            // still in its debounce sleep exits and leaves its latest snapshot here.
            for (_, task, _) in tasks {
                _ = try? await task.value
            }
            for (conversationId, _, version) in tasks {
                finishSaveTask(for: conversationId, version: version)
            }

            let conversationsToSave = pendingSaves
            pendingSaves.removeAll()
            let flushTasks = conversationsToSave.values.map(scheduleFlushSave)
            for (_, task, _) in flushTasks {
                _ = try? await task.value
            }
            for (conversationId, _, version) in flushTasks {
                finishSaveTask(for: conversationId, version: version)
            }

            guard activeClearTask == nil,
                  deletionTasks.isEmpty,
                  pendingRecreations.isEmpty,
                  activeSaveTasks.isEmpty,
                  pendingSaves.isEmpty
            else {
                continue
            }
            return
        }
    }

    /// Returns IDs with unsaved or currently persisting state. Used by reload
    /// reconciliation so storage-derived placeholders never replace user changes.
    func pendingConversationIds() -> Set<UUID> {
        dirtyConversationIds()
    }

    func reconciliationState() -> ConversationPersistenceReconciliationState {
        ConversationPersistenceReconciliationState(
            dirtyIds: dirtyConversationIds(),
            deletingIds: Set(deletionTasks.keys)
        )
    }

    private func dirtyConversationIds() -> Set<UUID> {
        Set(pendingSaves.keys)
            .union(activeSaveTasks.keys)
            .union(persistingConversationIds)
            .union(pendingRecreations.keys)
            .union(savesPendingAfterClear.keys)
            .union(recoveryBlockedConversationIds)
    }

    // MARK: - Private

    private func performClear(attachmentCleanupSnapshot: AttachmentCleanupSnapshot?) async throws {
        let saveTasks = Array(activeSaveTasks.values)
        for task in saveTasks {
            task.cancel()
        }
        activeSaveTasks.removeAll()
        activeSaveTaskVersions.removeAll()
        for (conversationId, conversation) in pendingSaves
            where savesToRestoreIfClearFails[conversationId] == nil
        {
            savesToRestoreIfClearFails[conversationId] = DeferredSave(
                conversation: conversation,
                allowsRecreation: false
            )
        }
        for (conversationId, conversation) in persistingConversations
            where savesToRestoreIfClearFails[conversationId] == nil
        {
            savesToRestoreIfClearFails[conversationId] = DeferredSave(
                conversation: conversation,
                allowsRecreation: false
            )
        }
        pendingSaves.removeAll()

        let activeDeletions = Array(deletionTasks.values)
        for task in saveTasks {
            _ = try? await task.value
        }
        for task in activeDeletions {
            _ = try? await task.value
        }

        do {
            try clearOperation(attachmentCleanupSnapshot)
            finishClear(succeeded: true)
        } catch let error as EncryptedStoreError {
            if error.clearWasCommitted {
                finishClear(succeeded: true)
            } else if error.clearNeedsRecovery {
                finishClear(succeeded: false, recoveryRequired: true)
            } else {
                finishClear(succeeded: false)
            }
            throw error
        } catch {
            finishClear(succeeded: false)
            throw error
        }
    }

    private func finishClear(succeeded: Bool, recoveryRequired: Bool = false) {
        var deferredSaves = savesPendingAfterClear
        if succeeded {
            latestCommittedClearGeneration = clearRequestGeneration
        }
        if recoveryRequired {
            recoveryBlockedConversationIds.formUnion(deferredSaves.keys)
            recoveryBlockedConversationIds.formUnion(savesToRestoreIfClearFails.keys)
            deferredSaves.removeAll()
        } else if !succeeded {
            suppressedSaveIds.subtract(clearNewlySuppressedIds)
            suppressedSaveIds.subtract(failedDeletionSuppressionsHeldByClear)
            for (conversationId, deferredSave) in savesToRestoreIfClearFails
                where deferredSaves[conversationId] == nil
            {
                deferredSaves[conversationId] = deferredSave
            }
        }

        savesPendingAfterClear.removeAll()
        savesToRestoreIfClearFails.removeAll()
        clearSuppressedIds.removeAll()
        clearNewlySuppressedIds.removeAll()
        failedDeletionSuppressionsHeldByClear.removeAll()
        activeClearTask = nil

        for deferredSave in deferredSaves.values {
            let conversation = deferredSave.conversation
            guard deferredSave.allowsRecreation || !suppressedSaveIds.contains(conversation.id) else {
                continue
            }
            if deferredSave.allowsRecreation {
                suppressedSaveIds.remove(conversation.id)
            }
            pendingSaves[conversation.id] = conversation
            scheduleDebouncedSave(for: conversation.id)
        }
    }

    private func mergeClearRequest(suppressing conversationIds: Set<UUID>) {
        clearSuppressedIds.formUnion(conversationIds)
        for conversationId in conversationIds where !suppressedSaveIds.contains(conversationId) {
            clearNewlySuppressedIds.insert(conversationId)
        }
        suppressedSaveIds.formUnion(conversationIds)
        for conversationId in conversationIds {
            let latestSnapshot = latestSnapshotById[conversationId]
            let deferredSave = savesPendingAfterClear.removeValue(forKey: conversationId)
            let recreation = pendingRecreations.removeValue(forKey: conversationId)
            let pendingSave = pendingSaves.removeValue(forKey: conversationId)

            if let deferredSave {
                savesToRestoreIfClearFails[conversationId] = deferredSave
            } else if let recreation {
                savesToRestoreIfClearFails[conversationId] = DeferredSave(
                    conversation: recreation,
                    allowsRecreation: true
                )
            } else if let latestSnapshot {
                savesToRestoreIfClearFails[conversationId] = DeferredSave(
                    conversation: latestSnapshot,
                    allowsRecreation: false
                )
            } else if let pendingSave {
                savesToRestoreIfClearFails[conversationId] = DeferredSave(
                    conversation: pendingSave,
                    allowsRecreation: false
                )
            }
            purgeLatestSnapshot(for: conversationId)
        }
    }

    private func deferSaveUntilAfterClear(
        _ conversation: Conversation,
        allowsRecreation: Bool
    ) {
        let existingAllowsRecreation = savesPendingAfterClear[conversation.id]?.allowsRecreation ?? false
        let effectiveAllowsRecreation = allowsRecreation || existingAllowsRecreation
        guard effectiveAllowsRecreation || !suppressedSaveIds.contains(conversation.id) else {
            let existingRestoreAllowsRecreation = savesToRestoreIfClearFails[conversation.id]?.allowsRecreation ?? false
            savesToRestoreIfClearFails[conversation.id] = DeferredSave(
                conversation: conversation,
                allowsRecreation: allowsRecreation || existingRestoreAllowsRecreation
            )
            _ = recordLatestSnapshotIfImmediateRequestActive(conversation)
            return
        }
        savesPendingAfterClear[conversation.id] = DeferredSave(
            conversation: conversation,
            allowsRecreation: effectiveAllowsRecreation
        )
        _ = recordLatestSnapshotIfImmediateRequestActive(conversation)
    }

    private func immediateConversationToPersist(
        conversationId: UUID,
        requestVersion: UInt64,
        fallback: Conversation
    ) -> Conversation? {
        guard immediateSaveRequestVersions[conversationId] == requestVersion else { return nil }
        return latestSnapshotById[conversationId] ?? fallback
    }

    private func recordLatestSnapshot(_ conversation: Conversation) -> UInt64 {
        nextLatestSnapshotVersion &+= 1
        latestSnapshotById[conversation.id] = conversation
        latestSnapshotVersionById[conversation.id] = nextLatestSnapshotVersion
        return nextLatestSnapshotVersion
    }

    private func recordLatestSnapshotIfImmediateRequestActive(
        _ conversation: Conversation
    ) -> UInt64? {
        guard immediateSaveRequestVersions[conversation.id] != nil else { return nil }
        return recordLatestSnapshot(conversation)
    }

    private func purgeLatestSnapshot(for conversationId: UUID) {
        latestSnapshotById.removeValue(forKey: conversationId)
        latestSnapshotVersionById.removeValue(forKey: conversationId)
    }

    private func scheduleDebouncedSave(for conversationId: UUID) {
        let previousTask = activeSaveTasks[conversationId]
        previousTask?.cancel()
        let version = nextTaskVersion()
        let debounceDuration = debounceDuration

        let task = Task<Void, Error> { [weak self] in
            if let previousTask {
                _ = try? await previousTask.value
            }

            do {
                try await Task.sleep(for: debounceDuration)
                try Task.checkCancellation()
            } catch is CancellationError {
                guard let self else { return }
                await self.finishSaveTask(for: conversationId, version: version)
                return
            }

            guard let self else { return }
            do {
                try await self.performSave(for: conversationId)
                await self.finishSaveTask(for: conversationId, version: version)
            } catch is CancellationError {
                await self.finishSaveTask(for: conversationId, version: version)
                return
            } catch {
                await self.finishSaveTask(for: conversationId, version: version)
                await self.saveFailureNotificationOperation(conversationId)
                throw error
            }
        }

        activeSaveTasks[conversationId] = task
        activeSaveTaskVersions[conversationId] = version
    }

    private func performSave(for conversationId: UUID) async throws {
        // Cancellation can arrive after the debounce task's final check but before
        // this actor hop. Do not consume the pending snapshot in that window.
        guard !Task.isCancelled,
              !suppressedSaveIds.contains(conversationId),
              let conversation = pendingSaves.removeValue(forKey: conversationId)
        else {
            return
        }

        try await persistConversation(
            conversation,
            successMessage: "💾 Saved conversation (debounced)",
            failureMessage: "❌ Failed to save conversation"
        )
    }

    private func scheduleFlushSave(
        _ conversation: Conversation
    ) -> (UUID, Task<Void, Error>, UInt64) {
        let previousTask = activeSaveTasks[conversation.id]
        previousTask?.cancel()
        let version = nextTaskVersion()
        let task = Task<Void, Error> { [weak self] in
            if let previousTask {
                _ = try? await previousTask.value
            }
            guard let self else { return }
            try await self.persistConversation(
                conversation,
                successMessage: "💾 Flushed pending conversation save on shutdown",
                failureMessage: "❌ Failed to flush conversation on shutdown"
            )
        }
        activeSaveTasks[conversation.id] = task
        activeSaveTaskVersions[conversation.id] = version
        return (conversation.id, task, version)
    }

    private func persistConversation(
        _ conversation: Conversation,
        successMessage: String,
        failureMessage: String
    ) async throws {
        persistingConversationIds.insert(conversation.id)
        persistingConversations[conversation.id] = conversation
        defer {
            persistingConversationIds.remove(conversation.id)
            if persistingConversations[conversation.id] == conversation {
                persistingConversations.removeValue(forKey: conversation.id)
            }
        }

        do {
            try await saveOperation(conversation)
            DiagnosticsLogger.log(
                .conversationManager,
                level: .debug,
                message: successMessage,
                metadata: ["id": conversation.id.uuidString]
            )
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: failureMessage,
                metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
            )

            throw error
        }
    }

    private func finishSaveTask(for conversationId: UUID, version: UInt64) {
        guard activeSaveTaskVersions[conversationId] == version else { return }
        activeSaveTasks.removeValue(forKey: conversationId)
        activeSaveTaskVersions.removeValue(forKey: conversationId)
    }

    private func nextTaskVersion() -> UInt64 {
        nextSaveTaskVersion &+= 1
        return nextSaveTaskVersion
    }
}
