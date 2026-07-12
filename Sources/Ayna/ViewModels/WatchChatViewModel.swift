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

    // swiftlint:disable type_body_length
    /// ViewModel for Watch chat view
    /// Handles message sending, streaming responses, and local state management
    @MainActor
    final class WatchChatViewModel: ObservableObject {
        @Published var isLoading = false
        @Published var isStreaming = false // True once first chunk received
        @Published var errorMessage: String?
        @Published var streamingContent = ""
        @Published var currentToolName: String?
        @Published var failedMessage: String?

        private let conversationStore: WatchConversationStore
        private let connectivityService: WatchConnectivityService
        private let aiService: AIService
        private let toolChainCoordinator = ToolChainCoordinator()
        private let toolCallRequestRoundCoordinator = ToolCallRequestRoundCoordinator<ToolExecutionResult>()
        private var currentConversationId: UUID?
        private var pendingUserMessageId: UUID?
        private var toolCallDepth = 0
        private var activeAssistantMessageId: UUID?
        private var titleRequest: AITextRequest?
        private var titleRequestID: UUID?
        private var titleRequestFallback: (conversationID: UUID, title: String)?

        /// Maximum tool chain depth for watchOS.
        /// Intentionally low (5) due to watchOS resource constraints (memory, battery, network).
        /// Sufficient for simple tool operations while preventing resource exhaustion.
        private let maxToolCallDepth = 5

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
            guard currentConversationId != id else { return }
            if currentConversationId != nil {
                cancelOwnedRequest()
            }
            currentConversationId = id
            errorMessage = nil
            streamingContent = ""
            currentToolName = nil
            toolCallDepth = 0
            activeAssistantMessageId = nil
            failedMessage = nil
            pendingUserMessageId = nil
            pendingContent = ""
        }

        /// Play haptic feedback
        private func playHaptic(_ type: WKHapticType) {
            WKInterfaceDevice.current().play(type)
        }

        /// Send a message in the current conversation
        func sendMessage(_ content: String) {
            sendMessage(content, reusingUserMessageID: nil)
        }

        private func sendMessage(_ content: String, reusingUserMessageID: UUID?) {
            guard let conversationId = currentConversationId else {
                errorMessage = "No conversation selected"
                playHaptic(.failure)
                return
            }
            cancelTitleRequest()
            guard let conversation = conversationStore.conversation(for: conversationId) else {
                errorMessage = "No conversation selected"
                playHaptic(.failure)
                return
            }

            // Clear any previous error
            errorMessage = nil
            failedMessage = nil
            isLoading = true
            isStreaming = false
            streamingContent = ""
            pendingContent = ""
            currentToolName = nil
            toolCallDepth = 0
            lastUIUpdateTime = .distantPast

            // Play haptic for message sent
            playHaptic(.click)

            let userContent = content
            let userMessage: WatchMessage
            let isFirstMessage: Bool
            if let reusingUserMessageID,
               let existingUserMessage = conversation.messages.first(where: {
                   $0.id == reusingUserMessageID && $0.role == Message.Role.user.rawValue
               })
            {
                userMessage = existingUserMessage
                isFirstMessage = conversation.messages.first?.id == reusingUserMessageID
            } else {
                userMessage = WatchMessage(from: Message(role: .user, content: content))
            conversationStore.addMessage(userMessage, to: conversationId)
            connectivityService.sendMessage(userMessage, conversationId: conversationId)
                isFirstMessage = conversation.messages.isEmpty
            }
            pendingUserMessageId = userMessage.id

            // Get updated conversation after committing the user message. Validate the model
            // before adding an assistant placeholder so configuration failures cannot leave a
            // hidden empty turn in local or synced history.
            guard let updatedConversation = conversationStore.conversation(for: conversationId) else {
                isLoading = false
                isStreaming = false
                errorMessage = "Failed to update conversation"
                playHaptic(.failure)
                return
            }

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
                    failedMessage = userContent
                    playHaptic(.failure)
                    return
                }
            }

            // Check if the model is configured (has API key or doesn't need one like Apple Intelligence)
            guard aiService.isModelConfigured(model) else {
                isLoading = false
                isStreaming = false
                errorMessage = "API key not configured. Please configure on iPhone."
                failedMessage = userContent
                playHaptic(.failure)
                return
            }

            let assistantMessage = WatchMessage(from: Message(role: .assistant, content: ""))
            conversationStore.addMessage(assistantMessage, to: conversationId)

            // The validated request history excludes the placeholder just added above.
            let messagesForAPI = updatedConversation.messages.map { $0.toMessage() }

            // Get available tools (Tavily web search if configured)
            let tools = aiService.getAllAvailableTools()

            sendMessageWithToolSupport(
                messages: Array(messagesForAPI),
                model: model,
                conversationId: conversationId,
                assistantMessageId: assistantMessage.id,
                tools: tools,
                isFirstMessage: isFirstMessage,
                userContent: userContent
            )
        }

        // swiftlint:disable function_body_length
        /// Send message with tool support for recursive tool calling.
        private func sendMessageWithToolSupport(
            messages: [Message],
            model: String,
            conversationId: UUID,
            assistantMessageId: UUID,
            tools: [[String: Any]]?,
            isFirstMessage: Bool,
            userContent: String,
            operationID existingOperationID: ToolChainCoordinator.OperationID? = nil
        ) {
            nonisolated(unsafe) let tools = tools
            let coordinator = toolChainCoordinator
            let roundCoordinator = toolCallRequestRoundCoordinator
            let operationID = existingOperationID ?? coordinator.beginOperation(conversationID: conversationId)
            guard coordinator.owns(operationID, conversationID: conversationId),
                  let requestRoundID = roundCoordinator.beginRequestRound(
                      for: operationID,
                      coordinatedBy: coordinator
                  )
            else {
                return
            }
            activeAssistantMessageId = assistantMessageId

            let request = aiService.sendMessage(
                messages: messages,
                model: model,
                stream: true,
                tools: tools,
                conversationId: conversationId,
                onChunk: { [weak self] chunk in
                    MainActor.assumeIsolated {
                        guard let self,
                              coordinator.owns(operationID, conversationID: conversationId),
                              self.activeAssistantMessageId == assistantMessageId
                        else {
                            return
                        }
                        if !self.isStreaming {
                            self.isStreaming = true
                        }
                        self.pendingContent += chunk

                        let now = Date()
                        if now.timeIntervalSince(self.lastUIUpdateTime) >= self.uiUpdateInterval {
                            self.streamingContent = self.pendingContent
                            self.updateAssistantMessage(
                                assistantMessageId,
                                in: conversationId,
                                content: self.streamingContent
                            )
                            self.lastUIUpdateTime = now
                        }
                            self.currentToolName = nil
                        }
                },
                onComplete: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              coordinator.owns(operationID, conversationID: conversationId),
                              self.activeAssistantMessageId == assistantMessageId
                        else {
                            return
                        }
                        let resolution = roundCoordinator.providerDidComplete(
                            operationID: operationID,
                            requestRoundID: requestRoundID
                        )
                        self.handleToolRoundResolution(
                            resolution,
                            operationID: operationID,
                            assistantMessageId: assistantMessageId,
                            model: model,
                            conversationId: conversationId,
                            tools: tools,
                            isFirstMessage: isFirstMessage,
                            userContent: userContent
                        )
                    }
                },
                onError: { [weak self] error in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.handleToolRequestError(
                            error,
                            operationID: operationID,
                            assistantMessageId: assistantMessageId,
                            conversationId: conversationId,
                            userContent: userContent
                        )
                    }
                },
                onToolCall: nil,
                onToolCallRequested: { [weak self] toolCallID, toolName, arguments in
                    nonisolated(unsafe) let arguments = arguments
                    MainActor.assumeIsolated {
                        guard let self,
                              coordinator.owns(operationID, conversationID: conversationId),
                              self.activeAssistantMessageId == assistantMessageId,
                              self.conversationStore.conversation(for: conversationId) != nil,
                              let toolToken = roundCoordinator.registerTool(
                                  for: operationID,
                                  requestRoundID: requestRoundID
                            )
                        else {
                            return
                        }

                        if toolToken.registrationIndex == 0 {
                            guard self.toolCallDepth < self.maxToolCallDepth else {
                                self.stopToolChainAtDepthLimit(
                                    operationID: operationID,
                                    assistantMessageId: assistantMessageId,
                                    conversationId: conversationId
                            )
                                return
                            }
                            self.toolCallDepth += 1
                        }

                        self.currentToolName = toolName
                        self.playHaptic(.click)
                        let anyCodableArguments = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                            result[pair.key] = AnyCodable(pair.value)
                        }
                        let toolCall = MCPToolCall(
                            id: toolCallID,
                            toolName: toolName,
                            arguments: anyCodableArguments
                        )
                        guard self.appendToolCall(
                            toolCall,
                            to: assistantMessageId,
                            in: conversationId
                        ) else {
                            self.stopToolChainForMissingConversation(
                                operationID: operationID,
                                assistantMessageId: assistantMessageId,
                                conversationId: conversationId
                            )
                            return
                        }
                        self.executeTool(
                            token: toolToken,
                            callID: toolCallID,
                            toolName: toolName,
                            arguments: arguments,
                            anyCodableArguments: anyCodableArguments,
                            operationID: operationID,
                            assistantMessageId: assistantMessageId,
                            model: model,
                            conversationId: conversationId,
                            tools: tools,
                            userContent: userContent
                        )
                    }
                },
                onReasoning: nil
            )
            coordinator.onCancel(for: operationID) {
                request.cancel()
            }
        }

        // swiftlint:enable function_body_length

        // swiftlint:disable:next function_parameter_count
        private func executeTool(
            token: ToolCallRequestRoundCoordinator<ToolExecutionResult>.ToolToken,
            callID: String,
            toolName: String,
            arguments: [String: Any],
            anyCodableArguments: [String: AnyCodable],
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            model: String,
            conversationId: UUID,
            tools: [[String: Any]]?,
            userContent: String
        ) {
            nonisolated(unsafe) let arguments = arguments
            nonisolated(unsafe) let tools = tools
            let coordinator = toolChainCoordinator
            let roundCoordinator = toolCallRequestRoundCoordinator
            coordinator.schedule(for: operationID, conversationID: conversationId) { [weak self] in
                guard let self,
                      coordinator.owns(operationID, conversationID: conversationId),
                      self.activeAssistantMessageId == assistantMessageId
                else {
                    return
                }

                            DiagnosticsLogger.log(
                                .chatView,
                                level: .info,
                    message: "⌚ Tool call requested: \(toolName)",
                    metadata: ["toolName": toolName]
                            )
                let output: String
                let citations: [CitationReference]?
                if self.aiService.isBuiltInTool(toolName) {
                    (output, citations) = await self.aiService.executeBuiltInToolWithCitations(
                        name: toolName,
                        arguments: arguments
                                )
                } else {
                    output = "Tool not available on Apple Watch"
                    citations = nil
                            }
                guard coordinator.owns(operationID, conversationID: conversationId),
                      self.activeAssistantMessageId == assistantMessageId,
                      !Task.isCancelled
                else {
                            return
                        }

                let result = ToolExecutionResult(
                    callID: callID,
                    toolName: toolName,
                    arguments: anyCodableArguments,
                    output: output,
                    citations: citations ?? []
                )
                let resolution = roundCoordinator.toolDidComplete(token, result: result)
                self.handleToolRoundResolution(
                    resolution,
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    model: model,
                    conversationId: conversationId,
                    tools: tools,
                    isFirstMessage: false,
                    userContent: userContent
                )
            }
        }

        // swiftlint:disable:next function_parameter_count
        private func handleToolRoundResolution(
            _ resolution: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Resolution,
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            model: String,
            conversationId: UUID,
            tools: [[String: Any]]?,
            isFirstMessage: Bool,
            userContent: String
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                return
            }

            switch resolution {
            case .pending, .ignored:
                return
            case .responseCompleted:
                finishToolSupportedResponse(
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId,
                    isFirstMessage: isFirstMessage,
                    userContent: userContent
                )
            case let .launchContinuation(continuation):
                launchToolContinuation(
                    continuation,
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    model: model,
                    conversationId: conversationId,
                    tools: tools,
                    userContent: userContent
                )
            }
        }

        private func launchToolContinuation(
            _ continuation: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Continuation,
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            model: String,
            conversationId: UUID,
            tools: [[String: Any]]?,
            userContent: String
        ) {
            guard continuation.operationID == operationID,
                  toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                return
            }

            if let assistantToolCallMessage = conversationStore.conversation(for: conversationId)?
                .messages.first(where: { $0.id == assistantMessageId })
                        {
                connectivityService.sendMessage(assistantToolCallMessage, conversationId: conversationId)
                            }

            let results = continuation.toolResults.map(\.result)
            for result in results {
                let toolMessage = WatchMessage(from: result.makeMessage())
                conversationStore.addMessage(toolMessage, to: conversationId)
                connectivityService.sendMessage(toolMessage, conversationId: conversationId)
                        }

            let citations = ToolExecutionResult.combinedCitations(from: results)
            var continuation = Message(role: .assistant, content: "", model: model)
            continuation.citations = citations.isEmpty ? nil : citations
            let continuationMessage = WatchMessage(from: continuation)
            conversationStore.addMessage(continuationMessage, to: conversationId)

            guard let updatedConversation = conversationStore.conversation(for: conversationId),
                  toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                stopToolChainForMissingConversation(
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId
                        )
                return
                    }

            let continuationMessages = updatedConversation.messages.dropLast().map { $0.toMessage() }
            streamingContent = ""
            pendingContent = ""
            currentToolName = nil
            lastUIUpdateTime = .distantPast
            sendMessageWithToolSupport(
                messages: Array(continuationMessages),
                model: model,
                conversationId: conversationId,
                assistantMessageId: continuationMessage.id,
                tools: tools,
                isFirstMessage: false,
                userContent: userContent,
                operationID: operationID
                            )
        }

        private func finishToolSupportedResponse(
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            conversationId: UUID,
            isFirstMessage: Bool,
            userContent: String
        ) {
            guard activeAssistantMessageId == assistantMessageId,
                  toolChainCoordinator.finishOperation(operationID)
            else {
                            return
                        }

            if !pendingContent.isEmpty {
                streamingContent = pendingContent
                updateAssistantMessage(
                    assistantMessageId,
                    in: conversationId,
                    content: streamingContent
                )
            }
            conversationStore.persistCurrentState()
            pendingContent = ""
            activeAssistantMessageId = nil
            pendingUserMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            playHaptic(.success)

            if let finalMessage = conversationStore.conversation(for: conversationId)?
                .messages.first(where: { $0.id == assistantMessageId })
            {
                connectivityService.sendMessage(finalMessage, conversationId: conversationId)
            }

            if isFirstMessage,
               let conversation = conversationStore.conversation(for: conversationId),
               conversation.title == "New Chat"
            {
                generateTitle(for: conversationId, firstMessage: userContent)
            }

            streamingContent = ""
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                message: "⌚ Response complete",
                metadata: ["conversationId": conversationId.uuidString]
                        )
        }

        private func handleToolRequestError(
            _ error: Error,
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            conversationId: UUID,
            userContent: String
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                return
                            }
            toolChainCoordinator.cancelCurrentOperation()
            activeAssistantMessageId = nil

            if error is CancellationError {
                if !pendingContent.isEmpty {
                    streamingContent = pendingContent
                    updateAssistantMessage(
                        assistantMessageId,
                        in: conversationId,
                        content: streamingContent
                            )
                }
                conversationStore.persistCurrentState()
                isLoading = false
                isStreaming = false
                currentToolName = nil
                toolCallDepth = 0
                pendingUserMessageId = nil
                pendingContent = ""
                return
            }

            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = ErrorPresenter.userMessage(for: error)
            failedMessage = userContent
            playHaptic(.failure)
            pendingContent = ""
            removeMessage(assistantMessageId, from: conversationId)

            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "⌚ Request failed",
                metadata: ["error": ErrorPresenter.userMessage(for: error)]
                            )
        }

        private func stopToolChainAtDepthLimit(
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            conversationId: UUID
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                                return
                            }
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "⌚ Max tool call depth reached"
            )
            toolChainCoordinator.cancelCurrentOperation()
            activeAssistantMessageId = nil
            pendingUserMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = "Tool call limit reached. Please try again."
            removeMessage(assistantMessageId, from: conversationId)
            playHaptic(.failure)
        }

        private func stopToolChainForMissingConversation(
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            conversationId: UUID
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                return
            }
            toolChainCoordinator.cancelCurrentOperation()
            activeAssistantMessageId = nil
            pendingUserMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            pendingContent = ""
        }

        private func appendToolCall(
            _ toolCall: MCPToolCall,
            to messageId: UUID,
            in conversationId: UUID
        ) -> Bool {
            guard var conversation = conversationStore.conversation(for: conversationId),
                  let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageId })
            else {
                return false
            }
            var calls = conversation.messages[messageIndex].toolCalls ?? []
            if !calls.contains(where: { $0.id == toolCall.id }) {
                calls.append(toolCall)
            }
            conversation.messages[messageIndex].toolCalls = calls
            return conversationStore.replaceConversation(conversation)
        }

        @discardableResult
        private func updateAssistantMessage(
            _ messageId: UUID,
            in conversationId: UUID,
            content: String
        ) -> Bool {
            guard var conversation = conversationStore.conversation(for: conversationId),
                  let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageId })
            else {
                return false
                        }
            conversation.messages[messageIndex].content = content
            return conversationStore.replaceConversation(conversation)
                    }

        private func removeMessage(_ messageId: UUID, from conversationId: UUID) {
            guard var conversation = conversationStore.conversation(for: conversationId),
                  let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageId })
            else {
                return
            }
            conversation.messages.remove(at: messageIndex)
            _ = conversationStore.replaceConversation(conversation)
        }

        /// Cancel the current request
        func cancelRequest() {
            flushPendingContent()
            finalizeCancelledAssistant()
            toolChainCoordinator.cancelCurrentOperation()
            cancelTitleRequest()
            activeAssistantMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            pendingContent = ""
            playHaptic(.click)
        }

        /// Cancels work owned by this view model without producing user feedback.
        func cancelOwnedRequest() {
            flushPendingContent()
            finalizeCancelledAssistant()
            let cancelledToolRequest = toolChainCoordinator.cancelCurrentOperation()
            let cancelledTitleRequest = cancelTitleRequest()
            guard cancelledToolRequest || cancelledTitleRequest else { return }
            activeAssistantMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            pendingContent = ""
        }

        private func finalizeCancelledAssistant() {
            guard let conversationId = currentConversationId,
                  let assistantMessageId = activeAssistantMessageId,
                  let message = conversationStore.conversation(for: conversationId)?
                  .messages.first(where: { $0.id == assistantMessageId })
            else {
                return
            }

            if message.content.isEmpty, message.citations?.isEmpty ?? true {
                removeMessage(assistantMessageId, from: conversationId)
            } else {
                conversationStore.persistCurrentState()
                connectivityService.sendMessage(message, conversationId: conversationId)
            }
        }

        private func flushPendingContent() {
            guard let conversationId = currentConversationId,
                  let assistantMessageId = activeAssistantMessageId,
                  !pendingContent.isEmpty
            else {
                return
            }

            streamingContent = pendingContent
            _ = updateAssistantMessage(
                assistantMessageId,
                in: conversationId,
                content: streamingContent
            )
            conversationStore.persistCurrentState()
            pendingContent = ""
        }

        /// Retry the last failed message
        func retryFailedMessage() {
            guard let message = failedMessage,
                  let userMessageID = pendingUserMessageId
            else {
                return
            }
            failedMessage = nil
            errorMessage = nil
            sendMessage(message, reusingUserMessageID: userMessageID)
        }

        /// Clear the failed message without retrying.
        func dismissError() {
            pendingUserMessageId = nil
            failedMessage = nil
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
            cancelTitleRequest()
            let requestID = UUID()
            let fallbackTitle = String(firstMessage.prefix(30)) + (firstMessage.count > 30 ? "..." : "")
            titleRequestID = requestID
            titleRequestFallback = (conversationId, fallbackTitle)

            let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(firstMessage.prefix(200))\". Only respond with the title, nothing else."

            let titleMessage = Message(role: .user, content: titlePrompt)
            let request = aiService.sendMessage(
                messages: [titleMessage],
                model: conversation.model,
                stream: false,
                onChunk: { [weak self] chunk in
                    MainActor.assumeIsolated {
                        guard let self, self.titleRequestID == requestID else { return }
                        let cleanTitle = chunk
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "\n", with: " ")

                        if !cleanTitle.isEmpty {
                            self.conversationStore.renameConversation(conversationId, newTitle: cleanTitle)
                        } else {
                            // Fallback to simple title
                            self.conversationStore.renameConversation(conversationId, newTitle: fallbackTitle)
                        }
                    }
                },
                onComplete: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.titleRequestID == requestID else { return }
                        self.applyTitleFallbackIfNeeded(requestID)
                        self.finishTitleRequest(requestID)
                    }
                },
                onError: { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.titleRequestID == requestID else { return }
                        // Fallback to simple title on error
                        self.conversationStore.renameConversation(conversationId, newTitle: fallbackTitle)
                        self.finishTitleRequest(requestID)
                    }
                },
                onReasoning: nil
            )
            if titleRequestID == requestID {
                titleRequest = request
            } else {
                request.cancel()
            }
        }

        @discardableResult
        private func cancelTitleRequest() -> Bool {
            let request = titleRequest
            let requestWasActive = request != nil || titleRequestID != nil
            let fallback = titleRequestFallback
            titleRequest = nil
            titleRequestID = nil
            titleRequestFallback = nil

            if let fallback,
               conversationStore.conversation(for: fallback.conversationID)?.title == "New Chat"
            {
                conversationStore.renameConversation(fallback.conversationID, newTitle: fallback.title)
            }
            request?.cancel()
            return requestWasActive
        }

        private func applyTitleFallbackIfNeeded(_ requestID: UUID) {
            guard titleRequestID == requestID,
                  let fallback = titleRequestFallback,
                  conversationStore.conversation(for: fallback.conversationID)?.title == "New Chat"
            else {
                return
            }
            conversationStore.renameConversation(fallback.conversationID, newTitle: fallback.title)
        }

        private func finishTitleRequest(_ requestID: UUID) {
            guard titleRequestID == requestID else { return }
            titleRequest = nil
            titleRequestID = nil
            titleRequestFallback = nil
        }
    }
    // swiftlint:enable type_body_length

#endif
