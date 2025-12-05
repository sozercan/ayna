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

    // MARK: - Private

    private func performSave() async {
        // Get all pending saves and clear them atomically
        let conversationsToSave = pendingSaves
        pendingSaves.removeAll()

        for (id, conversation) in conversationsToSave {
            activeSaveTasks.removeValue(forKey: id)

            do {
                try await store.save(conversation)
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .debug,
                    message: "💾 Saved conversation (debounced)",
                    metadata: ["id": id.uuidString]
                )
            } catch {
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
    }
}
