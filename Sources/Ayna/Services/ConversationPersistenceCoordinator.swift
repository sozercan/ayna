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

/// Actor that coordinates conversation persistence to prevent race conditions.
/// All save operations are serialized through this actor, with debouncing
/// to coalesce rapid successive saves.
actor ConversationPersistenceCoordinator {
    private var pendingSaves: [UUID: Conversation] = [:]
    private var activeSaveTasks: [UUID: Task<Void, Never>] = [:]
    private let store: EncryptedConversationStore
    private let debounceDuration: Duration

    init(
        store: EncryptedConversationStore = .shared,
        debounceDuration: Duration = .milliseconds(200)
    ) {
        self.store = store
        self.debounceDuration = debounceDuration
    }

    /// Enqueue a conversation for saving with debouncing.
    /// Multiple rapid saves for the same conversation will be coalesced.
    func enqueueSave(_ conversation: Conversation) {
        // Store the latest version
        pendingSaves[conversation.id] = conversation

        // Cancel any existing save task for this conversation
        activeSaveTasks[conversation.id]?.cancel()

        // Create new debounced save task
        activeSaveTasks[conversation.id] = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                // Task was cancelled, which is expected when a newer save comes in
                return
            }

            // Check if we were cancelled or if there's a newer version
            guard !Task.isCancelled else { return }

            await performSave()
        }
    }

    /// Save immediately without debouncing.
    /// Cancels any pending debounced save for this conversation.
    func saveImmediately(_ conversation: Conversation) async throws {
        // Cancel any pending debounced save
        activeSaveTasks[conversation.id]?.cancel()
        activeSaveTasks.removeValue(forKey: conversation.id)
        pendingSaves.removeValue(forKey: conversation.id)

        // Save directly
        try await store.save(conversation)

        DiagnosticsLogger.log(
            .conversationManager,
            level: .debug,
            message: "💾 Saved conversation immediately",
            metadata: ["id": conversation.id.uuidString]
        )
    }

    /// Delete a conversation.
    func delete(_ conversationId: UUID) async throws {
        // Cancel any pending save for this conversation
        activeSaveTasks[conversationId]?.cancel()
        activeSaveTasks.removeValue(forKey: conversationId)
        pendingSaves.removeValue(forKey: conversationId)

        // Delete from store
        try await store.delete(conversationId)
    }

    /// Cancel all pending saves (useful for shutdown).
    func cancelAllPendingSaves() {
        for task in activeSaveTasks.values {
            task.cancel()
        }
        activeSaveTasks.removeAll()
        pendingSaves.removeAll()
    }

    /// Flush all pending saves immediately, bypassing the debounce timer.
    /// Call this on app termination to prevent data loss.
    func flushPendingSaves() async {
        // Cancel debounce timers — we'll save directly
        for task in activeSaveTasks.values {
            task.cancel()
        }
        activeSaveTasks.removeAll()

        // Save all pending conversations
        let conversationsToSave = pendingSaves
        pendingSaves.removeAll()

        await persistConversations(
            conversationsToSave,
            successMessage: "💾 Flushed pending conversation save on shutdown",
            failureMessage: "❌ Failed to flush conversation on shutdown",
            notifyOnFailure: false
        )
    }

    /// Returns the set of conversation IDs that currently have a pending save queued.
    /// Used to implement "dirty-wins" reload reconciliation.
    func pendingConversationIds() -> Set<UUID> {
        Set(pendingSaves.keys)
    }

    // MARK: - Private

    private func performSave() async {
        // Get all pending saves and clear them atomically
        let conversationsToSave = pendingSaves
        pendingSaves.removeAll()

        guard !Task.isCancelled else {
            requeuePendingConversations(conversationsToSave)
            return
        }

        await persistConversations(
            conversationsToSave,
            successMessage: "💾 Saved conversation (debounced)",
            failureMessage: "❌ Failed to save conversation",
            notifyOnFailure: true
        )

        // B32: activeSaveTasks entries are NOT removed here. enqueueSave is the sole
        // writer to activeSaveTasks[id], ensuring a newer task is never accidentally
        // removed after an await suspension in store.save().
    }

    private func persistConversations(
        _ conversationsToSave: [UUID: Conversation],
        successMessage: String,
        failureMessage: String,
        notifyOnFailure: Bool
    ) async {
        guard !conversationsToSave.isEmpty else { return }

        let persistenceStore = store
        await withTaskGroup(of: (UUID, Result<Void, Error>).self) { group in
            for (id, conversation) in conversationsToSave {
                group.addTask {
                    do {
                        try await persistenceStore.save(conversation)
                        return (id, .success(()))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            for await (id, result) in group {
                switch result {
                case .success:
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .debug,
                        message: successMessage,
                        metadata: ["id": id.uuidString]
                    )
                case let .failure(error):
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .error,
                        message: failureMessage,
                        metadata: ["id": id.uuidString, "error": error.localizedDescription]
                    )

                    guard notifyOnFailure else { continue }
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .conversationSaveFailed,
                            object: nil,
                            userInfo: ["conversationId": id]
                        )
                    }
                }
            }
        }
    }

    private func requeuePendingConversations(_ conversationsToSave: [UUID: Conversation]) {
        for (id, conversation) in conversationsToSave where pendingSaves[id] == nil {
            pendingSaves[id] = conversation
        }
    }
}
