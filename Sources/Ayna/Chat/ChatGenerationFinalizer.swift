//
//  ChatGenerationFinalizer.swift
//  ayna
//
//  Finalizes persisted chat state when an in-flight generation is cancelled.
//

import Foundation

struct ChatGenerationFinalizationResult: Equatable, Sendable {
    let appendedCharacterCount: Int
    let removedAssistantMessageID: UUID?
    let terminalizedResponseCount: Int

    var didMutate: Bool {
        appendedCharacterCount > 0 || removedAssistantMessageID != nil || terminalizedResponseCount > 0
    }
}

enum ChatGenerationFinalizer {
    /// Applies cancellation bookkeeping without discarding partial assistant output.
    ///
    /// Empty single-response text placeholders are removed. Multi-model placeholders remain so
    /// their failed terminal state can still be rendered as part of the response group.
    @discardableResult
    static func finalize(
        conversation: inout Conversation,
        activeAssistantMessageID: UUID?,
        pendingText: String = "",
        activeResponseGroupID: UUID?
    ) -> ChatGenerationFinalizationResult {
        var appendedCharacterCount = 0
        var removedAssistantMessageID: UUID?
        var terminalizedResponseCount = 0

        if let activeAssistantMessageID,
           !pendingText.isEmpty,
           let messageIndex = conversation.messages.firstIndex(where: { $0.id == activeAssistantMessageID }),
           conversation.messages[messageIndex].role == .assistant
        {
            conversation.messages[messageIndex].content += pendingText
            appendedCharacterCount = pendingText.count
        }

        if let activeResponseGroupID,
           let groupIndex = conversation.responseGroups.firstIndex(where: { $0.id == activeResponseGroupID })
        {
            for responseIndex in conversation.responseGroups[groupIndex].responses.indices
                where conversation.responseGroups[groupIndex].responses[responseIndex].status == .streaming
            {
                conversation.responseGroups[groupIndex].responses[responseIndex].status = .failed
                terminalizedResponseCount += 1
            }
        }

        if let activeAssistantMessageID,
           let messageIndex = conversation.messages.firstIndex(where: { $0.id == activeAssistantMessageID }),
           isDiscardableTextPlaceholder(conversation.messages[messageIndex])
        {
            conversation.messages.remove(at: messageIndex)
            removedAssistantMessageID = activeAssistantMessageID
        }

        if appendedCharacterCount > 0 || removedAssistantMessageID != nil || terminalizedResponseCount > 0 {
            conversation.updatedAt = Date()
        }

        return ChatGenerationFinalizationResult(
            appendedCharacterCount: appendedCharacterCount,
            removedAssistantMessageID: removedAssistantMessageID,
            terminalizedResponseCount: terminalizedResponseCount
        )
    }

    private static func isDiscardableTextPlaceholder(_ message: Message) -> Bool {
        message.role == .assistant &&
            message.responseGroupId == nil &&
            message.mediaType == nil &&
            message.content.isEmpty &&
            (message.reasoning?.isEmpty ?? true) &&
            (message.citations?.isEmpty ?? true) &&
            message.imageData == nil &&
            message.imagePath == nil
    }
}
