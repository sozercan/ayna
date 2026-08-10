//
//  ChatTurnRequestPlan.swift
//  Ayna
//
//  Plans the provider-visible history for a chat turn.
//

import Foundation

/// Pure request-history construction shared by chat entry points.
struct ChatTurnRequestPlan: Equatable, Sendable {
    let messages: [Message]

    init(history: [Message], systemPrompt: String?) {
        messages = Self.messages(from: history, systemPrompt: systemPrompt)
    }

    init(
        history: [Message],
        systemPrompt: String?,
        excludingAssistantPlaceholderId placeholderId: UUID?
    ) {
        self.init(
            history: Self.history(
                from: history,
                excludingAssistantPlaceholderId: placeholderId
            ),
            systemPrompt: systemPrompt
        )
    }

    init(
        conversation: Conversation,
        systemPrompt: String?,
        excludingAssistantPlaceholderId placeholderId: UUID?
    ) {
        self.init(
            history: conversation.getEffectiveHistory(),
            systemPrompt: systemPrompt,
            excludingAssistantPlaceholderId: placeholderId
        )
    }

    static func messages(from history: [Message], systemPrompt: String?) -> [Message] {
        guard let systemPrompt,
              !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return history
        }

        return [Message(role: .system, content: systemPrompt)] + history
    }

    static func effectiveMessages(
        from conversation: Conversation,
        systemPrompt: String?,
        excludingResponseGroupId responseGroupId: UUID? = nil
    ) -> [Message] {
        var history = conversation.getEffectiveHistory()
        if let responseGroupId {
            history.removeAll { $0.responseGroupId == responseGroupId }
        }
        return messages(from: history, systemPrompt: systemPrompt)
    }

    private static func history(
        from messages: [Message],
        excludingAssistantPlaceholderId placeholderId: UUID?
    ) -> [Message] {
        guard let placeholderId else { return messages }

        return messages.filter { message in
            guard message.id == placeholderId, message.role == .assistant else {
                return true
            }
            return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
