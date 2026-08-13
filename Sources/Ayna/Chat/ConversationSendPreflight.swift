import Foundation

@MainActor
enum ConversationSendPreflight {
    struct Failure {
        let message: String
        let recoverySuggestion: String
    }

    static func loadConversationHistory(
        conversationId: UUID,
        manager: ConversationManager
    ) async -> Conversation? {
        guard !Task.isCancelled else { return nil }
        let conversation = await manager.ensureConversationLoaded(conversationId)
        guard !Task.isCancelled,
              conversation?.id == conversationId,
              !manager.isMetadataOnlyConversation(conversationId)
        else {
            return nil
        }
        return conversation
    }

    static func attachmentRuleFailure(
        models: [String],
        messages: [Message],
        aiService: AIService
    ) -> Failure? {
        if let message = aiService.attachmentHistorySupportError(
            for: models,
            messages: messages
        ) {
            return Failure(
                message: message,
                recoverySuggestion: "Choose a vision-capable chat model or start a new conversation."
            )
        }

        if let message = aiService.attachmentImageLimitError(
            for: models,
            messages: messages
        ) {
            return Failure(
                message: message,
                recoverySuggestion: "Remove images or start a new conversation."
            )
        }

        return nil
    }

    static func attachmentDataFailure(
        models: [String],
        messages: [Message],
        aiService: AIService,
        loadAttachmentData: @Sendable (String) async -> Data?
    ) async -> Failure? {
        guard hasImageAttachments(in: messages) else { return nil }
        guard let message = await aiService.attachmentImageValidationError(
            for: models,
            in: messages,
            loadAttachmentData: loadAttachmentData
        ) else {
            return nil
        }

        return Failure(
            message: message,
            recoverySuggestion: "Remove the image or choose a different model."
        )
    }

    static func attachmentFailure(
        models: [String],
        messages: [Message],
        aiService: AIService,
        loadAttachmentData: @Sendable (String) async -> Data?
    ) async -> Failure? {
        if let failure = attachmentRuleFailure(
            models: models,
            messages: messages,
            aiService: aiService
        ) {
            return failure
        }

        return await attachmentDataFailure(
            models: models,
            messages: messages,
            aiService: aiService,
            loadAttachmentData: loadAttachmentData
        )
    }

    static func hasImageAttachments(in messages: [Message]) -> Bool {
        messages.contains { message in
            guard message.role == .user else { return false }
            return message.attachments?.contains(where: {
                $0.mimeType.lowercased().hasPrefix("image/")
            }) == true
        }
    }
}
