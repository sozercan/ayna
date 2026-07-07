//
//  ConversationMetadata.swift
//  ayna
//
//  Lightweight persisted conversation list metadata.
//

import Foundation

struct ConversationMetadata: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var systemPromptMode: SystemPromptMode
    var temperature: Double
    var multiModelEnabled: Bool
    var activeModels: [String]
    var messageCount: Int
    var responseGroupCount: Int

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        model: String,
        systemPromptMode: SystemPromptMode,
        temperature: Double,
        multiModelEnabled: Bool,
        activeModels: [String],
        messageCount: Int,
        responseGroupCount: Int
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPromptMode = systemPromptMode
        self.temperature = temperature
        self.multiModelEnabled = multiModelEnabled
        self.activeModels = activeModels
        self.messageCount = messageCount
        self.responseGroupCount = responseGroupCount
    }

    init(conversation: Conversation) {
        self.init(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            model: conversation.model,
            systemPromptMode: conversation.systemPromptMode,
            temperature: conversation.temperature,
            multiModelEnabled: conversation.multiModelEnabled,
            activeModels: conversation.activeModels,
            messageCount: conversation.messages.count,
            responseGroupCount: conversation.responseGroups.count
        )
    }
}
