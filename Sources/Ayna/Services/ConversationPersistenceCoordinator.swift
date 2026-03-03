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

        for (id, conversation) in conversationsToSave {
            do {
                try await store.save(conversation)
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .info,
                    message: "💾 Flushed pending conversation save on shutdown",
                    metadata: ["id": id.uuidString]
                )
            } catch {
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .error,
                    message: "❌ Failed to flush conversation on shutdown",
                    metadata: ["id": id.uuidString, "error": error.localizedDescription]
                )
            }
        }
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

        // B39: Track which items were saved or error-handled so we can requeue the rest on cancellation.
        var handledIds = Set<UUID>()

        for (id, conversation) in conversationsToSave {
            // B39: Break (not continue) so unprocessed items can be requeued below.
            guard !Task.isCancelled else { break }

            do {
                try await store.save(conversation)
                handledIds.insert(id)
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .debug,
                    message: "💾 Saved conversation (debounced)",
                    metadata: ["id": id.uuidString]
                )
            } catch {
                handledIds.insert(id)
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .error,
                    message: "❌ Failed to save conversation",
                    metadata: ["id": id.uuidString, "error": error.localizedDescription]
                )
                // Post notification so ConversationManager can reload from disk
                // This ensures in-memory state doesn't diverge from persisted state
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .conversationSaveFailed,
                        object: nil,
                        userInfo: ["conversationId": id]
                    )
                }
            }
        }

        // B39: Requeue any items skipped due to Task cancellation, unless a newer
        // version was already enqueued by enqueueSave during a suspension point.
        for (id, conversation) in conversationsToSave where !handledIds.contains(id) {
            if pendingSaves[id] == nil {
                pendingSaves[id] = conversation
            }
        }
        // B32: activeSaveTasks entries are NOT removed here. enqueueSave is the sole
        // writer to activeSaveTasks[id], ensuring a newer task is never accidentally
        // removed after an await suspension in store.save().
    }
}
