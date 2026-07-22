//
//  WatchChatViewModel.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

import Foundation

/// Deduplicates callbacks for one provider request round and supplies IDs when the provider omits them.
@MainActor
final class WatchToolCallRoundRegistry {
    private struct IDLessCallSignature: Hashable {
        let toolName: String
        let encodedArguments: Data
    }

    private let syntheticIDPrefix: String
    private var registeredIDs: Set<String> = []
    private var registeredIDLessCalls: Set<IDLessCallSignature> = []
    private var nextSyntheticID = 0

    init(roundID: UUID) {
        syntheticIDPrefix = "watch-tool-\(roundID.uuidString.lowercased())"
    }

    /// Returns the provider ID or a stable round-local synthetic ID for a newly observed call.
    /// Identical ID-less callbacks are indistinguishable, so their canonical tool payload is
    /// used as the duplicate key.
    func register(
        providerID: String,
        toolName: String,
        arguments: [String: AnyCodable]
    ) -> String? {
        if !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard registeredIDs.insert(providerID).inserted else { return nil }
            return providerID
        }

        let signature = IDLessCallSignature(
            toolName: toolName,
            encodedArguments: Self.encode(arguments)
        )
        guard registeredIDLessCalls.insert(signature).inserted else { return nil }
        return makeSyntheticID()
    }

    private func makeSyntheticID() -> String {
        while true {
            let candidate = "\(syntheticIDPrefix)-\(nextSyntheticID)"
            nextSyntheticID += 1
            if registeredIDs.insert(candidate).inserted {
                return candidate
            }
        }
    }

    private static func encode(_ arguments: [String: AnyCodable]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(arguments)) ?? Data()
    }
}

