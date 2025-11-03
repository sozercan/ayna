//
//  ConversationManager.swift
//  ayna
//
//  Created on 11/2/25.
//

import Foundation
import SwiftUI

class ConversationManager: ObservableObject {
    @Published var conversations: [Conversation] = []

    private let conversationsKey = "saved_conversations"

    init() {
        loadConversations()
    }

    func createNewConversation(title: String = "New Conversation") {
        let conversation = Conversation(title: title)
        conversations.insert(conversation, at: 0)
        saveConversations()
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        saveConversations()
    }

    func updateConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
            saveConversations()
        }
    }

    func toggleFavorite(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].isFavorite.toggle()
            saveConversations()
        }
    }

    func renameConversation(_ conversation: Conversation, newTitle: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].title = newTitle
            conversations[index].updatedAt = Date()
            saveConversations()
        }
    }

    func addMessage(to conversation: Conversation, message: Message) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].addMessage(message)

            // Auto-generate title from first user message
            if conversations[index].messages.filter({ $0.role == .user }).count == 1
                && conversations[index].title == "New Conversation" {
                generateTitle(for: conversations[index])
            }

            saveConversations()
        }
    }

    func updateLastMessage(in conversation: Conversation, content: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].updateLastMessage(content)
            saveConversations()
        }
    }

    func clearMessages(in conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].messages.removeAll()
            conversations[index].updatedAt = Date()
            saveConversations()
        }
    }

    private func generateTitle(for conversation: Conversation) {
        guard let firstMessage = conversation.messages.first(where: { $0.role == .user }) else {
            return
        }

        // Simple title generation - take first 50 chars
        let content = firstMessage.content
        let title = String(content.prefix(50))
        renameConversation(conversation, newTitle: title + (content.count > 50 ? "..." : ""))
    }

    // MARK: - Persistence

    func saveConversations() {
        if let encoded = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(encoded, forKey: conversationsKey)
        }
    }

    private func loadConversations() {
        if let data = UserDefaults.standard.data(forKey: conversationsKey),
           let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = decoded
        }
    }

    // MARK: - Search and Filter

    func searchConversations(query: String) -> [Conversation] {
        guard !query.isEmpty else { return conversations }

        return conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query) ||
            conversation.messages.contains { message in
                message.content.localizedCaseInsensitiveContains(query)
            }
        }
    }

    func favoriteConversations() -> [Conversation] {
        conversations.filter { $0.isFavorite }
    }
}
