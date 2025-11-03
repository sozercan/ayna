//
//  Conversation.swift
//  ayna
//
//  Created on 11/2/25.
//

import Foundation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var systemPrompt: String?
    var temperature: Double

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [Message] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        model: String = "gpt-4o",
        systemPrompt: String? = nil,
        temperature: Double = 0.7
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
    }

    mutating func addMessage(_ message: Message) {
        messages.append(message)
        updatedAt = Date()
    }

    mutating func updateLastMessage(_ content: String) {
        if var lastMessage = messages.last {
            lastMessage.content = content
            messages[messages.count - 1] = lastMessage
            updatedAt = Date()
        }
    }
}
