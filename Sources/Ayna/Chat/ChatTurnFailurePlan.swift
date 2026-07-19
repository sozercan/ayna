//
//  ChatTurnFailurePlan.swift
//  ayna
//
//  Plans transcript cleanup after a chat turn fails.
//

import Foundation

/// Pure cleanup plan for a failed chat turn.
///
/// The Module makes the platform retry policy explicit while centralizing the
/// risky transcript mutation: removing only the UI-only assistant placeholder
/// that belongs to the failed request.
struct ChatTurnFailurePlan: Equatable, Sendable {
    enum FailedUserMessagePolicy: Equatable, Sendable {
        case preserve
        case removeForRetry
    }

    let messagesAfterFailure: [Message]
    let retryPrompt: String?

    init(
        messages: [Message],
        failedUserMessageId: UUID?,
        assistantPlaceholderId: UUID?,
        failedUserMessagePolicy: FailedUserMessagePolicy
    ) {
        let failedUserMessage = failedUserMessageId.flatMap { userId in
            messages.first { $0.id == userId && $0.role == .user }
        }
        let canRecreateFailedUserFromText = failedUserMessage.map(Self.canRecreateFromTextOnly) ?? false
        let assistantMessage = assistantPlaceholderId.flatMap { assistantId in
            messages.first { $0.id == assistantId && $0.role == .assistant }
        }
        let canRemoveAssistant = assistantMessage.map(Self.isRemovableAssistantPlaceholder) ?? false
        let shouldRemoveFailedUser = failedUserMessagePolicy == .removeForRetry
            && canRecreateFailedUserFromText
            && canRemoveAssistant

        retryPrompt = shouldRemoveFailedUser ? failedUserMessage?.content : nil

        messagesAfterFailure = messages.filter { message in
            if let assistantPlaceholderId,
               message.id == assistantPlaceholderId,
               message.role == .assistant
            {
                if shouldRemoveFailedUser {
                    return false
                }
                return !Self.isRemovableAssistantPlaceholder(message)
            }

            if shouldRemoveFailedUser,
               let failedUserMessageId,
               message.id == failedUserMessageId,
               message.role == .user
            {
                return false
            }

            return true
        }
    }

    private static func canRecreateFromTextOnly(_ message: Message) -> Bool {
        let hasAttachments = !(message.attachments?.isEmpty ?? true)
        return !message.content.isEmpty
            && !hasAttachments
            && message.mediaType == nil
            && message.imageData == nil
            && message.imagePath == nil
    }

    private static func isRemovableAssistantPlaceholder(_ message: Message) -> Bool {
        guard message.role == .assistant, message.content.isEmpty else { return false }

        let hasAttachments = !(message.attachments?.isEmpty ?? true)
        let hasReasoning = !(message.reasoning?.isEmpty ?? true)
        let hasCitations = !(message.citations?.isEmpty ?? true)
        #if os(watchOS)
            let hasToolCalls = false
            let hasPendingToolCalls = false
        #else
            let hasToolCalls = !(message.toolCalls?.isEmpty ?? true)
            let hasPendingToolCalls = !(message.pendingToolCalls?.isEmpty ?? true)
        #endif

        return !hasAttachments
            && !hasReasoning
            && !hasCitations
            && !hasToolCalls
            && !hasPendingToolCalls
            && message.mediaType == nil
            && message.imageData == nil
            && message.imagePath == nil
    }
}