#if os(watchOS)

    import Combine
    import os
    import SwiftUI
    import WatchKit

    // swiftlint:disable type_body_length
    /// ViewModel for Watch chat view
    /// Handles message sending, streaming responses, and local state management
    @MainActor
    final class WatchChatViewModel: ObservableObject {
        enum SendResult: Equatable {
            case notConsumed
            case consumed
            case started

            var consumedInput: Bool {
                self != .notConsumed
            }
        }

        struct RequestConfiguration {
            let messages: [Message]
            let model: String
            let temperature: Double
            let conversationID: UUID
        }

        private struct TitleRequestContext {
            let conversationID: UUID
            let fallbackTitle: String
            let expectedTitle: String
            let expectedRevision: UInt64
            let expectedUpdatedAt: Date
        }

        private struct PendingResponsePromotion {
            let conversationID: UUID
            let assistantMessageID: UUID
            let userMessageID: UUID?
            let isFirstMessage: Bool
            let userContent: String
            let finalContent: String
        }

        private enum DraftFinalizationOutcome: Equatable {
            case unavailable
            case discarded
            case promoted
            case promotionPending
        }

        private static let responsePromotionErrorMessage = "Failed to save response. Please try again."

        @Published var isLoading = false
        @Published var isStreaming = false // True once first chunk received
        @Published var errorMessage: String?
        @Published var streamingContent = ""
        @Published var currentToolName: String?
        @Published var failedMessage: String?

        private let conversationStore: WatchConversationStore
        private let connectivityService: WatchConnectivityService
        private let aiService: AIService
        private let requestObserver: ((RequestConfiguration) -> Void)?
        private let toolChainCoordinator = ToolChainCoordinator()
        private let toolCallRequestRoundCoordinator = ToolCallRequestRoundCoordinator<ToolExecutionResult>()
        private var currentConversationId: UUID?
        private var pendingUserMessageId: UUID?
        private var toolCallDepth = 0
        private var activeAssistantMessageId: UUID?
        private var titleRequest: AITextRequest?
        private var titleRequestID: UUID?
        private var titleRequestContext: TitleRequestContext?
        private var pendingResponsePromotions: [UUID: PendingResponsePromotion] = [:]

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
            aiService: AIService = .shared,
            requestObserver: ((RequestConfiguration) -> Void)? = nil
        ) {
            self.conversationStore = conversationStore
            self.connectivityService = connectivityService
            self.aiService = aiService
            self.requestObserver = requestObserver
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
            restorePendingResponsePromotionState(for: id)
        }

        /// Play haptic feedback
        private func playHaptic(_ type: WKHapticType) {
            WKInterfaceDevice.current().play(type)
        }

        /// Send a message in the current conversation.
        ///
        /// - Returns: Whether the composer input was consumed and whether a request started.
        @discardableResult
        func sendMessage(_ content: String) -> SendResult {
            sendMessage(content, reusingUserMessageID: nil)
        }

        private func sendMessage(_ content: String, reusingUserMessageID: UUID?) -> SendResult {
            guard let conversationId = currentConversationId,
                  let conversation = conversationStore.conversation(for: conversationId)
            else {
                errorMessage = "No conversation selected"
                playHaptic(.failure)
                return .notConsumed
            }
            cancelTitleRequest()
            if pendingResponsePromotions[conversationId] != nil,
               !retryPendingResponsePromotion(for: conversationId)
            {
                return .notConsumed
            }

            errorMessage = nil
            failedMessage = nil
            isLoading = true
            isStreaming = false
            streamingContent = ""
            pendingContent = ""
            currentToolName = nil
            toolCallDepth = 0
            lastUIUpdateTime = .distantPast
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
                pendingUserMessageId = userMessage.id
                guard conversationStore.addMessage(userMessage, to: conversationId) else {
                    stopForPreparationError(
                        "Failed to save message. Please try again.",
                        retryContent: userContent
                    )
                    return .notConsumed
                }
                isFirstMessage = conversation.messages.isEmpty
            }
            pendingUserMessageId = userMessage.id

            guard var requestConversation = conversationStore.conversation(for: conversationId) else {
                stopForPreparationError("Failed to update conversation", retryContent: userContent)
                return .consumed
            }

            var model = requestConversation.model
            if aiService.modelProviders[model] == .appleIntelligence {
                let fallback = connectivityService.availableModels.first { candidate in
                    aiService.modelProviders[candidate] != .appleIntelligence &&
                        aiService.isModelConfigured(candidate)
                }
                guard let fallback else {
                    stopForPreparationError(
                        "No compatible models available. Please add a model on iPhone.",
                        retryContent: userContent
                    )
                    return .consumed
                }
                guard conversationStore.updateModel(fallback, for: conversationId),
                      let updated = conversationStore.conversation(for: conversationId)
                else {
                    stopForPreparationError(
                        "Failed to save model selection. Please try again.",
                        retryContent: userContent
                    )
                    return .consumed
                }
                model = fallback
                requestConversation = updated
            }

            guard aiService.isModelConfigured(model) else {
                stopForPreparationError(
                    "API key not configured. Please configure on iPhone.",
                    retryContent: userContent
                )
                return .consumed
            }

            let assistantMessage = WatchMessage(
                from: Message(role: .assistant, content: "", model: model)
            )
            var draft = requestConversation
            draft.messages.append(assistantMessage)
            draft.updatedAt = Date()
            guard conversationStore.syncDraft(draft) else {
                stopForPreparationError(
                    "Failed to save response draft. Please try again.",
                    retryContent: userContent
                )
                return .consumed
            }

            let tools = aiService.getAllAvailableTools()
            sendMessageWithToolSupport(
                messages: requestConversation.effectiveHistory,
                model: model,
                temperature: requestConversation.temperature,
                conversationId: conversationId,
                assistantMessageId: assistantMessage.id,
                tools: tools,
                isFirstMessage: isFirstMessage,
                userContent: userContent
            )
            return .started
        }

        private func stopForPreparationError(_ message: String, retryContent: String?) {
            isLoading = false
            isStreaming = false
            errorMessage = message
            failedMessage = retryContent
            playHaptic(.failure)
        }

        // swiftlint:disable function_body_length
        /// Send message with tool support for recursive tool calling.
        private func sendMessageWithToolSupport( // swiftlint:disable:this function_parameter_count
            messages: [Message],
            model: String,
            temperature: Double,
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
            let registeredToolCalls = WatchToolCallRoundRegistry(roundID: assistantMessageId)
            requestObserver?(
                RequestConfiguration(
                    messages: messages,
                    model: model,
                    temperature: temperature,
                    conversationID: conversationId
                )
            )

            let request = aiService.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: true,
                tools: tools,
                conversationId: conversationId,
                onChunk: { [weak self] chunk in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
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
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
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
                            temperature: temperature,
                            conversationId: conversationId,
                            tools: tools,
                            isFirstMessage: isFirstMessage,
                            userContent: userContent
                        )
                    }
                },
                onError: { [weak self] error in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
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
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                        guard let self,
                              coordinator.owns(operationID, conversationID: conversationId),
                              self.activeAssistantMessageId == assistantMessageId
                        else {
                            return
                        }
                        guard self.conversationStore.conversation(for: conversationId) != nil else {
                            self.stopToolChainForMissingConversation(
                                operationID: operationID,
                                assistantMessageId: assistantMessageId,
                                conversationId: conversationId,
                                userContent: userContent
                            )
                            return
                        }
                        let anyCodableArguments = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                            result[pair.key] = AnyCodable(pair.value)
                        }
                        guard let registeredToolCallID = registeredToolCalls.register(
                            providerID: toolCallID,
                            toolName: toolName,
                            arguments: anyCodableArguments
                        ),
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
                                    conversationId: conversationId,
                                    userContent: userContent
                                )
                                return
                            }
                            self.toolCallDepth += 1
                        }

                        self.currentToolName = toolName
                        self.playHaptic(.click)
                        let toolCall = MCPToolCall(
                            id: registeredToolCallID,
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
                                conversationId: conversationId,
                                userContent: userContent
                            )
                            return
                        }
                        self.executeTool(
                            token: toolToken,
                            callID: registeredToolCallID,
                            toolName: toolName,
                            arguments: arguments,
                            anyCodableArguments: anyCodableArguments,
                            operationID: operationID,
                            assistantMessageId: assistantMessageId,
                            model: model,
                            temperature: temperature,
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
            temperature: Double,
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
                    temperature: temperature,
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
            temperature: Double,
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
                    temperature: temperature,
                    conversationId: conversationId,
                    tools: tools,
                    userContent: userContent
                )
            }
        }

        private func launchToolContinuation( // swiftlint:disable:this function_parameter_count
            _ continuation: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Continuation,
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            model: String,
            temperature: Double,
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

            guard flushPendingContent(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId
            ) else {
                toolChainCoordinator.cancelCurrentOperation()
                failResponsePromotion(
                    makePendingResponsePromotion(
                        assistantMessageId: assistantMessageId,
                        conversationId: conversationId,
                        userContent: userContent,
                        finalContent: pendingContent
                    ),
                    retryPromotion: true
                )
                return
            }
            guard var draft = conversationStore.conversation(for: conversationId) else {
                stopToolChainForMissingConversation(
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId,
                    userContent: userContent
                )
                return
            }

            let results = continuation.toolResults.map(\.result)
            for result in results {
                draft.messages.append(WatchMessage(from: result.makeMessage()))
            }

            let citations = ToolExecutionResult.combinedCitations(from: results)
            var continuationMessageValue = Message(role: .assistant, content: "", model: model)
            continuationMessageValue.citations = citations.isEmpty ? nil : citations
            let continuationMessage = WatchMessage(from: continuationMessageValue)
            draft.messages.append(continuationMessage)
            draft.updatedAt = Date()
            guard conversationStore.syncDraft(draft) else {
                handleToolRequestError(
                    AynaError.fileOperationFailed(
                        operation: "save Watch tool continuation",
                        path: nil
                    ),
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId,
                    userContent: userContent
                )
                return
            }

            guard let updatedConversation = conversationStore.conversation(for: conversationId),
                  toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                stopToolChainForMissingConversation(
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId,
                    userContent: userContent
                )
                return
            }

            let continuationMessages = Array(updatedConversation.effectiveHistory.dropLast())
            streamingContent = ""
            pendingContent = ""
            currentToolName = nil
            lastUIUpdateTime = .distantPast
            sendMessageWithToolSupport(
                messages: continuationMessages,
                model: model,
                temperature: temperature,
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

            attemptResponsePromotion(
                PendingResponsePromotion(
                    conversationID: conversationId,
                    assistantMessageID: assistantMessageId,
                    userMessageID: pendingUserMessageId,
                    isFirstMessage: isFirstMessage,
                    userContent: userContent,
                    finalContent: pendingContent
                )
            )
        }

        @discardableResult
        private func attemptResponsePromotion(_ pending: PendingResponsePromotion) -> Bool {
            guard flushPendingContent(
                assistantMessageId: pending.assistantMessageID,
                conversationId: pending.conversationID,
                finalContent: pending.finalContent
            ) else {
                failResponsePromotion(pending, retryPromotion: true)
                return false
            }

            switch conversationStore.finishDraft(conversationID: pending.conversationID) {
            case let .promoted(conversation):
                completeResponsePromotion(pending, conversation: conversation)
                return true
            case .persistenceFailed:
                failResponsePromotion(pending, retryPromotion: true)
                return false
            case .noDraft, .discardedEmptyDraft:
                failResponsePromotion(pending, retryPromotion: false)
                return false
            }
        }

        private func completeResponsePromotion(
            _ pending: PendingResponsePromotion,
            conversation: WatchConversation
        ) {
            pendingResponsePromotions.removeValue(forKey: pending.conversationID)
            activeAssistantMessageId = nil
            pendingUserMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = nil
            failedMessage = nil
            playHaptic(.success)

            if pending.isFirstMessage, conversation.title == "New Chat" {
                generateTitle(for: pending.conversationID, firstMessage: pending.userContent)
            }

            streamingContent = ""
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "⌚ Response complete",
                metadata: ["conversationId": pending.conversationID.uuidString]
            )
        }

        private func failResponsePromotion(
            _ pending: PendingResponsePromotion,
            retryPromotion: Bool
        ) {
            if retryPromotion {
                pendingResponsePromotions[pending.conversationID] = pending
            } else {
                pendingResponsePromotions.removeValue(forKey: pending.conversationID)
            }
            activeAssistantMessageId = nil
            pendingUserMessageId = pending.userMessageID
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = Self.responsePromotionErrorMessage
            failedMessage = pending.userContent
            playHaptic(.failure)

            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "⌚ Failed to promote response draft",
                metadata: ["conversationId": pending.conversationID.uuidString]
            )
        }

        @discardableResult
        private func retryPendingResponsePromotion(for conversationID: UUID) -> Bool {
            guard let pendingResponsePromotion = pendingResponsePromotions[conversationID] else {
                return true
            }
            errorMessage = nil
            failedMessage = nil
            return attemptResponsePromotion(pendingResponsePromotion)
        }

        private func restorePendingResponsePromotionState(for conversationID: UUID) {
            guard let pending = pendingResponsePromotions[conversationID] else { return }
            pendingUserMessageId = pending.userMessageID
            errorMessage = Self.responsePromotionErrorMessage
            failedMessage = pending.userContent
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
            guard flushPendingContent(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId
            ) else {
                failResponsePromotion(
                    makePendingResponsePromotion(
                        assistantMessageId: assistantMessageId,
                        conversationId: conversationId,
                        userContent: userContent,
                        finalContent: pendingContent
                    ),
                    retryPromotion: true
                )
                return
            }
            activeAssistantMessageId = nil

            if error is CancellationError {
                let finalizationOutcome = finalizeDraftIfNeeded(
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId,
                    userContent: userContent
                )
                isLoading = false
                isStreaming = false
                currentToolName = nil
                toolCallDepth = 0
                if finalizationOutcome != .promotionPending {
                    pendingUserMessageId = nil
                }
                return
            }

            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = ErrorPresenter.userMessage(for: error)
            failedMessage = userContent
            playHaptic(.failure)
            let finalizationOutcome = finalizeDraftIfNeeded(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId,
                userContent: userContent
            )
            if finalizationOutcome == .promoted {
                pendingUserMessageId = nil
            }

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
            conversationId: UUID,
            userContent: String
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
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = "Tool call limit reached. Please try again."
            let finalizationOutcome = finalizeDraftIfNeeded(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId,
                userContent: userContent
            )
            if finalizationOutcome != .promotionPending {
                pendingUserMessageId = nil
            }
            playHaptic(.failure)
        }

        private func stopToolChainForMissingConversation(
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
            let finalizationOutcome = finalizeDraftIfNeeded(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId,
                userContent: userContent
            )
            activeAssistantMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            pendingContent = ""
            if finalizationOutcome != .promotionPending {
                errorMessage = "Failed to update conversation. Please try again."
                failedMessage = userContent
                playHaptic(.failure)
            }
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

        /// Cancel active request work without discarding a completed response promotion retry.
        func cancelRequest() {
            toolChainCoordinator.cancelCurrentOperation {
                finalizeCancelledAssistant()
            }
            cancelTitleRequest()
            activeAssistantMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            if !hasPendingResponsePromotionForCurrentConversation {
                pendingContent = ""
                playHaptic(.click)
            }
        }

        /// Cancels active owned work without producing feedback or discarding promotion retries.
        @discardableResult
        func cancelOwnedRequest() -> Bool {
            let cancelledToolRequest = toolChainCoordinator.cancelCurrentOperation {
                finalizeCancelledAssistant()
            }
            let cancelledTitleRequest = cancelTitleRequest()
            guard cancelledToolRequest || cancelledTitleRequest else { return false }
            activeAssistantMessageId = nil
            isLoading = false
            isStreaming = false
            currentToolName = nil
            toolCallDepth = 0
            if !hasPendingResponsePromotionForCurrentConversation {
                pendingContent = ""
            }
            return true
        }

        private var hasPendingResponsePromotionForCurrentConversation: Bool {
            currentConversationId.map { pendingResponsePromotions[$0] != nil } ?? false
        }

        private func finalizeCancelledAssistant() {
            guard let conversationId = currentConversationId,
                  let assistantMessageId = activeAssistantMessageId
            else {
                return
            }
            guard flushPendingContent(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId
            ) else {
                failResponsePromotion(
                    makePendingResponsePromotion(
                        assistantMessageId: assistantMessageId,
                        conversationId: conversationId,
                        finalContent: pendingContent
                    ),
                    retryPromotion: true
                )
                return
            }
            finalizeDraftIfNeeded(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId
            )
        }

        @discardableResult
        private func finalizeDraftIfNeeded(
            assistantMessageId: UUID,
            conversationId: UUID,
            userContent: String? = nil
        ) -> DraftFinalizationOutcome {
            guard let conversation = conversationStore.conversation(for: conversationId),
                  let messageIndex = conversation.messages.firstIndex(where: { $0.id == assistantMessageId })
            else {
                return .unavailable
            }
            let message = conversation.messages[messageIndex]
            let pendingPromotion = makePendingResponsePromotion(
                assistantMessageId: assistantMessageId,
                conversationId: conversationId,
                userContent: userContent,
                finalContent: message.content
            )

            let hasAssistantState = !message.content.isEmpty ||
                !(message.citations?.isEmpty ?? true) ||
                !(message.toolCalls?.isEmpty ?? true)
            let turnStartIndex = conversation.messages[...messageIndex].lastIndex {
                $0.role == Message.Role.user.rawValue
            } ?? messageIndex
            let hasToolState = conversation.messages[turnStartIndex ... messageIndex].contains {
                $0.role == Message.Role.tool.rawValue || !($0.toolCalls?.isEmpty ?? true)
            }
            if hasToolState, !hasAssistantState {
                var cleaned = conversation
                cleaned.messages.remove(at: messageIndex)
                _ = conversationStore.replaceConversation(cleaned)
            }
            if hasAssistantState || hasToolState {
                switch conversationStore.finishDraft(conversationID: conversationId) {
                case .promoted:
                    return .promoted
                case .noDraft:
                    return .unavailable
                case .discardedEmptyDraft:
                    return .discarded
                case .persistenceFailed:
                    failResponsePromotion(pendingPromotion, retryPromotion: true)
                    return .promotionPending
                }
            } else {
                conversationStore.discardDraft(conversationID: conversationId)
                return .discarded
            }
        }

        private func makePendingResponsePromotion(
            assistantMessageId: UUID,
            conversationId: UUID,
            userContent: String? = nil,
            finalContent: String
        ) -> PendingResponsePromotion {
            let conversation = conversationStore.conversation(for: conversationId)
            let messageIndex = conversation?.messages.firstIndex { $0.id == assistantMessageId }
            let userMessage = messageIndex.flatMap { index in
                conversation?.messages[...index].last { $0.role == Message.Role.user.rawValue }
            }
            let userMessageID = pendingUserMessageId ?? userMessage?.id
            let isFirstMessage = userMessageID.map { conversation?.messages.first?.id == $0 } ?? false
            return PendingResponsePromotion(
                conversationID: conversationId,
                assistantMessageID: assistantMessageId,
                userMessageID: userMessageID,
                isFirstMessage: isFirstMessage,
                userContent: userContent ?? userMessage?.content ?? failedMessage ?? "",
                finalContent: finalContent
            )
        }

        @discardableResult
        private func flushPendingContent(
            assistantMessageId: UUID? = nil,
            conversationId: UUID? = nil,
            finalContent: String? = nil
        ) -> Bool {
            let content = finalContent ?? pendingContent
            guard !content.isEmpty else { return true }
            guard let conversationId = conversationId ?? currentConversationId,
                  let assistantMessageId = assistantMessageId ?? activeAssistantMessageId
            else {
                return false
            }

            streamingContent = content
            guard updateAssistantMessage(
                assistantMessageId,
                in: conversationId,
                content: content
            ) else {
                return false
            }
            if pendingContent == content {
                pendingContent = ""
            }
            return true
        }

        /// Retry the last failed message
        func retryFailedMessage() {
            if let currentConversationId,
               pendingResponsePromotions[currentConversationId] != nil
            {
                _ = retryPendingResponsePromotion(for: currentConversationId)
                return
            }
            guard let message = failedMessage else { return }
            let userMessageID = pendingUserMessageId
            failedMessage = nil
            errorMessage = nil
            if let userMessageID {
                _ = sendMessage(message, reusingUserMessageID: userMessageID)
            } else {
                _ = sendMessage(message)
            }
        }

        /// Hide the current error without discarding a durable response promotion retry.
        func dismissError() {
            pendingUserMessageId = nil
            failedMessage = nil
            errorMessage = nil
        }

        /// Create a new conversation
        func createNewConversation() -> UUID? {
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

            guard let conversation = conversationStore.createConversation(
                model: model,
                resolvedSystemPrompt: connectivityService.defaultSystemPrompt
            ) else {
                errorMessage = "Failed to save conversation. Please try again."
                playHaptic(.failure)
                return nil
            }
            setConversation(conversation.id)
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
            titleRequestContext = TitleRequestContext(
                conversationID: conversationId,
                fallbackTitle: fallbackTitle,
                expectedTitle: conversation.title,
                expectedRevision: conversation.watchRevision,
                expectedUpdatedAt: conversation.updatedAt
            )

            let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(firstMessage.prefix(200))\". Only respond with the title, nothing else."

            let titleMessage = Message(role: .user, content: titlePrompt)
            let request = aiService.sendMessage(
                messages: [titleMessage],
                model: conversation.model,
                stream: false,
                onChunk: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        guard let self, self.canApplyTitleUpdate(requestID) else { return }
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
                    Task { @MainActor [weak self] in
                        guard let self, self.titleRequestID == requestID else { return }
                        self.applyTitleFallbackIfNeeded(requestID)
                        self.finishTitleRequest(requestID)
                    }
                },
                onError: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.titleRequestID == requestID else { return }
                        if self.canApplyTitleUpdate(requestID) {
                            self.conversationStore.renameConversation(conversationId, newTitle: fallbackTitle)
                        }
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
            let context = titleRequestContext
            titleRequest = nil
            titleRequestID = nil
            titleRequestContext = nil

            if let context, canApplyTitleUpdate(context) {
                conversationStore.renameConversation(
                    context.conversationID,
                    newTitle: context.fallbackTitle
                )
            }
            request?.cancel()
            return requestWasActive
        }

        private func applyTitleFallbackIfNeeded(_ requestID: UUID) {
            guard canApplyTitleUpdate(requestID), let context = titleRequestContext else { return }
            conversationStore.renameConversation(
                context.conversationID,
                newTitle: context.fallbackTitle
            )
        }

        private func canApplyTitleUpdate(_ requestID: UUID) -> Bool {
            guard titleRequestID == requestID, let context = titleRequestContext else { return false }
            return canApplyTitleUpdate(context)
        }

        private func canApplyTitleUpdate(_ context: TitleRequestContext) -> Bool {
            guard let conversation = conversationStore.conversation(for: context.conversationID) else {
                return false
            }
            return conversation.title == context.expectedTitle &&
                conversation.watchRevision == context.expectedRevision &&
                conversation.updatedAt == context.expectedUpdatedAt
        }

        private func finishTitleRequest(_ requestID: UUID) {
            guard titleRequestID == requestID else { return }
            titleRequest = nil
            titleRequestID = nil
            titleRequestContext = nil
        }
    }
    // swiftlint:enable type_body_length

#endif
