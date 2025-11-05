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
        let defaultModel = OpenAIService.shared.selectedModel
        let conversation = Conversation(title: title, model: defaultModel)
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
            let autoGenerateTitle = UserDefaults.standard.object(forKey: "autoGenerateTitle") as? Bool ?? true
            let userMessageCount = conversations[index].messages.filter({ $0.role == .user }).count
            let currentTitle = conversations[index].title
            
            if autoGenerateTitle
                && userMessageCount == 1
                && currentTitle == "New Conversation"
                && message.role == .user {
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

    func updateMessage(in conversation: Conversation, messageId: UUID, update: (inout Message) -> Void) {
        if let convIndex = conversations.firstIndex(where: { $0.id == conversation.id }),
           let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId }) {
            var message = conversations[convIndex].messages[msgIndex]
            update(&message)
            conversations[convIndex].messages[msgIndex] = message
            conversations[convIndex].updatedAt = Date()
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

    func updateModel(for conversation: Conversation, model: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].model = model
            conversations[index].updatedAt = Date()
            saveConversations()
        }
    }

    private func generateTitle(for conversation: Conversation) {
        guard let firstMessage = conversation.messages.first(where: { $0.role == .user }) else {
            return
        }

        let content = firstMessage.content
        
        // Use AI to generate a concise title using the same model as the conversation
        let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(content.prefix(200))\". Only respond with the title, nothing else."
        
        let titleMessage = Message(role: .user, content: titlePrompt)
        
        var generatedTitle = ""
        
        OpenAIService.shared.sendMessage(
            messages: [titleMessage],
            model: conversation.model,
            stream: false,
            onChunk: { chunk in
                generatedTitle += chunk
            },
            onComplete: { [weak self] in
                // Use the AI-generated title, trimmed and cleaned
                let cleanTitle = generatedTitle
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "\n", with: " ")
                
                if !cleanTitle.isEmpty {
                    self?.renameConversation(conversation, newTitle: cleanTitle)
                } else {
                    // Fallback to simple title if empty
                    let fallbackTitle = String(content.prefix(50))
                    self?.renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                }
            },
            onError: { [weak self] error in
                // Fallback to simple title if AI fails
                print("⚠️ Failed to generate AI title: \(error.localizedDescription)")
                let fallbackTitle = String(content.prefix(50))
                self?.renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
            },
            onReasoning: nil
        )
    }

    // MARK: - Persistence

    func saveConversations() {
        if let encoded = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(encoded, forKey: conversationsKey)
        }
    }

    private func loadConversations() {
        if let data = UserDefaults.standard.data(forKey: conversationsKey),
           var decoded = try? JSONDecoder().decode([Conversation].self, from: data) {

            // Validate and fix models that no longer exist
            let availableModels = OpenAIService.shared.customModels
            let defaultModel = OpenAIService.shared.selectedModel
            var needsSave = false

            for index in decoded.indices {
                if !availableModels.contains(decoded[index].model) {
                    // Model no longer exists, update to default
                    decoded[index].model = defaultModel
                    needsSave = true
                }
            }

            conversations = decoded

            // Save if any models were updated
            if needsSave {
                saveConversations()
            }
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
}
