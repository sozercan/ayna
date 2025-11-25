//
//  Conversation.swift
//  ayna
//
//  Created on 11/2/25.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let aynaConversation = UTType(
        exportedAs: "com.sertacozercan.ayna.conversation", conformingTo: .content
    )
}

/// Defines how the system prompt is resolved for a conversation.
enum SystemPromptMode: Codable, Equatable {
    /// Use the global system prompt from AppPreferences
    case inheritGlobal
    /// Use a custom system prompt specific to this conversation
    case custom(String)
    /// No system prompt at all
    case disabled

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ModeType: String, Codable {
        case inheritGlobal
        case custom
        case disabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ModeType.self, forKey: .type)
        switch type {
        case .inheritGlobal:
            self = .inheritGlobal
        case .custom:
            let value = try container.decode(String.self, forKey: .value)
            self = .custom(value)
        case .disabled:
            self = .disabled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inheritGlobal:
            try container.encode(ModeType.inheritGlobal, forKey: .type)
        case let .custom(value):
            try container.encode(ModeType.custom, forKey: .type)
            try container.encode(value, forKey: .value)
        case .disabled:
            try container.encode(ModeType.disabled, forKey: .type)
        }
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var systemPromptMode: SystemPromptMode
    var temperature: Double

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [Message] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        model: String = "gpt-4o",
        systemPromptMode: SystemPromptMode = .inheritGlobal,
        temperature: Double = 0.7
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPromptMode = systemPromptMode
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
