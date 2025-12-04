//
//  WatchDataModels.swift
//  ayna
//
//  Shared data models for Watch synchronization.
//  These types are used across macOS, iOS, and watchOS for WatchConnectivity sync.
//

import Foundation

/// Lightweight conversation model for Watch sync (strips heavy data like images and attachments)
struct WatchConversation: Codable, Identifiable {
    let id: UUID
    var title: String
    var messages: [WatchMessage]
    var model: String
    var updatedAt: Date
    var createdAt: Date

    init(from conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        model = conversation.model
        updatedAt = conversation.updatedAt
        createdAt = conversation.createdAt
        // Only include recent messages and strip attachments
        messages = conversation.messages.suffix(20).map { WatchMessage(from: $0) }
    }

    func toConversation() -> Conversation {
        var conversation = Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            model: model
        )
        conversation.updatedAt = updatedAt
        conversation.messages = messages.map { $0.toMessage() }
        return conversation
    }
}

/// Lightweight message model for Watch sync (no images or attachments)
struct WatchMessage: Codable, Identifiable {
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var model: String?

    init(from message: Message) {
        id = message.id
        role = message.role.rawValue
        content = message.content
        timestamp = message.timestamp
        model = message.model
    }

    func toMessage() -> Message {
        Message(
            id: id,
            role: Message.Role(rawValue: role) ?? .assistant,
            content: content,
            timestamp: timestamp,
            model: model
        )
    }
}
