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
        @Published var errorMessage: String?
        @Published var streamingContent = ""
        @Published var currentToolName: String?

        private let conversationStore: WatchConversationStore
        private let connectivityService: WatchConnectivityService
        private let openAIService: OpenAIService
        private var currentConversationId: UUID?
        private var toolCallDepth = 0
        private let maxToolCallDepth = 5

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
            currentToolName = nil
            toolCallDepth = 0
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
            isLoading = true
            streamingContent = ""
            currentToolName = nil
            toolCallDepth = 0

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
                errorMessage = "Failed to update conversation"
                playHaptic(.failure)
                return
            }

            // Convert to Message array for API
            let messagesForAPI = updatedConversation.messages.dropLast().map { $0.toMessage() }

            // Get model from settings or conversation, but validate it's usable on watchOS
            var model = connectivityService.selectedModel.isEmpty
                ? updatedConversation.model
                : connectivityService.selectedModel

            // Check if the selected model is usable on watchOS
            let provider = openAIService.modelProviders[model]
            if provider == .aikit || provider == .appleIntelligence {
                // Fall back to first usable model
                let usableModels = connectivityService.availableModels.filter { modelName in
                    let modelProvider = openAIService.modelProviders[modelName]
                    return modelProvider != .aikit && modelProvider != .appleIntelligence
                }
                if let fallback = usableModels.first {
                    model = fallback
                } else {
                    isLoading = false
                    errorMessage = "No compatible models available. Please add a model on iPhone."
                    playHaptic(.failure)
                    return
                }
            }

            // Check if the model is configured (has API key or doesn't need one like Apple Intelligence)
            guard openAIService.isModelConfigured(model) else {
                isLoading = false
                errorMessage = "API key not configured. Please configure on iPhone."
                playHaptic(.failure)
                return
            }

            // Get available tools (Tavily web search if configured)
            let tools = openAIService.getAllAvailableTools()

            sendMessageWithToolSupport(
                messages: Array(messagesForAPI),
                model: model,
                conversationId: conversationId,
                tools: tools,
                isFirstMessage: isFirstMessage,
                userContent: userContent
            )
        }

        /// Send message with tool support for recursive tool calling
        private func sendMessageWithToolSupport(
            messages: [Message],
            model: String,
            conversationId: UUID,
            tools: [[String: Any]]?,
            isFirstMessage: Bool,
            userContent: String
        ) {
            openAIService.sendMessage(
                messages: messages,
                model: model,
                stream: true,
                tools: tools,
                conversationId: conversationId,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self else { return }
                        self.streamingContent += chunk
                        self.conversationStore.updateLastMessage(
                            in: conversationId,
                            content: self.streamingContent
                        )
                        // Clear tool indicator when we start receiving content
                        if self.currentToolName != nil {
                            self.currentToolName = nil
                        }
                    }
                },
                onComplete: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }

                        // Only complete if no tool call is pending
                        guard self.currentToolName == nil else {
                            DiagnosticsLogger.log(
                                .chatView,
                                level: .info,
                                message: "⌚ onComplete: keeping isLoading TRUE (tool call pending)",
                                metadata: ["toolName": self.currentToolName ?? "unknown"]
                            )
                            return
                        }

                        self.isLoading = false
                        self.toolCallDepth = 0

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
                        self.isLoading = false
                        self.currentToolName = nil
                        self.toolCallDepth = 0
                        self.errorMessage = error.localizedDescription

                        // Play failure haptic
                        self.playHaptic(.failure)

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
                onToolCallRequested: { [weak self] _, toolName, arguments in
                    Task { @MainActor in
                        guard let self else { return }

                        // Check depth limit
                        guard self.toolCallDepth < self.maxToolCallDepth else {
                            DiagnosticsLogger.log(
                                .chatView,
                                level: .error,
                                message: "⌚ Max tool call depth reached"
                            )
                            self.isLoading = false
                            self.currentToolName = nil
                            self.playHaptic(.failure)
                            return
                        }

                        self.toolCallDepth += 1
                        self.currentToolName = toolName

                        // Play haptic for tool execution
                        self.playHaptic(.click)

                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "⌚ Tool call requested: \(toolName)",
                            metadata: ["toolName": toolName]
                        )

                        // Execute the tool
                        Task {
                            let result: String = if self.openAIService.isBuiltInTool(toolName) {
                                await self.openAIService.executeBuiltInTool(name: toolName, arguments: arguments)
                            } else {
                                "Tool not available on Apple Watch"
                            }

                            await MainActor.run {
                                // Add tool result as a tool message
                                let toolMessage = WatchMessage(
                                    from: Message(role: .tool, content: result)
                                )
                                self.conversationStore.addMessage(toolMessage, to: conversationId)

                                // Add new assistant message placeholder
                                let newAssistantMessage = WatchMessage(
                                    from: Message(role: .assistant, content: "")
                                )
                                self.conversationStore.addMessage(newAssistantMessage, to: conversationId)

                                // Get updated messages
                                guard let updatedConv = self.conversationStore.conversation(for: conversationId) else {
                                    self.isLoading = false
                                    self.currentToolName = nil
                                    return
                                }

                                // Continue with tool result
                                let continuationMessages = updatedConv.messages.dropLast().map { $0.toMessage() }
                                self.streamingContent = ""

                                self.sendMessageWithToolSupport(
                                    messages: Array(continuationMessages),
                                    model: model,
                                    conversationId: conversationId,
                                    tools: tools,
                                    isFirstMessage: false,
                                    userContent: userContent
                                )
                            }
                        }
                    }
                },
                onReasoning: nil
            )
        }

        /// Cancel the current request
        func cancelRequest() {
            openAIService.cancelCurrentRequest()
            isLoading = false
            currentToolName = nil
            toolCallDepth = 0
            playHaptic(.click)
        }

        /// Create a new conversation
        func createNewConversation() -> UUID {
            // Filter to only models usable on watchOS (exclude AIKit and Apple Intelligence)
            let usableModels = connectivityService.availableModels.filter { model in
                let provider = openAIService.modelProviders[model]
                return provider != .aikit && provider != .appleIntelligence
            }

            // Use selected model if it's usable, otherwise pick first usable model
            let selectedModel = connectivityService.selectedModel
            let selectedProvider = openAIService.modelProviders[selectedModel]
            let isSelectedUsable = selectedProvider != .aikit && selectedProvider != .appleIntelligence

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
            var generatedTitle = ""

            openAIService.sendMessage(
                messages: [titleMessage],
                model: conversation.model,
                stream: false,
                onChunk: { chunk in
                    generatedTitle += chunk
                },
                onComplete: { [weak self] in
                    Task { @MainActor in
                        let cleanTitle = generatedTitle
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
