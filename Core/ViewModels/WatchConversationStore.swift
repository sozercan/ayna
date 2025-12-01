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
    @MainActor
    final class WatchConversationStore: ObservableObject {
        static let shared = WatchConversationStore()

        @Published var conversations: [WatchConversation] = []
        @Published var selectedConversationId: UUID?

        private init() {}

        /// Update conversations from WatchConnectivity sync
        func updateConversations(_ newConversations: [WatchConversation]) {
            // Merge with existing, preserving locally generated titles
            var updatedConversations: [WatchConversation] = []

            for newConv in newConversations {
                if let existingConv = conversations.first(where: { $0.id == newConv.id }) {
                    // Preserve local title if iPhone still has "New Chat" but we generated one
                    var mergedConv = newConv
                    if newConv.title == "New Chat", existingConv.title != "New Chat" {
                        mergedConv.title = existingConv.title
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

            // Sync new conversation to iPhone
            WatchConnectivityService.shared.sendConversation(conversation)

            return conversation
        }

        /// Add a message to a conversation
        func addMessage(_ message: WatchMessage, to conversationId: UUID) {
            if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
                conversations[index].messages.append(message)
                conversations[index].updatedAt = Date()

                // Re-sort to put updated conversation at top
                let updated = conversations[index]
                conversations.remove(at: index)
                conversations.insert(updated, at: 0)
            }
        }

        /// Update the last message content (for streaming)
        func updateLastMessage(in conversationId: UUID, content: String) {
            if let convIndex = conversations.firstIndex(where: { $0.id == conversationId }),
               !conversations[convIndex].messages.isEmpty
            {
                let lastIndex = conversations[convIndex].messages.count - 1
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

                // Sync title update to iPhone
                WatchConnectivityService.shared.sendTitleUpdate(conversationId: conversationId, newTitle: newTitle)
            }
        }
    }

#endif
