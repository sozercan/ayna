//
//  WatchChatViewModel.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

import Combine
import Foundation
import os
import SwiftUI

/// ViewModel for Watch chat view
/// Handles message sending, streaming responses, and local state management
@MainActor
final class WatchChatViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var streamingContent = ""

    private let conversationStore: WatchConversationStore
    private let connectivityService: WatchConnectivityService
    private let openAIService: OpenAIService
    private var currentConversationId: UUID?

    init(
        conversationStore: WatchConversationStore = .shared,
        connectivityService: WatchConnectivityService = .shared,
        openAIService: OpenAIService = .shared
    ) {
        self.conversationStore = conversationStore
        self.connectivityService = connectivityService
        self.openAIService = openAIService
    }

    /// Set the current conversation being viewed
    func setConversation(_ id: UUID) {
        currentConversationId = id
        errorMessage = nil
        streamingContent = ""
    }

    /// Send a message in the current conversation
    func sendMessage(_ content: String) {
        guard let conversationId = currentConversationId,
              var conversation = conversationStore.conversation(for: conversationId)
        else {
            errorMessage = "No conversation selected"
            return
        }

        // Clear any previous error
        errorMessage = nil
        isLoading = true
        streamingContent = ""

        // Create user message
        let userMessage = WatchMessage(
            from: Message(role: .user, content: content)
        )

        // Add to local store
        conversationStore.addMessage(userMessage, to: conversationId)

        // Sync to iPhone
        connectivityService.sendMessage(userMessage, conversationId: conversationId)

        // Create placeholder assistant message for streaming
        let assistantMessage = WatchMessage(
            from: Message(role: .assistant, content: "")
        )
        conversationStore.addMessage(assistantMessage, to: conversationId)

        // Get updated conversation with messages
        guard let updatedConversation = conversationStore.conversation(for: conversationId) else {
            isLoading = false
            errorMessage = "Failed to update conversation"
            return
        }

        // Convert to Message array for API
        let messagesForAPI = updatedConversation.messages.dropLast().map { $0.toMessage() }

        // Get model from settings or conversation
        let model = connectivityService.selectedModel.isEmpty
            ? updatedConversation.model
            : connectivityService.selectedModel

        // Check if the model is configured (has API key or doesn't need one like Apple Intelligence)
        guard openAIService.isModelConfigured(model) else {
            isLoading = false
            errorMessage = "API key not configured. Please configure on iPhone."
            return
        }

        // Send to OpenAI
        openAIService.sendMessage(
            messages: Array(messagesForAPI),
            model: model,
            stream: true,
            tools: nil, // No tools on Watch
            conversationId: conversationId,
            onChunk: { [weak self] chunk in
                Task { @MainActor in
                    guard let self else { return }
                    self.streamingContent += chunk
                    self.conversationStore.updateLastMessage(
                        in: conversationId,
                        content: self.streamingContent
                    )
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoading = false

                    // Create final assistant message and sync to iPhone
                    let finalMessage = WatchMessage(
                        from: Message(role: .assistant, content: self.streamingContent)
                    )
                    self.connectivityService.sendMessage(finalMessage, conversationId: conversationId)
                    self.streamingContent = ""

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "⌚ Response complete",
                        metadata: ["conversationId": conversationId.uuidString]
                    )
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription

                    // Remove the empty assistant message
                    if var conv = self.conversationStore.conversation(for: conversationId),
                       !conv.messages.isEmpty
                    {
                        conv.messages.removeLast()
                        self.conversationStore.updateConversations(
                            self.conversationStore.conversations.map { $0.id == conversationId ? conv : $0 }
                        )
                    }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "⌚ Request failed",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            },
            onToolCall: nil,
            onToolCallRequested: nil,
            onReasoning: nil
        )
    }

    /// Cancel the current request
    func cancelRequest() {
        openAIService.cancelCurrentRequest()
        isLoading = false
    }

    /// Create a new conversation
    func createNewConversation() -> UUID {
        let model = connectivityService.selectedModel.isEmpty
            ? (connectivityService.availableModels.first ?? "gpt-4")
            : connectivityService.selectedModel

        let conversation = conversationStore.createConversation(model: model)
        currentConversationId = conversation.id
        return conversation.id
    }
}

#endif
