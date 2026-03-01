//
//  MacChatView+Retry.swift
//  ayna
//
//  Created on 7/25/25.
//

import SwiftUI

// MARK: - Retry & Resend Methods

extension MacChatView {
    /// Retry the message that came before the specified assistant message
    func retryLastMessage(beforeMessage: Message) {
        guard !isGenerating else { return }

        // Find the user message that came before this assistant message
        guard
            let assistantIndex = currentConversation.messages.firstIndex(where: {
                $0.id == beforeMessage.id
            }),
            assistantIndex > 0
        else {
            return
        }

        // Find the last user message before this assistant message
        var userMessageIndex: Int?
        for index in (0 ..< assistantIndex).reversed()
            where currentConversation.messages[index].role == .user
        {
            userMessageIndex = index
            break
        }

        guard let userIndex = userMessageIndex else { return }
        let userMessage = currentConversation.messages[userIndex]

        // Remove all messages from the assistant message onwards
        if let convIndex = conversationManager.conversations.firstIndex(where: {
            $0.id == conversation.id
        }) {
            conversationManager.conversations[convIndex].messages.removeSubrange(assistantIndex...)
            conversationManager.save(conversationManager.conversations[convIndex])
        }

        // Resend the user message
        resendMessage(userMessage)
    }

    /// Switch model and retry
    func switchModelAndRetry(beforeMessage: Message, newModel: String) {
        // Don't update the global conversation model or selected model
        // Just retry with the specified model for this message only
        retryWithModel(beforeMessage: beforeMessage, model: newModel)
    }

    /// Retry with a specific model (without changing conversation's default model)
    func retryWithModel(beforeMessage: Message, model: String) {
        guard !isGenerating else { return }

        // Find the user message that came before this assistant message
        guard
            let assistantIndex = currentConversation.messages.firstIndex(where: {
                $0.id == beforeMessage.id
            }),
            assistantIndex > 0
        else {
            return
        }

        // Find the last user message before this assistant message
        var userMessageIndex: Int?
        for index in (0 ..< assistantIndex).reversed()
            where currentConversation.messages[index].role == .user
        {
            userMessageIndex = index
            break
        }

        guard let userIndex = userMessageIndex else { return }
        let userMessage = currentConversation.messages[userIndex]

        // Remove all messages from the assistant message onwards
        if let convIndex = conversationManager.conversations.firstIndex(where: {
            $0.id == conversation.id
        }) {
            conversationManager.conversations[convIndex].messages.removeSubrange(assistantIndex...)
            conversationManager.save(conversationManager.conversations[convIndex])
        }

        // Resend the user message with the specified model
        resendMessageWithModel(userMessage, model: model)
    }

    /// Resend a message
    func resendMessage(_ message: Message) {
        errorMessage = nil
        isGenerating = true

        // Get updated messages
        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        // Check if current model is for image generation
        let modelCapability = aiService.getModelCapability(updatedConversation.model)

        if modelCapability == .imageGeneration {
            // Image generation flow
            generateImage(prompt: message.content, model: updatedConversation.model)
            return
        }

        let currentMessages = updatedConversation.messages

        // Prepend system prompt if configured
        var messagesToSend = currentMessages
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Add empty assistant message with current model
        let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available tools (Tavily + MCP)
        let tools = aiService.getAllAvailableTools()

        // Reset tool call depth
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }

    /// Resend a message with a specific model (without changing conversation's default model)
    func resendMessageWithModel(_ message: Message, model: String) {
        errorMessage = nil
        isGenerating = true

        // Get updated messages
        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        // Check if specified model is for image generation
        let modelCapability = aiService.getModelCapability(model)

        if modelCapability == .imageGeneration {
            // Image generation flow
            generateImage(prompt: message.content, model: model)
            return
        }

        let currentMessages = updatedConversation.messages

        // Prepend system prompt if configured
        var messagesToSend = currentMessages
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Add empty assistant message with the specified model
        let assistantMessage = Message(role: .assistant, content: "", model: model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available tools (Tavily + MCP)
        let tools = aiService.getAllAvailableTools()

        // Reset tool call depth
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }

    // MARK: - System Prompt Helpers

    /// Builds the full system prompt including agentic capabilities context.
    func buildFullSystemPrompt(for conversation: Conversation) -> String? {
        var components: [String] = []

        // Add user's configured system prompt
        if let userPrompt = conversationManager.effectiveSystemPrompt(for: conversation), !userPrompt.isEmpty {
            components.append(userPrompt)
        }

        // Add agentic tools context if available
        if let agenticContext = aiService.getAgenticSystemPromptContext() {
            components.append(agenticContext)
        }

        return components.isEmpty ? nil : components.joined(separator: "\n\n")
    }
}
