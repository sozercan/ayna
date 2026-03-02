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
enum SystemPromptMode: Equatable {
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

extension SystemPromptMode: Codable {}

struct Conversation: Identifiable, Equatable {
    let id: UUID
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var systemPromptMode: SystemPromptMode
    var temperature: Double

    // Multi-model support
    var multiModelEnabled: Bool
    var activeModels: [String] // Models selected for parallel queries
    var responseGroups: [ResponseGroup] // Track all response groups

    /// Deep link support - transient, not persisted
    /// When set, the chat view should auto-send this prompt on load
    var pendingAutoSendPrompt: String?

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [Message] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        model: String = "gpt-4o",
        systemPromptMode: SystemPromptMode = .inheritGlobal,
        temperature: Double = 0.7,
        multiModelEnabled: Bool = false,
        activeModels: [String] = [],
        responseGroups: [ResponseGroup] = []
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPromptMode = systemPromptMode
        self.temperature = temperature
        self.multiModelEnabled = multiModelEnabled
        self.activeModels = activeModels
        self.responseGroups = responseGroups
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, model
        case systemPromptMode, temperature
        case multiModelEnabled, activeModels, responseGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([Message].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        model = try container.decode(String.self, forKey: .model)
        systemPromptMode = try container.decode(SystemPromptMode.self, forKey: .systemPromptMode)
        temperature = try container.decode(Double.self, forKey: .temperature)
        // Provide defaults for new multi-model fields (backward compatibility)
        multiModelEnabled = try container.decodeIfPresent(Bool.self, forKey: .multiModelEnabled) ?? false
        activeModels = try container.decodeIfPresent([String].self, forKey: .activeModels) ?? []
        responseGroups = try container.decodeIfPresent([ResponseGroup].self, forKey: .responseGroups) ?? []
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

    // MARK: - Multi-Model Support

    /// Get the effective message history for API requests.
    /// This filters out unselected responses from response groups to maintain linear context.
    func getEffectiveHistory() -> [Message] {
        var effectiveMessages: [Message] = []

        for message in messages {
            // If message is part of a response group
            if let groupId = message.responseGroupId {
                // Find the corresponding response group
                if let group = responseGroups.first(where: { $0.id == groupId }) {
                    // Only include if this is the selected response, or if no selection made yet
                    if group.selectedResponseId == message.id || group.selectedResponseId == nil {
                        effectiveMessages.append(message)
                    }
                    // Skip unselected responses
                } else {
                    // No group found, include the message anyway
                    effectiveMessages.append(message)
                }
            } else {
                // Regular message (not part of a response group)
                effectiveMessages.append(message)
            }
        }

        return effectiveMessages
    }

    /// Add a response group for multi-model responses
    mutating func addResponseGroup(_ group: ResponseGroup) {
        responseGroups.append(group)
        updatedAt = Date()
    }

    /// Select a response from a response group
    mutating func selectResponse(in groupId: UUID, messageId: UUID) {
        if let index = responseGroups.firstIndex(where: { $0.id == groupId }) {
            let previousSelection = responseGroups[index].selectedResponseId
            responseGroups[index].selectResponse(messageId)

            // Mark messages accordingly
            for msgIndex in messages.indices where messages[msgIndex].responseGroupId == groupId {
                let isNewSelection = messages[msgIndex].id == messageId
                let wasPreviousSelection = messages[msgIndex].id == previousSelection

                messages[msgIndex].isSelectedResponse = isNewSelection

                #if !os(watchOS)
                    // If this is the selected message and it has pending tool calls, activate them
                    if isNewSelection, let pendingCalls = messages[msgIndex].pendingToolCalls {
                        messages[msgIndex].toolCalls = pendingCalls
                        messages[msgIndex].pendingToolCalls = nil
                    }
                    // Clear tool calls from previous selection to prevent confusion
                    if wasPreviousSelection, previousSelection != nil {
                        messages[msgIndex].toolCalls = nil
                    }
                #endif
            }

            updatedAt = Date()
        }
    }

    /// Get a response group by ID
    func getResponseGroup(_ groupId: UUID) -> ResponseGroup? {
        responseGroups.first { $0.id == groupId }
    }

    /// Update a response group
    mutating func updateResponseGroup(_ group: ResponseGroup) {
        if let index = responseGroups.firstIndex(where: { $0.id == group.id }) {
            responseGroups[index] = group
            updatedAt = Date()
        }
    }
}

extension Conversation: Codable {}
