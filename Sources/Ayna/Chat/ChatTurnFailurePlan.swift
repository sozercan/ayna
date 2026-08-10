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

    /// Returns the transcript prefix before the failed user turn.
    ///
    /// Retrying must remove the entire failed turn, not only the user message,
    /// because a tool continuation may already have appended assistant and tool
    /// messages after that user message.
    static func messagesBeforeFailedTurn(
        in messages: [Message],
        failedUserMessageId: UUID
    ) -> [Message]? {
        guard let failedUserIndex = messages.firstIndex(where: {
            $0.id == failedUserMessageId && $0.role == .user
        }) else {
            return nil
        }

        return Array(messages.prefix(failedUserIndex))
    }

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
        let canRetryAfterAssistantState = assistantMessage.map(Self.canRetryAfterAssistantState) ?? false
        let shouldOfferRetry = failedUserMessagePolicy == .removeForRetry
            && canRecreateFailedUserFromText
            && canRetryAfterAssistantState

        retryPrompt = shouldOfferRetry ? failedUserMessage?.content : nil

        messagesAfterFailure = messages.filter { message in
            if let assistantPlaceholderId,
               message.id == assistantPlaceholderId,
               message.role == .assistant
            {
                return !Self.isRemovableAssistantPlaceholder(message)
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
        isEmptyAssistantState(message, citationsPreventMatch: true)
    }

    /// Citations are useful transcript metadata, but do not mean the assistant
    /// continuation produced output. Keep them visible after failure while still
    /// allowing the originating text-only user turn to be retried.
    private static func canRetryAfterAssistantState(_ message: Message) -> Bool {
        isEmptyAssistantState(message, citationsPreventMatch: false)
    }

    private static func isEmptyAssistantState(
        _ message: Message,
        citationsPreventMatch: Bool
    ) -> Bool {
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
            && (!citationsPreventMatch || !hasCitations)
            && !hasToolCalls
            && !hasPendingToolCalls
            && message.mediaType == nil
            && message.imageData == nil
            && message.imagePath == nil
    }
}
