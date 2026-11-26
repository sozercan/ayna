// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

extension MacChatView {
    func editMessageAndResend(_ message: Message, newContent: String) {
        guard !isGenerating, sendPreparationTask == nil else { return }
        guard let proposedHistory = ChatDraftContent.effectiveHistory(
            byEditingUserMessage: message.id,
            newContent: newContent,
            in: currentConversation
        ) else {
            return
        }

        let resendModel = currentConversation.model
        let conversationID = currentConversation.id
        let performEdit: @MainActor @Sendable () -> Void = {
            performEditMessageAndResend(
                messageID: message.id,
                newContent: newContent,
                model: resendModel,
                conversationID: conversationID
            )
        }
        preflightHistoryMutation(
            models: [resendModel],
            messages: proposedHistory,
            onSuccess: performEdit
        )
    }

    func retryLastMessage(beforeMessage: Message) {
        scheduleRetry(
            beforeMessageID: beforeMessage.id,
            model: currentConversation.model,
            usesConversationModel: true
        )
    }

    func switchModelAndRetry(beforeMessage: Message, newModel: String) {
        retryWithModel(beforeMessage: beforeMessage, model: newModel)
    }

    func retryWithModel(beforeMessage: Message, model: String) {
        scheduleRetry(
            beforeMessageID: beforeMessage.id,
            model: model,
            usesConversationModel: false
        )
    }

    private func scheduleRetry(
        beforeMessageID: UUID,
        model: String,
        usesConversationModel: Bool
    ) {
        guard !isGenerating, sendPreparationTask == nil else { return }
        let targetConversation = currentConversation
        guard let assistantIndex = targetConversation.messages.firstIndex(where: {
                  $0.id == beforeMessageID
              }), assistantIndex > 0,
              targetConversation.messages[..<assistantIndex].last(where: { $0.role == .user }) != nil
        else {
            return
        }

        let conversationID = targetConversation.id
        let retryAction: @MainActor @Sendable () -> Void = {
            performRetry(
                beforeMessageID: beforeMessageID,
                model: model,
                conversationID: conversationID,
                usesConversationModel: usesConversationModel
            )
        }

        var retryConversation = targetConversation
        retryConversation.messages = Array(targetConversation.messages.prefix(assistantIndex))
        preflightHistoryMutation(
            models: [model],
            messages: retryConversation.getEffectiveHistory(),
            onSuccess: retryAction
        )
    }

    private func preflightHistoryMutation(
        models: [String],
        messages: [Message],
        onSuccess: @escaping @MainActor @Sendable () -> Void
    ) {
        if let failure = ConversationSendPreflight.attachmentRuleFailure(
            models: models,
            messages: messages,
            aiService: aiService
        ) {
            errorMessage = failure.message
            errorRecoverySuggestion = failure.recoverySuggestion
            return
        }

        guard ConversationSendPreflight.hasImageAttachments(in: messages) else {
            onSuccess()
            return
        }

        let preparationID = UUID()
        sendPreparationID = preparationID
        isGenerating = true
        let task = Task { @MainActor in
            let failure = await ConversationSendPreflight.attachmentDataFailure(
                models: models,
                messages: messages,
                aiService: aiService,
                loadAttachmentData: { path in
                    await AttachmentStorage.shared.loadData(path: path)
                }
            )
            guard !Task.isCancelled, sendPreparationID == preparationID else { return }

            sendPreparationTask = nil
            sendPreparationID = nil
            isGenerating = false
            if let failure {
                errorMessage = failure.message
                errorRecoverySuggestion = failure.recoverySuggestion
                return
            }
            onSuccess()
        }
        sendPreparationTask = task
    }

    private func performRetry(
        beforeMessageID: UUID,
        model: String,
        conversationID: UUID,
        usesConversationModel: Bool
    ) {
        guard !isGenerating, sendPreparationTask == nil,
              let targetConversation = conversationManager.conversation(byId: conversationID),
              !usesConversationModel || targetConversation.model == model,
              let assistantIndex = targetConversation.messages.firstIndex(where: {
                  $0.id == beforeMessageID
              }), assistantIndex > 0,
              let userMessage = targetConversation.messages[..<assistantIndex]
                  .last(where: { $0.role == .user }),
              let conversationIndex = conversationManager.conversations.firstIndex(where: {
                  $0.id == conversationID
              })
        else {
            return
        }

        conversationManager.conversations[conversationIndex].messages.removeSubrange(assistantIndex...)
        conversationManager.save(conversationManager.conversations[conversationIndex])
        if usesConversationModel {
            resendMessage(userMessage)
        } else {
            resendMessageWithModel(userMessage, model: model)
        }
    }

    private func performEditMessageAndResend(
        messageID: UUID,
        newContent: String,
        model: String,
        conversationID: UUID
    ) {
        guard !isGenerating, sendPreparationTask == nil,
              let targetConversation = conversationManager.conversation(byId: conversationID),
              targetConversation.model == model,
              conversationManager.editMessage(
                  in: targetConversation,
                  messageId: messageID,
                  newContent: newContent
              ),
              let editedMessage = conversationManager.conversation(byId: conversationID)?
                  .messages.first(where: { $0.id == messageID })
        else {
            return
        }
        resendMessage(editedMessage)
    }

    func resendMessage(_ message: Message) {
        errorMessage = nil
        isGenerating = true

        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        let modelCapability = aiService.getModelCapability(updatedConversation.model)

        if modelCapability == .imageGeneration {
            generateImage(prompt: message.content, model: updatedConversation.model)
            return
        }

        let currentMessages = updatedConversation.messages

        var messagesToSend = currentMessages
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        let tools = aiService.getAllAvailableTools()

        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true,
            assistantMessageID: assistantMessage.id
        )
    }

    func resendMessageWithModel(_ message: Message, model: String) {
        errorMessage = nil
        isGenerating = true

        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        let modelCapability = aiService.getModelCapability(model)

        if modelCapability == .imageGeneration {
            generateImage(prompt: message.content, model: model)
            return
        }

        let currentMessages = updatedConversation.messages

        var messagesToSend = currentMessages
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        let assistantMessage = Message(role: .assistant, content: "", model: model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        let tools = aiService.getAllAvailableTools()

        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true,
            assistantMessageID: assistantMessage.id
        )
    }

    func buildFullSystemPrompt(for conversation: Conversation) -> String? {
        var components: [String] = []

        if let userPrompt = conversationManager.effectiveSystemPrompt(for: conversation), !userPrompt.isEmpty {
            components.append(userPrompt)
        }

        if let agenticContext = aiService.getAgenticSystemPromptContext() {
            components.append(agenticContext)
        }

        return components.isEmpty ? nil : components.joined(separator: "\n\n")
    }
}
#endif
