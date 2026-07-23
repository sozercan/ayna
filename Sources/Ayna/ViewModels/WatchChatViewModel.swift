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
    import WatchKit

    /// ViewModel for Watch chat view
    /// Handles message sending, streaming responses, and local state management
    @MainActor
    final class WatchChatViewModel: ObservableObject {
        @Published var isLoading = false
        @Published var isStreaming = false // True once first chunk received
        @Published var errorMessage: String?
        @Published var streamingContent = ""
        @Published var failedMessage: String?
        private var failedMessageId: UUID?

        private let conversationStore: WatchConversationStore
        private let connectivityService: WatchConnectivityService
        private let aiService: AIService
        private var currentConversationId: UUID?

        // Streaming throttle for performance
        private var lastUIUpdateTime: Date = .distantPast
        private let uiUpdateInterval: TimeInterval = 0.1 // 100ms throttle
        private var pendingContent = ""

        init(
            conversationStore: WatchConversationStore = .shared,
            connectivityService: WatchConnectivityService = .shared,
            aiService: AIService = .shared
        ) {
            self.conversationStore = conversationStore
            self.connectivityService = connectivityService
            self.aiService = aiService
        }

        /// Set the current conversation being viewed
        func setConversation(_ id: UUID) {
            currentConversationId = id
            errorMessage = nil
            streamingContent = ""
            failedMessage = nil
            failedMessageId = nil
            pendingContent = ""
        }

        /// Play haptic feedback
        private func playHaptic(_ type: WKHapticType) {
            WKInterfaceDevice.current().play(type)
        }

        /// Send a message in the current conversation
        func sendMessage(_ content: String) {
            guard let conversationId = currentConversationId,
                  let conversation = conversationStore.conversation(for: conversationId)
            else {
                errorMessage = "No conversation selected"
                playHaptic(.failure)
                return
            }

            // Clear any previous error
            errorMessage = nil
            failedMessage = nil
            failedMessageId = nil
            isLoading = true
            isStreaming = false
            streamingContent = ""
            pendingContent = ""
            lastUIUpdateTime = .distantPast

            // Play haptic for message sent
            playHaptic(.click)

            // Check if this is the first user message (for title generation later)
            let isFirstMessage = conversation.messages.isEmpty
            let userContent = content // Capture for closure

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
                isStreaming = false
                errorMessage = "Failed to update conversation"
                playHaptic(.failure)
                return
            }

            // Convert to Message array for API, excluding the UI-only assistant placeholder
            let messagesForAPI = ChatTurnRequestPlan.messages(
                from: updatedConversation.messages.map { $0.toMessage() },
                systemPrompt: nil,
                excludingAssistantPlaceholderId: assistantMessage.id
            )

            // Get model from settings or conversation, but validate it's usable on watchOS
            var model = connectivityService.selectedModel.isEmpty
                ? updatedConversation.model
                : connectivityService.selectedModel

            // Check if the selected model is usable on watchOS
            let provider = aiService.modelProviders[model]
            if provider == .appleIntelligence {
                // Fall back to first usable model
                let usableModels = connectivityService.availableModels.filter { modelName in
                    let modelProvider = aiService.modelProviders[modelName]
                    return modelProvider != .appleIntelligence
                }
                if let fallback = usableModels.first {
                    model = fallback
                } else {
                    isLoading = false
                    isStreaming = false
                    errorMessage = "No compatible models available. Please add a model on iPhone."
                    playHaptic(.failure)
                    return
                }
            }

            // Check if the model is configured (has API key or doesn't need one like Apple Intelligence)
            guard aiService.isModelConfigured(model) else {
                isLoading = false
                isStreaming = false
                errorMessage = "API key not configured. Please configure on iPhone."
                playHaptic(.failure)
                return
            }

            sendStreamingMessage(
                messages: Array(messagesForAPI),
                model: model,
                conversationId: conversationId,
                isFirstMessage: isFirstMessage,
                userContent: userContent,
                failedUserMessageId: userMessage.id,
                assistantPlaceholderId: assistantMessage.id,
                failedUserMessagePolicy: .removeForRetry
            )
        }

        /// Send a streaming message request.
        private func sendStreamingMessage( // swiftlint:disable:this function_body_length
            messages: [Message],
            model: String,
            conversationId: UUID,
            isFirstMessage: Bool,
            userContent: String,
            failedUserMessageId: UUID?,
            assistantPlaceholderId: UUID?,
            failedUserMessagePolicy: ChatTurnFailurePlan.FailedUserMessagePolicy
        ) {
            aiService.sendMessage(
                messages: messages,
                model: model,
                stream: true,
                tools: nil,
                conversationId: conversationId,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self else { return }

                        // Mark as streaming once we receive the first chunk
                        if !self.isStreaming {
                            self.isStreaming = true
                        }

                        self.pendingContent += chunk

                        // Throttle UI updates for better performance on Watch
                        let now = Date()
                        if now.timeIntervalSince(self.lastUIUpdateTime) >= self.uiUpdateInterval {
                            self.streamingContent = self.pendingContent
                            self.conversationStore.updateLastMessage(
                                in: conversationId,
                                content: self.streamingContent
                            )
                            self.lastUIUpdateTime = now
                        }

                    }
                },
                onComplete: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }


                        // Flush any remaining pending content
                        if !self.pendingContent.isEmpty {
                            self.streamingContent = self.pendingContent
                            self.conversationStore.updateLastMessage(
                                in: conversationId,
                                content: self.streamingContent
                            )
                        }
                        self.conversationStore.persistCurrentState()
                        self.pendingContent = ""

                        self.isLoading = false
                        self.isStreaming = false

                        // Play success haptic
                        self.playHaptic(.success)

                        // Create final assistant message and sync to iPhone
                        let finalMessage = WatchMessage(
                            from: Message(role: .assistant, content: self.streamingContent)
                        )
                        self.connectivityService.sendMessage(finalMessage, conversationId: conversationId)

                        // Generate title if this was the first message
                        if isFirstMessage,
                           let conv = self.conversationStore.conversation(for: conversationId),
                           conv.title == "New Chat"
                        {
                            self.generateTitle(for: conversationId, firstMessage: userContent)
                        }

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

                        // Handle cancellation silently - don't show error UI for user-initiated cancels
                        if error is CancellationError {
                            DiagnosticsLogger.log(
                                .chatView,
                                level: .info,
                                message: "⌚ Request cancelled"
                            )
                            if !self.pendingContent.isEmpty {
                                self.streamingContent = self.pendingContent
                                self.conversationStore.updateLastMessage(
                                    in: conversationId,
                                    content: self.streamingContent
                                )
                            }
                            self.conversationStore.persistCurrentState()
                            self.isLoading = false
                            self.isStreaming = false
                            self.pendingContent = ""
                            return
                        }

                        self.isLoading = false
                        self.isStreaming = false
                        self.errorMessage = ErrorPresenter.userMessage(for: error)

                        // Apply shared failure cleanup policy for this turn.
                        self.pendingContent = ""
                        if var conv = self.conversationStore.conversation(for: conversationId) {
                            let plan = ChatTurnFailurePlan(
                                messages: conv.messages.map { $0.toMessage() },
                                failedUserMessageId: failedUserMessageId,
                                assistantPlaceholderId: assistantPlaceholderId,
                                failedUserMessagePolicy: failedUserMessagePolicy
                            )
                            self.failedMessage = plan.retryPrompt
                            self.failedMessageId = plan.retryPrompt == nil ? nil : failedUserMessageId
                            conv.messages = plan.messagesAfterFailure.map { WatchMessage(from: $0) }
                            _ = self.conversationStore.replaceConversation(conv)
                        } else {
                            self.failedMessage = nil
                            self.failedMessageId = nil
                        }

                        // Play failure haptic
                        self.playHaptic(.failure)

                        DiagnosticsLogger.log(
                            .chatView,
                            level: .error,
                            message: "⌚ Request failed",
                            metadata: ["error": ErrorPresenter.userMessage(for: error)]
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
            aiService.cancelCurrentRequest()
            isLoading = false
            isStreaming = false
            playHaptic(.click)
        }

        /// Retry the last failed message
        func retryFailedMessage() {
            guard let message = failedMessage else { return }
            let messageId = failedMessageId
            failedMessage = nil
            failedMessageId = nil
            errorMessage = nil

            if let messageId,
               let conversationId = currentConversationId,
               var conversation = conversationStore.conversation(for: conversationId)
            {
                conversation.messages.removeAll { $0.id == messageId }
                _ = conversationStore.replaceConversation(conversation)
            }

            sendMessage(message)
        }

        /// Clear the failed message without retrying
        func dismissError() {
            failedMessage = nil
            failedMessageId = nil
            errorMessage = nil
        }

        /// Create a new conversation
        func createNewConversation() -> UUID {
            // Filter to only models usable on watchOS (exclude Apple Intelligence)
            let usableModels = connectivityService.availableModels.filter { model in
                let provider = aiService.modelProviders[model]
                return provider != .appleIntelligence
            }

            // Use selected model if it's usable, otherwise pick first usable model
            let selectedModel = connectivityService.selectedModel
            let selectedProvider = aiService.modelProviders[selectedModel]
            let isSelectedUsable = selectedProvider != .appleIntelligence

            let model: String = if !selectedModel.isEmpty, isSelectedUsable {
                selectedModel
            } else {
                usableModels.first ?? "gpt-4"
            }

            let conversation = conversationStore.createConversation(model: model)
            currentConversationId = conversation.id
            playHaptic(.click)
            return conversation.id
        }

        /// Generate a title for the conversation using AI
        private func generateTitle(for conversationId: UUID, firstMessage: String) {
            guard let conversation = conversationStore.conversation(for: conversationId) else { return }

            let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(firstMessage.prefix(200))\". Only respond with the title, nothing else."

            let titleMessage = Message(role: .user, content: titlePrompt)
            aiService.sendMessage(
                messages: [titleMessage],
                model: conversation.model,
                stream: false,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        let cleanTitle = chunk
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "\n", with: " ")

                        if !cleanTitle.isEmpty {
                            self?.conversationStore.renameConversation(conversationId, newTitle: cleanTitle)
                        } else {
                            // Fallback to simple title
                            let fallback = String(firstMessage.prefix(30)) + (firstMessage.count > 30 ? "..." : "")
                            self?.conversationStore.renameConversation(conversationId, newTitle: fallback)
                        }
                    }
                },
                onComplete: { },
                onError: { [weak self] _ in
                    Task { @MainActor in
                        // Fallback to simple title on error
                        let fallback = String(firstMessage.prefix(30)) + (firstMessage.count > 30 ? "..." : "")
                        self?.conversationStore.renameConversation(conversationId, newTitle: fallback)
                    }
                },
                onReasoning: nil
            )
        }
    }

#endif
