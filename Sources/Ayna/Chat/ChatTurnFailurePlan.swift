//
//  ChatTurnFailurePlan.swift
//  Ayna
//
//  Plans transcript cleanup after a failed chat turn.
//

import Foundation

/// Removes only UI-only assistant state while preserving durable failed-turn context.
struct ChatTurnFailurePlan: Equatable, Sendable {
    enum FailedUserMessagePolicy: Equatable, Sendable {
        case preserve
        case removeForRetry
    }

    let messagesAfterFailure: [Message]
    let retryPrompt: String?

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

    static func hasSubstantiveText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let assistantMessage = assistantPlaceholderId.flatMap { assistantId in
            messages.first { $0.id == assistantId && $0.role == .assistant }
        }

        let shouldOfferRetry = failedUserMessagePolicy == .removeForRetry
            && failedUserMessage.map(Self.canRecreateFromTextOnly) == true
            && assistantMessage.map(Self.canRetryAfterAssistantState) == true

        retryPrompt = shouldOfferRetry ? failedUserMessage?.content : nil
        messagesAfterFailure = messages.filter { message in
            guard let assistantPlaceholderId,
                  message.id == assistantPlaceholderId,
                  message.role == .assistant
            else {
                return true
            }
            return !Self.isRemovableAssistantPlaceholder(message)
        }
    }

    private static func canRecreateFromTextOnly(_ message: Message) -> Bool {
        let hasAttachments = !(message.attachments?.isEmpty ?? true)
        return hasSubstantiveText(message.content)
            && !hasAttachments
            && message.mediaType == nil
            && message.imageData == nil
            && message.imagePath == nil
    }

    private static func isRemovableAssistantPlaceholder(_ message: Message) -> Bool {
        isEmptyAssistantState(message, citationsPreventMatch: true)
    }

    /// Citations remain visible transcript metadata, but still allow retrying the
    /// originating text-only request when no assistant text or reasoning arrived.
    private static func canRetryAfterAssistantState(_ message: Message) -> Bool {
        isEmptyAssistantState(message, citationsPreventMatch: false)
    }

    private static func isEmptyAssistantState(
        _ message: Message,
        citationsPreventMatch: Bool
    ) -> Bool {
        guard message.role == .assistant,
              !hasSubstantiveText(message.content)
        else {
            return false
        }

        let hasAttachments = !(message.attachments?.isEmpty ?? true)
        let hasReasoning = hasSubstantiveText(message.reasoning)
        let hasCitations = !(message.citations?.isEmpty ?? true)
        let hasToolCalls = !(message.toolCalls?.isEmpty ?? true)
        #if os(watchOS)
            let hasPendingToolCalls = false
        #else
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
