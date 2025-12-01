//
//  WatchConversationStore.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

    import Combine
    import Foundation
    import os

    /// Local store for conversations on Apple Watch
    /// Receives updates from iPhone via WatchConnectivity
    /// Persists conversations to UserDefaults for offline access
    @MainActor
    final class WatchConversationStore: ObservableObject {
        static let shared = WatchConversationStore()

        @Published var conversations: [WatchConversation] = []
        @Published var selectedConversationId: UUID?

        private let persistenceKey = "com.sertacozercan.ayna.watch.conversations"
        private let maxPersistedConversations = 20

        private init() {
            loadFromDisk()
        }

        // MARK: - Persistence

        /// Load conversations from UserDefaults
        private func loadFromDisk() {
            guard let data = UserDefaults.standard.data(forKey: persistenceKey) else {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ No persisted conversations found"
                )
                return
            }

            do {
                let decoded = try JSONDecoder().decode([WatchConversation].self, from: data)
                conversations = decoded
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Loaded \(decoded.count) conversations from disk"
                )
            } catch {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .error,
                    message: "⌚ Failed to load conversations from disk",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }

        /// Save conversations to UserDefaults
        private func saveToDisk() {
            // Only persist most recent conversations to save space
            let toSave = Array(conversations.prefix(maxPersistedConversations))

            do {
                let data = try JSONEncoder().encode(toSave)
                UserDefaults.standard.set(data, forKey: persistenceKey)
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .debug,
                    message: "⌚ Saved \(toSave.count) conversations to disk"
                )
            } catch {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .error,
                    message: "⌚ Failed to save conversations to disk",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }

        /// Update conversations from WatchConnectivity sync
        func updateConversations(_ newConversations: [WatchConversation]) {
            // Merge with existing, preserving local state that may be ahead of iPhone
            var updatedConversations: [WatchConversation] = []

            for newConv in newConversations {
                if let existingConv = conversations.first(where: { $0.id == newConv.id }) {
                    var mergedConv = newConv

                    // Preserve local title if iPhone still has "New Chat" but we generated one
                    if newConv.title == "New Chat", existingConv.title != "New Chat" {
                        mergedConv.title = existingConv.title
                    }

                    // CRITICAL: If local has MORE messages than iPhone, keep local messages
                    // This happens during streaming when we've added a placeholder assistant message
                    // but haven't synced it back to iPhone yet
                    if existingConv.messages.count > newConv.messages.count {
                        mergedConv.messages = existingConv.messages
                        mergedConv.updatedAt = existingConv.updatedAt
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .debug,
                            message: "⌚ Preserved local messages during sync (local has more)",
                            metadata: [
                                "localCount": "\(existingConv.messages.count)",
                                "remoteCount": "\(newConv.messages.count)"
                            ]
                        )
                    }

                    updatedConversations.append(mergedConv)
                } else {
                    updatedConversations.append(newConv)
                }
            }

            // Add any local-only conversations (not yet synced to iPhone)
            for localConv in conversations where !updatedConversations.contains(where: { $0.id == localConv.id }) {
                updatedConversations.append(localConv)
            }

            // Sort by most recent
            updatedConversations.sort { $0.updatedAt > $1.updatedAt }
            conversations = updatedConversations

            // Persist to disk
            saveToDisk()

            DiagnosticsLogger.log(
                .watchConnectivity,
                level: .info,
                message: "⌚ Updated local store with \(conversations.count) conversations"
            )
        }

        /// Get a conversation by ID
        func conversation(for id: UUID) -> WatchConversation? {
            conversations.first { $0.id == id }
        }

        /// Create a new conversation locally and sync to iPhone
        func createConversation(title: String = "New Chat", model: String) -> WatchConversation {
            let conversation = WatchConversation(
                from: Conversation(title: title, model: model)
            )
            conversations.insert(conversation, at: 0)

            // Persist to disk
            saveToDisk()

            // Sync new conversation to iPhone
            WatchConnectivityService.shared.sendConversation(conversation)

            return conversation
        }

        /// Add a message to a conversation
        func addMessage(_ message: WatchMessage, to conversationId: UUID) {
            if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .debug,
                    message: "⌚ addMessage: role='\(message.role)' content='\(message.content.prefix(20))...'"
                )
                conversations[index].messages.append(message)
                conversations[index].updatedAt = Date()

                // Re-sort to put updated conversation at top
                let updated = conversations[index]
                conversations.remove(at: index)
                conversations.insert(updated, at: 0)

                // Persist to disk
                saveToDisk()
            }
        }

        /// Update the last message content (for streaming)
        func updateLastMessage(in conversationId: UUID, content: String) {
            if let convIndex = conversations.firstIndex(where: { $0.id == conversationId }),
               !conversations[convIndex].messages.isEmpty
            {
                let lastIndex = conversations[convIndex].messages.count - 1
                let role = conversations[convIndex].messages[lastIndex].role
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .debug,
                    message: "⌚ updateLastMessage: index=\(lastIndex) role='\(role)' content='\(content.prefix(20))...'"
                )
                conversations[convIndex].messages[lastIndex].content = content
            }
        }

        /// Get the preview text for a conversation
        func previewText(for conversation: WatchConversation) -> String {
            if let lastMessage = conversation.messages.last {
                let preview = lastMessage.content.prefix(50)
                return preview.count < lastMessage.content.count ? "\(preview)..." : String(preview)
            }
            return "No messages"
        }

        /// Delete a conversation
        func deleteConversation(_ conversationId: UUID) {
            conversations.removeAll { $0.id == conversationId }
            if selectedConversationId == conversationId {
                selectedConversationId = nil
            }

            // Persist to disk
            saveToDisk()

            DiagnosticsLogger.log(
                .watchConnectivity,
                level: .info,
                message: "⌚ Deleted conversation locally",
                metadata: ["conversationId": conversationId.uuidString]
            )
        }

        /// Rename a conversation
        func renameConversation(_ conversationId: UUID, newTitle: String) {
            if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
                conversations[index].title = newTitle

                // Persist to disk
                saveToDisk()

                // Sync title update to iPhone
                WatchConnectivityService.shared.sendTitleUpdate(conversationId: conversationId, newTitle: newTitle)
            }
        }
    }

#endif
