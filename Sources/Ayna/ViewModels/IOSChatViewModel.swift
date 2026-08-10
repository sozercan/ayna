// swiftlint:disable file_length
//
//  IOSChatViewModel.swift
//  ayna
//
//  Created on 11/24/25.
//

#if os(iOS)

import Combine
import Foundation
import os.log
import PhotosUI
import SwiftUI

/// A wrapper to make non-Sendable types Sendable by unchecked conformance.
/// Use this only when you are sure the value is thread-safe or accessed safely.
private struct UncheckedSendable<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T
    nonisolated init(_ value: T) {
        self.value = value
    }
}

typealias IOSBuiltInToolExecutor = @MainActor (
    _ name: String,
    _ arguments: [String: Any]
) async -> (String, [CitationReference]?)

/// IOSChatViewModel consolidates iOS chat logic to avoid duplicating state across views.
/// A shared ViewModel that encapsulates common chat logic for iOS views.
/// Used by both `IOSChatView` (existing conversations) and `IOSNewChatView` (new conversations).
@MainActor final class IOSChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messageText = ""
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var attachedFiles: [URL] = []
    @Published var attachedImages: [UIImage] = []
    @Published private(set) var messageContentRevision = 0

    /// The name of the tool currently being executed (for UI indicator)
    @Published var currentToolName: String?

    /// The last failed message content, stored for retry functionality
    @Published var failedMessage: String?

    /// Recovery suggestion for the current error (if available)
    @Published var errorRecoverySuggestion: String?

    // MARK: - Dependencies

    var conversationManager: ConversationManager
    let aiService: AIService
    private let executeBuiltInTool: IOSBuiltInToolExecutor
    private let imageGenerationCoordinator = ImageGenerationCoordinator()
        private let toolChainCoordinator = ToolChainCoordinator()
        private let toolCallRequestRoundCoordinator = ToolCallRequestRoundCoordinator<ToolExecutionResult>()

    // MARK: - Tool Call State

    /// Tracks the depth of recursive tool calls to prevent infinite loops
    private var toolCallDepth = 0
        private var activeAssistantMessageId: UUID?
        private var activeMultiModelResponseGroupId: UUID?
        private var pendingAutoSendTask: Task<Void, Never>?
        private var pendingAutoSendID: UUID?
        private var pendingAutoSendDraft: String?
        private var pendingAutoSendConversationID: UUID?
        private var sendPreparationTask: Task<Void, Never>?
        private var sendPreparationID: UUID?
        var sendPreparationDidFinish: (@MainActor () -> Void)?
        var multiModelChunkWillProcess: (@MainActor () -> Void)?
        private var isProcessingMultiModelChunkCallback = false
        private var pendingResetForNewChat = false

    /// Maximum tool chain depth for iOS.
    /// Lower than macOS (25) due to mobile resource constraints and typical mobile use cases.
    /// This prevents runaway tool chains while still allowing reasonable agentic workflows.
    private let maxToolCallDepth = 10

    /// Stores the pending user message text for retry on failure
    private var pendingUserMessage: String?

    private struct StreamingChunkKey: Hashable, Sendable {
        let conversationId: UUID
        let messageId: UUID
        let model: String?
    }

    private struct PendingChunkBuffer {
        var chunks: [String] = []
        var pendingCharacterCount = 0
        var flushTask: Task<Void, Never>?
    }

    private var pendingChunkBuffers: [StreamingChunkKey: PendingChunkBuffer] = [:]
    private let streamingChunkFlushInterval: Duration = .milliseconds(75)
    private let streamingChunkImmediateFlushThreshold = 256
    private let multiModelReasoningBuffer = MultiModelStreamingBuffer()

    private struct ToolExecutionState {
        let token: ToolCallRequestRoundCoordinator<ToolExecutionResult>.ToolToken
        let conversationId: UUID
        let callId: String
        let toolName: String
        let arguments: [String: AnyCodable]
        var result: ToolExecutionResult?
    }

    private struct SendPreparation {
        let draftText: String
        let text: String
        let attachedFiles: [URL]
        let attachedImages: [UIImage]
        let selectedModel: String
        let selectedModels: Set<String>
        let requestModel: String
    }

    private var toolExecutionStates: [
        ToolCallRequestRoundCoordinator<ToolExecutionResult>.ToolToken: ToolExecutionState
    ] = [:]

    // MARK: - Configuration

    /// The conversation ID this view model is managing.
    /// For new chats, this starts as nil and gets set when first message is sent.
    var conversationId: UUID?

    /// Whether this is a "new chat" view model (creates conversation on first message).
    let isNewChatMode: Bool

    /// Selected model for new chats (ignored for existing conversations).
    @Published var selectedModel: String

    /// Selected models for multi-model chat
    @Published var selectedModels: Set<String> = []

    /// Callback when a new conversation is created and first response completes.
    /// Used by IOSNewChatView to navigate to IOSChatView.
    var onConversationCreated: ((UUID) -> Void)?

    // MARK: - Initialization

    /// Create a placeholder ViewModel for use with @StateObject.
    /// Must call `configure(with:conversationId:)` in onAppear.
    static func placeholder() -> IOSChatViewModel {
        IOSChatViewModel(
            conversationManager: ConversationManager(),
            aiService: nil
        )
    }

    /// Initialize for an existing conversation.
    init(
        conversationId: UUID,
        conversationManager: ConversationManager,
        aiService: AIService? = nil,
        executeBuiltInTool: IOSBuiltInToolExecutor? = nil
    ) {
        let resolvedAIService = aiService ?? .shared
        self.conversationId = conversationId
        isNewChatMode = false
        self.conversationManager = conversationManager
        self.aiService = resolvedAIService
        self.executeBuiltInTool = executeBuiltInTool ?? { name, arguments in
            await resolvedAIService.executeBuiltInToolWithCitations(
                name: name,
                arguments: arguments
            )
        }
        selectedModel = resolvedAIService.selectedModel
        selectedModels = [resolvedAIService.selectedModel]
    }

    /// Initialize for a new chat (no conversation yet).
    init(
        conversationManager: ConversationManager,
        aiService: AIService? = nil,
        executeBuiltInTool: IOSBuiltInToolExecutor? = nil
    ) {
        let resolvedAIService = aiService ?? .shared
        conversationId = nil
        isNewChatMode = true
        self.conversationManager = conversationManager
        self.aiService = resolvedAIService
        self.executeBuiltInTool = executeBuiltInTool ?? { name, arguments in
            await resolvedAIService.executeBuiltInToolWithCitations(
                name: name,
                arguments: arguments
            )
        }
        selectedModel = resolvedAIService.selectedModel
        selectedModels = [resolvedAIService.selectedModel]
    }

    // MARK: - Computed Properties

    /// The current conversation being managed.
    var conversation: Conversation? {
        guard let id = conversationId else { return nil }
        return conversationManager.conversation(byId: id)
    }

    // MARK: - Configuration Update

    /// Update the conversation manager reference.
    /// Used when view model was created before environment was available.
    func configure(with manager: ConversationManager) {
            if conversationManager !== manager {
                cancelOwnedOperations()
            }
        conversationManager = manager
    }

    /// Configure with conversation manager and conversation ID.
    /// Used for existing conversation views.
    func configure(with manager: ConversationManager, conversationId: UUID) {
            if self.conversationId != conversationId || conversationManager !== manager {
                cancelOwnedOperations()
            }
        conversationManager = manager
        self.conversationId = conversationId

        // Check for pending auto-send prompt (from deep link)
        checkAndProcessPendingPrompt()
    }

    /// The model to use for sending messages.
    private var effectiveModel: String {
        if isNewChatMode {
            return selectedModel
        }
        return conversation?.model ?? selectedModel
    }

    // MARK: - Public Methods

    /// Reset state for a fresh new chat session.
    func resetForNewChat() {
        if isProcessingMultiModelChunkCallback {
            pendingResetForNewChat = true
            return
        }
        performResetForNewChat()
    }

    private func performResetForNewChat() {
        pendingResetForNewChat = false
            cancelOwnedOperations()
        conversationId = nil
        messageText = ""
        isGenerating = false
        errorMessage = nil
        errorRecoverySuggestion = nil
        failedMessage = nil
        cleanupAttachedFiles()
        attachedImages.removeAll()
        selectedModel = aiService.selectedModel
        selectedModels = [aiService.selectedModel]

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📱 IOSChatViewModel reset for new chat"
        )
    }

    /// Check for and process a pending auto-send prompt from deep link.
    /// This should be called after the view model is configured with a conversation.
    private func checkAndProcessPendingPrompt() {
        guard let convId = conversationId,
              let index = conversationManager.conversations.firstIndex(where: { $0.id == convId }),
              let prompt = conversationManager.conversations[index].pendingAutoSendPrompt,
              !prompt.isEmpty
        else {
            return
        }

        if sendPreparationTask != nil {
            guard cancelPendingAutoSend() else { return }
            if cancelSendPreparation() {
                isGenerating = false
            }
        } else {
            guard !isGenerating else { return }
            cancelPendingAutoSend()
        }

        guard let claimIndex = conversationManager.conversations.firstIndex(where: { $0.id == convId }),
              conversationManager.conversations[claimIndex].pendingAutoSendPrompt == prompt
        else {
            return
        }

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔗 Processing pending auto-send prompt from deep link",
            metadata: ["promptLength": "\(prompt.count)"]
        )

            // Clear and persist the prompt before claiming it so view recreation cannot resend it.
        conversationManager.conversations[claimIndex].pendingAutoSendPrompt = nil
            conversationManager.saveImmediately(conversationManager.conversations[claimIndex])

        // Set the message text and send
        messageText = prompt
            pendingAutoSendDraft = prompt
            pendingAutoSendConversationID = convId
            let autoSendID = UUID()
            pendingAutoSendID = autoSendID
        // Use a small delay to ensure the view is fully loaded
            let task = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self,
                      self.pendingAutoSendID == autoSendID,
                      self.conversationId == convId,
                      self.messageText == prompt
                else {
                    return
                }
                self.pendingAutoSendTask = nil
                self.pendingAutoSendID = nil
                self.sendMessage()
            }
            pendingAutoSendTask = task
        }

        @discardableResult
        private func cancelPendingAutoSend() -> Bool {
            let wasPending = pendingAutoSendTask != nil
                || pendingAutoSendID != nil
                || pendingAutoSendDraft != nil
            pendingAutoSendTask?.cancel()
            pendingAutoSendTask = nil
            pendingAutoSendID = nil
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: true)
            pendingAutoSendDraft = nil
            pendingAutoSendConversationID = nil
            return wasPending
        }

        private func preparePendingAutoSendClaimForSend() {
            pendingAutoSendTask?.cancel()
            pendingAutoSendTask = nil
            pendingAutoSendID = nil
        }

        private func restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: Bool) {
            guard let draft = pendingAutoSendDraft,
                  let claimedConversationID = pendingAutoSendConversationID,
                  let index = conversationManager.conversations.firstIndex(where: { $0.id == claimedConversationID })
            else {
                return
            }

            if conversationManager.conversations[index].pendingAutoSendPrompt == nil {
                conversationManager.conversations[index].pendingAutoSendPrompt = draft
                conversationManager.saveImmediately(conversationManager.conversations[index])
            }
            if clearVisibleDraft, messageText == draft {
                messageText = ""
            }
        }

        private func consumePendingAutoSendClaim(afterCommittingTo conversationID: UUID) {
            pendingAutoSendTask?.cancel()
            pendingAutoSendTask = nil
            pendingAutoSendID = nil
            if let draft = pendingAutoSendDraft,
               pendingAutoSendConversationID == conversationID,
               let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationID }),
               conversationManager.conversations[index].pendingAutoSendPrompt == draft
            {
                conversationManager.conversations[index].pendingAutoSendPrompt = nil
                conversationManager.saveImmediately(conversationManager.conversations[index])
            }
            pendingAutoSendDraft = nil
            pendingAutoSendConversationID = nil
    }

    /// Retry the last failed message
    func retryFailedMessage() {
        guard !isGenerating else { return }
        guard let message = failedMessage else { return }

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔄 Retrying failed message",
            metadata: ["messageLength": "\(message.count)"]
        )

        // Clear error state
        failedMessage = nil
        errorMessage = nil
        errorRecoverySuggestion = nil

        // Set message text and send
        messageText = message
        sendMessage()
    }

    /// Dismiss the current error without retrying
    func dismissError() {
        failedMessage = nil
        errorMessage = nil
        errorRecoverySuggestion = nil
    }

    /// Handle file import results from the file importer.
    func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            for url in urls {
                // Start accessing the security-scoped resource
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                guard accessing else {
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Failed to access security-scoped resource: \(url.lastPathComponent)"
                    )
                    continue
                }

                // Copy to temporary location immediately
                do {
                    let tempURL = try copyToTemporaryDirectory(url: url)
                    attachedFiles.append(tempURL)
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "📎 File attached (copied to temp): \(url.lastPathComponent)"
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Failed to copy attachment: \(error.localizedDescription)"
                    )
                    errorMessage = "Failed to attach file: \(error.localizedDescription)"
                }
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ File import failed: \(error.localizedDescription)"
            )
        }
    }

    /// Handle photo selection from the photo picker.
    func handlePhotoSelection(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data)
                {
                    await MainActor.run {
                        attachedImages.append(image)
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "📷 Photo attached from library",
                            metadata: ["imageSize": "\(image.size)"]
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to load photo: \(error.localizedDescription)"
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Photo selection failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Cancel the current generation.
    func cancelGeneration() {
        let logMetadata: [String: String] = conversationId.map { ["conversationId": $0.uuidString] } ?? [:]
        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🛑 Cancelling generation",
            metadata: logMetadata
        )
            let cancelledPreparation = cancelSendPreparation()
            if cancelledPreparation {
                restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            }
            toolChainCoordinator.cancelCurrentOperation {
                finalizePersistedTextGeneration()
        }
            imageGenerationCoordinator.cancelCurrentOperation()
        isGenerating = false
        currentToolName = nil
        toolCallDepth = 0
            activeAssistantMessageId = nil
            activeMultiModelResponseGroupId = nil
        pendingUserMessage = nil
    }

    /// Send a message in the current conversation.
    func sendMessage() {
        let currentConversation = conversation
        let preparation = SendPreparation(
            draftText: messageText,
            text: messageText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachedFiles: attachedFiles,
            attachedImages: attachedImages,
            selectedModel: selectedModel,
            selectedModels: selectedModels,
            requestModel: currentConversation?.model ?? selectedModel
        )

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🚀 sendMessage() called",
            metadata: [
                "textLength": "\(preparation.text.count)",
                "isGenerating": "\(isGenerating)",
                "hasConversation": "\(currentConversation != nil)",
                "isNewChatMode": "\(isNewChatMode)"
            ]
        )

        guard !preparation.text.isEmpty
            || !preparation.attachedFiles.isEmpty
            || !preparation.attachedImages.isEmpty
        else {
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "⚠️ Empty message, ignoring"
            )
            return
        }

        // Prevent sending while already generating
        guard !isGenerating, sendPreparationTask == nil else {
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "⚠️ Ignoring send request - already generating"
            )
            return
        }

            // A manual send during the short deep-link delay takes over the same durable claim.
            // Keep ownership until the user message is committed so failed hydration can restore it.
            preparePendingAutoSendClaimForSend()

        if !isNewChatMode,
           let conversationId,
           conversationManager.isMetadataOnlyConversation(conversationId)
        {
            prepareExistingConversationAndSend(
                conversationId: conversationId,
                preparation: preparation
            )
            return
        }

        sendPreparedMessage(preparation)
    }

    private func prepareExistingConversationAndSend(
        conversationId: UUID,
        preparation: SendPreparation
    ) {
        let preparationID = UUID()
        let manager = conversationManager
        sendPreparationID = preparationID
        isGenerating = true

        let task = Task { @MainActor [weak self] in
            defer { self?.sendPreparationDidFinish?() }
            let loadedConversation = await ConversationSendPreflight.loadConversationHistory(
                conversationId: conversationId,
                manager: manager
            )
            guard let self,
                  !Task.isCancelled,
                  self.sendPreparationID == preparationID,
                  self.conversationId == conversationId,
                  self.conversationManager === manager
            else {
                return
            }

            self.sendPreparationTask = nil
            self.sendPreparationID = nil
            self.isGenerating = false

            guard loadedConversation != nil else {
                DiagnosticsLogger.log(
                    .chatView,
                    level: .error,
                    message: "❌ Failed to load conversation before sending",
                    metadata: ["conversationId": conversationId.uuidString]
                )
                self.errorMessage = "Unable to load this conversation's history. Try again."
                self.restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
                return
            }

            self.sendPreparedMessage(preparation)
        }
        sendPreparationTask = task
    }

    @discardableResult
    private func cancelSendPreparation() -> Bool {
        let wasPending = sendPreparationTask != nil || sendPreparationID != nil
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        sendPreparationID = nil
        return wasPending
    }

    // swiftlint:disable:next function_body_length
    private func sendPreparedMessage(_ preparation: SendPreparation) {
        // Check for multi-model mode
        if preparation.selectedModels.count >= 2 {
            sendToMultipleModels(preparation)
            return
        }

        // Get or create conversation
        let targetConversation: Conversation
        if let existing = conversation {
            targetConversation = existing
        } else if isNewChatMode {
            conversationManager.createNewConversation()
            guard let newConv = conversationManager.conversations.first else { return }
            targetConversation = newConv
            conversationId = newConv.id

            // Update model if different from default
            if newConv.model != preparation.selectedModel {
                conversationManager.updateModel(for: newConv, model: preparation.selectedModel)
            }

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "🆕 Created new conversation",
                metadata: ["conversationId": newConv.id.uuidString]
            )
        } else {
            // No conversation and not in new chat mode - shouldn't happen
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ No conversation available to send message"
            )
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return
        }

        let targetConversationId = targetConversation.id

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📤 Sending message",
            metadata: [
                "conversationId": targetConversationId.uuidString,
                "textLength": "\(preparation.text.count)",
                "attachmentCount": "\(preparation.attachedFiles.count)",
                "imageCount": "\(preparation.attachedImages.count)",
            ]
        )

        var userMessage = Message(role: .user, content: preparation.text)

        // Process file attachments with proper resource cleanup
        if !preparation.attachedFiles.isEmpty {
            let result = IOSFileAttachmentUtils.processAttachments(from: preparation.attachedFiles)
            userMessage.attachments = result.attachments
            if !result.errors.isEmpty {
                errorMessage = result.errors.joined(separator: "\n")
            }
            cleanupAttachedFiles(preparation.attachedFiles)
        }

        // Process image attachments from photo library
        if !preparation.attachedImages.isEmpty {
            let imageAttachments = IOSFileAttachmentUtils.processImageAttachments(from: preparation.attachedImages)
            if userMessage.attachments == nil {
                userMessage.attachments = imageAttachments
            } else {
                userMessage.attachments?.append(contentsOf: imageAttachments)
            }
            removeAttachedImages(preparation.attachedImages)
        }

        conversationManager.addMessage(to: targetConversation, message: userMessage)
        consumePendingAutoSendClaim(afterCommittingTo: targetConversationId)

        // Process memory commands (e.g., "remember that I prefer dark mode")
        if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: preparation.text) {
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "💾 Memory command processed",
                metadata: ["response": memoryResponse]
            )
        }

        // Store the message text for retry in case of failure
        pendingUserMessage = preparation.text
        if messageText == preparation.draftText {
            messageText = ""
        }
        isGenerating = true
        errorMessage = nil
        errorRecoverySuggestion = nil
        failedMessage = nil

        // Play message sent sound
        SoundEngine.messageSent()

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📝 User message added, isGenerating=true",
            metadata: ["userMessageId": userMessage.id.uuidString]
        )

        // Create a capability-aware placeholder so cancellation/rollback can identify image work.
        let requestModel = preparation.requestModel.isEmpty
            ? targetConversation.model
            : preparation.requestModel
        let isImageRequest = aiService.getModelCapability(requestModel) == .imageGeneration
        var assistantMessage = Message(role: .assistant, content: "", model: requestModel)
        if isImageRequest {
            assistantMessage.mediaType = .image
        }
        conversationManager.addMessage(to: targetConversation, message: assistantMessage)

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🤖 Assistant placeholder created",
            metadata: ["assistantMessageId": assistantMessage.id.uuidString]
        )

        // Re-fetch conversation with updated messages
        guard let updatedConversation = conversation else {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Failed to re-fetch conversation after adding messages"
            )
            isGenerating = false
            return
        }

        if isImageRequest {
            generateImage(
                text: preparation.text,
                assistantMessage: assistantMessage,
                conversationId: targetConversationId,
                model: requestModel
            )
            return
        }

            // Linearize multi-model history and omit failed/empty placeholders. The newly added
            // empty assistant is also excluded by effective-history filtering.
            var messagesToSend = updatedConversation.getEffectiveHistory()

        // Prepend system prompt if configured
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Get available tools (Tavily web search on iOS)
        let tools = aiService.getAllAvailableTools()
        toolCallDepth = 0

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📡 Calling sendMessageWithToolSupport",
            metadata: [
                "model": requestModel,
                "messageCount": "\(messagesToSend.count)",
                "hasTools": "\(tools != nil)",
                "toolCount": "\(tools?.count ?? 0)"
            ]
        )

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: requestModel,
            conversationId: targetConversationId,
            assistantMessageId: assistantMessage.id,
            tools: tools
        )
    }
    }

    private extension IOSChatViewModel {
    /// Helper method to send messages with tool call support
    private func sendMessageWithToolSupport( // swiftlint:disable:this function_body_length
        messages: [Message],
        model: String,
        conversationId: UUID,
        assistantMessageId: UUID,
        tools: [[String: Any]]?,
        operationID existingOperationID: ToolChainCoordinator.OperationID? = nil
    ) {
        let toolsWrapper = UncheckedSendable(tools)
        let coordinator = toolChainCoordinator
        let roundCoordinator = toolCallRequestRoundCoordinator
        let operationID = existingOperationID ?? coordinator.beginOperation(conversationID: conversationId)
        if existingOperationID == nil {
            activeMultiModelResponseGroupId = nil
        }
            guard coordinator.owns(operationID, conversationID: conversationId),
                  let requestRoundID = roundCoordinator.beginRequestRound(
                      for: operationID,
                      coordinatedBy: coordinator
                  )
            else {
                return
            }
            activeAssistantMessageId = assistantMessageId
            let toolCallAdmissionGate = ToolCallRequestAdmissionGate()

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔌 sendMessageWithToolSupport: Calling OpenAI service",
            metadata: [
                "assistantMessageId": assistantMessageId.uuidString,
                "model": model
            ]
        )

            let request = aiService.sendMessage(
                messages: messages,
                model: model,
                stream: true,
                tools: tools,
                onChunk: { [weak self] chunk in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                        guard let self,
                              coordinator.owns(operationID, conversationID: conversationId),
                              self.activeAssistantMessageId == assistantMessageId
                        else {
                            return
                        }
                        if !chunk.isEmpty {
                            DiagnosticsLogger.log(
                                .chatView,
                                level: .debug,
                                message: "📥 onChunk received",
                                metadata: [
                                    "chunkLength": "\(chunk.count)",
                                    "assistantMessageId": assistantMessageId.uuidString
                                ]
                            )
                        }
                        self.currentToolName = nil
                        self.enqueueStreamingChunk(
                            conversationId: conversationId,
                            messageId: assistantMessageId,
                            model: model,
                            chunk: chunk
                        )
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

                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "✅ onComplete called",
                            metadata: [
                                "currentToolName": self.currentToolName ?? "none",
                                "assistantMessageId": assistantMessageId.uuidString
                            ]
                        )

                        self.flushStreamingChunks(
                            conversationId: conversationId,
                            messageId: assistantMessageId,
                            model: model
                        )

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
                            tools: toolsWrapper.value
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
                            conversationId: conversationId
                        )
                    }
                },
                onToolCallRequested: toolCallAdmissionGate.admittedCallback { [weak self] toolCallId, toolName, arguments in
                    let argumentsWrapper = UncheckedSendable(arguments)
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                        guard let self,
                              coordinator.owns(operationID, conversationID: conversationId),
                              self.activeAssistantMessageId == assistantMessageId,
                              self.conversationManager.conversation(byId: conversationId) != nil,
                              let toolToken = roundCoordinator.registerTool(
                                  for: operationID,
                                  requestRoundID: requestRoundID
                              )
                        else {
                            return
                        }

                        self.flushStreamingChunks(
                            conversationId: conversationId,
                            messageId: assistantMessageId,
                            model: model
                        )

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
                        let arguments = argumentsWrapper.value
                        let anyCodableArguments = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                            result[pair.key] = AnyCodable(pair.value)
                        }
                        let toolCall = MCPToolCall(
                            id: toolCallId,
                            toolName: toolName,
                            arguments: anyCodableArguments
                        )
                        let updatedAssistant = self.conversationManager.updateMessage(
                            conversationId: conversationId,
                            messageId: assistantMessageId
                        ) { message in
                            var calls = message.toolCalls ?? []
                            if !calls.contains(where: { $0.id == toolCallId }) {
                                calls.append(toolCall)
                            }
                            message.toolCalls = calls
                        }
                        guard updatedAssistant else {
                            self.stopToolChainForMissingConversation(
                                operationID: operationID,
                                assistantMessageId: assistantMessageId,
                                conversationId: conversationId
                            )
                            return
                        }
                        if let updatedConversation = self.conversationManager.conversation(byId: conversationId) {
                            self.conversationManager.save(updatedConversation)
                        }

                        self.toolExecutionStates[toolToken] = ToolExecutionState(
                            token: toolToken,
                            conversationId: conversationId,
                            callId: toolCallId,
                            toolName: toolName,
                            arguments: anyCodableArguments,
                            result: nil
                        )

                        self.executeTool(
                            token: toolToken,
                            callID: toolCallId,
                            toolName: toolName,
                            arguments: argumentsWrapper,
                            anyCodableArguments: anyCodableArguments,
                            operationID: operationID,
                            assistantMessageId: assistantMessageId,
                            model: model,
                            conversationId: conversationId,
                            tools: toolsWrapper
                        )
                    }
                }
            )
            coordinator.onCancel(for: operationID) {
                request.cancel()
            }
        }

        // swiftlint:disable:next function_parameter_count
        private func executeTool(
            token: ToolCallRequestRoundCoordinator<ToolExecutionResult>.ToolToken,
            callID: String,
            toolName: String,
            arguments: UncheckedSendable<[String: Any]>,
            anyCodableArguments: [String: AnyCodable],
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            model: String,
            conversationId: UUID,
            tools: UncheckedSendable<[[String: Any]]?>
        ) {
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
                            message: "⚙️ Executing tool: \(toolName)"
                        )
                let (output, citations) = await self.executeBuiltInTool(
                    toolName,
                    arguments.value
                )
                guard coordinator.owns(operationID, conversationID: conversationId),
                      self.activeAssistantMessageId == assistantMessageId,
                      !Task.isCancelled
                else {
                    return
                }

                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                    message: "✅ Tool result received (\(output.count) chars, \(citations?.count ?? 0) citations)"
                        )

                let result = ToolExecutionResult(
                    callID: callID,
                    toolName: toolName,
                    arguments: anyCodableArguments,
                    output: output,
                    citations: citations ?? []
                )
                if var state = self.toolExecutionStates[token] {
                    state.result = result
                    self.toolExecutionStates[token] = state
                }
                let resolution = roundCoordinator.toolDidComplete(token, result: result)
                self.handleToolRoundResolution(
                    resolution,
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    model: model,
                    conversationId: conversationId,
                    tools: tools.value
                )
            }
        }

        private func handleToolRoundResolution(
            _ resolution: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Resolution,
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            model: String,
            conversationId: UUID,
            tools: [[String: Any]]?
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
                    conversationId: conversationId
                )
            case let .launchContinuation(continuation):
                launchToolContinuation(
                    continuation,
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    model: model,
                    conversationId: conversationId,
                    tools: tools
                )
            }
        }

        private func launchToolContinuation(
            _ continuation: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Continuation,
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            model: String,
            conversationId: UUID,
            tools: [[String: Any]]?
        ) {
            guard continuation.operationID == operationID,
                  toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                return
            }

            let results = continuation.toolResults.map(\.result)
            for result in results {
                guard let conversation = conversationManager.conversation(byId: conversationId) else {
                    stopToolChainForMissingConversation(
                        operationID: operationID,
                        assistantMessageId: assistantMessageId,
                        conversationId: conversationId
                                    )
                                    return
                                }
                conversationManager.addMessage(to: conversation, message: result.makeMessage())
                            }

            toolExecutionStates.removeAll()

            if let conversationWithToolResults = conversationManager.conversation(byId: conversationId) {
                conversationManager.saveImmediately(conversationWithToolResults)
            }

            guard let conversationWithResults = conversationManager.conversation(byId: conversationId) else {
                stopToolChainForMissingConversation(
                    operationID: operationID,
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId
                )
                                return
                            }

                            var continuationAssistantMessage = Message(role: .assistant, content: "", model: model)
            let citations = ToolExecutionResult.combinedCitations(from: results)
            if !citations.isEmpty {
                                continuationAssistantMessage.citations = citations
                            }
            conversationManager.addMessage(
                to: conversationWithResults,
                message: continuationAssistantMessage
            )

            guard let conversationWithAssistant = conversationManager.conversation(byId: conversationId),
                  toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                                return
                            }

            var history = conversationWithAssistant
            history.messages.removeAll { $0.id == continuationAssistantMessage.id }
            var continuationMessages = history.getEffectiveHistory()
            if let systemPrompt = conversationManager.effectiveSystemPrompt(for: conversationWithAssistant) {
                continuationMessages.insert(Message(role: .system, content: systemPrompt), at: 0)
            }

            currentToolName = nil
            sendMessageWithToolSupport(
                messages: continuationMessages,
                model: model,
                conversationId: conversationId,
                assistantMessageId: continuationAssistantMessage.id,
                tools: tools,
                operationID: operationID
                                    )
                            }

        private func finishToolSupportedResponse(
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            conversationId: UUID
        ) {
            flushAllStreamingChunks(conversationId: conversationId)
            guard activeAssistantMessageId == assistantMessageId,
                  toolChainCoordinator.finishOperation(operationID)
            else {
                return
                            }
            activeAssistantMessageId = nil
            toolExecutionStates.removeAll()
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
            pendingUserMessage = nil
            SoundEngine.messageReceived()

            if let finalConversation = conversationManager.conversation(byId: conversationId) {
                conversationManager.save(finalConversation)
            }

            if isNewChatMode {
                onConversationCreated?(conversationId)
            }

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "✅ Message generation completed",
                metadata: ["conversationId": conversationId.uuidString]
            )
        }

        private func handleToolRequestError(
            _ error: Error,
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageId: UUID,
            conversationId: UUID
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationId),
                  activeAssistantMessageId == assistantMessageId
            else {
                return
            }
            flushAllStreamingChunks(conversationId: conversationId)
            persistUnfinishedToolExecutions(conversationId: conversationId)
            toolChainCoordinator.cancelCurrentOperation()
            activeAssistantMessageId = nil

            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                DiagnosticsLogger.log(
                    .chatView,
                    level: .info,
                    message: "Request cancelled",
                    metadata: ["assistantMessageId": assistantMessageId.uuidString]
                )
                isGenerating = false
                currentToolName = nil
                toolCallDepth = 0
                pendingUserMessage = nil
                if let updatedConversation = conversationManager.conversation(byId: conversationId) {
                    conversationManager.saveImmediately(updatedConversation)
                }
                return
            }

            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "🚨 onError callback fired",
                metadata: [
                    "error": ErrorPresenter.userMessage(for: error),
                    "assistantMessageId": assistantMessageId.uuidString
                ]
            )

            isGenerating = false
            SoundEngine.error()
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = ErrorPresenter.userMessage(for: error)
            errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
            failedMessage = pendingUserMessage
            pendingUserMessage = nil
            let assistantHasToolCalls = conversationManager
                .conversation(byId: conversationId)?
                .messages.first(where: { $0.id == assistantMessageId })?
                .toolCalls?.isEmpty == false
            if !assistantHasToolCalls {
                conversationManager.removeMessage(
                    conversationId: conversationId,
                    messageId: assistantMessageId
                )
            }
            if let updatedConversation = conversationManager.conversation(byId: conversationId) {
                conversationManager.save(updatedConversation)
                        }

            if isNewChatMode {
                onConversationCreated?(conversationId)
                    }

            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Message generation failed: \(ErrorPresenter.userMessage(for: error))",
                metadata: ["conversationId": conversationId.uuidString]
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
                message: "⚠️ Max tool call depth reached"
        )
            toolChainCoordinator.cancelCurrentOperation()
            toolExecutionStates.removeAll()
            activeAssistantMessageId = nil
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
            errorMessage = "Tool call limit reached. Please try again."
            conversationManager.removeMessage(
                conversationId: conversationId,
                messageId: assistantMessageId
            )
            if let updatedConversation = conversationManager.conversation(byId: conversationId) {
                conversationManager.save(updatedConversation)
            }
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
            toolExecutionStates.removeAll()
            activeAssistantMessageId = nil
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
    }

        @discardableResult
        private func persistUnfinishedToolExecutions(conversationId: UUID) -> Bool {
            let states = toolExecutionStates.values
                .filter { $0.conversationId == conversationId }
                .sorted { $0.token.registrationIndex < $1.token.registrationIndex }
            guard !states.isEmpty else { return false }

            for state in states {
                toolExecutionStates.removeValue(forKey: state.token)
            }

            guard let conversation = conversationManager.conversation(byId: conversationId) else {
                return false
            }

            var persistedCallIds = Set(
                conversation.messages
                    .filter { $0.role == .tool }
                    .flatMap { $0.toolCalls ?? [] }
                    .map(\.id)
            )
            var didPersist = false

            for state in states where !persistedCallIds.contains(state.callId) {
                let result = state.result ?? ToolExecutionResult(
                    callID: state.callId,
                    toolName: state.toolName,
                    arguments: state.arguments,
                    output: "Tool call cancelled before completion."
                )
                conversationManager.addMessage(to: conversation, message: result.makeMessage())
                persistedCallIds.insert(state.callId)
                didPersist = true
            }

            return didPersist
        }

    /// Get the ID of the last assistant message in the conversation
    private func getLastAssistantMessageId(conversationId: UUID) -> UUID? {
        guard let conv = conversationManager.conversation(byId: conversationId),
              let lastMessage = conv.messages.last,
              lastMessage.role == .assistant
        else {
            return nil
        }
        return lastMessage.id
    }

    // MARK: - Multi-Model Message Sending

    // MARK: - Private Methods

    private func enqueueStreamingChunk(
        conversationId: UUID,
        messageId: UUID,
        model: String? = nil,
        chunk: String
    ) {
        guard !chunk.isEmpty else { return }

        let key = StreamingChunkKey(
            conversationId: conversationId,
            messageId: messageId,
            model: model
        )
        var buffer = pendingChunkBuffers[key] ?? PendingChunkBuffer()
        buffer.chunks.append(chunk)
        buffer.pendingCharacterCount += chunk.count

        if buffer.flushTask == nil {
            let interval = streamingChunkFlushInterval
            buffer.flushTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.flushStreamingChunks(for: key)
            }
        }

        pendingChunkBuffers[key] = buffer

        if buffer.pendingCharacterCount >= streamingChunkImmediateFlushThreshold {
            flushStreamingChunks(for: key)
        }
    }

    private func flushStreamingChunks(
        conversationId: UUID,
        messageId: UUID,
        model: String? = nil
    ) {
        flushStreamingChunks(
            for: StreamingChunkKey(
                conversationId: conversationId,
                messageId: messageId,
                model: model
            )
        )
    }

    private func flushStreamingChunks(for key: StreamingChunkKey) {
        guard let buffer = pendingChunkBuffers.removeValue(forKey: key) else { return }
        buffer.flushTask?.cancel()
        let chunk = buffer.chunks.joined()
        guard !chunk.isEmpty else { return }
        updateAssistantMessage(
            key.messageId,
            appendingChunk: chunk,
            conversationId: key.conversationId
        )
    }

    @discardableResult
    private func flushAllStreamingChunks(conversationId: UUID? = nil) -> Bool {
        let keys = pendingChunkBuffers.keys.filter { key in
            conversationId.map { key.conversationId == $0 } ?? true
        }
        guard !keys.isEmpty else { return false }
        for key in keys {
            flushStreamingChunks(for: key)
        }
        return true
    }

    private func updateAssistantMessage(_ messageId: UUID, appendingChunk chunk: String, conversationId: UUID) {
        // Use safe ID-based append instead of index-based access
        let success = conversationManager.appendToMessage(
            conversationId: conversationId,
            messageId: messageId,
            chunk: chunk
        )

        if success {
            messageContentRevision &+= 1
        } else {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Failed to update assistant message - not found",
                metadata: ["conversationId": conversationId.uuidString, "messageId": messageId.uuidString]
            )
        }
    }
}

// MARK: - File Handling Helpers

private extension IOSChatViewModel {
    /// Copies a security-scoped file to a temporary location.
    func copyToTemporaryDirectory(url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = url.lastPathComponent
        // Use UUID to avoid collisions
        let uniqueTempDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: uniqueTempDir, withIntermediateDirectories: true, attributes: nil)
        let destinationURL = uniqueTempDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: url, to: destinationURL)
        return destinationURL
    }

    /// Cleans up temporary attached files.
    func cleanupAttachedFiles() {
        cleanupAttachedFiles(attachedFiles)
    }

    func cleanupAttachedFiles(_ files: [URL]) {
        let tempDirPath = FileManager.default.temporaryDirectory.path
        for url in files {
            if FileManager.default.fileExists(atPath: url.path),
               url.path.hasPrefix(tempDirPath)
            {
                try? FileManager.default.removeItem(at: url)
            }
            if let index = attachedFiles.firstIndex(of: url) {
                attachedFiles.remove(at: index)
            }
        }
    }

    func removeAttachedImages(_ images: [UIImage]) {
        for image in images {
            if let index = attachedImages.firstIndex(where: { $0 === image }) {
                attachedImages.remove(at: index)
            }
        }
    }
}

// MARK: - Message Retry and Editing

extension IOSChatViewModel {
    /// Retry from a specific assistant message.
    func retryMessage(beforeMessage: Message) {
        guard !isGenerating else { return }
        guard let conversation else { return }
        let targetConversationId = conversation.id
        let retryModel = beforeMessage.model ?? conversation.model
        let isImageRetry = aiService.getModelCapability(retryModel) == .imageGeneration

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔄 Retrying message",
            metadata: ["conversationId": targetConversationId.uuidString]
        )

        // Find the index of the message to retry
        guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == beforeMessage.id }) else {
            return
        }

        // Remove the assistant message and any subsequent messages
        let updatedMessages = Array(conversation.messages.prefix(messageIndex))

        // Update the conversation
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == targetConversationId }) {
            conversationManager.conversations[convIndex].messages = updatedMessages
        }

        // Create a new assistant message placeholder
        var assistantMessage = Message(role: .assistant, content: "", model: retryModel)
        if isImageRetry {
            assistantMessage.mediaType = .image
        }
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        isGenerating = true
        errorMessage = nil

        // Re-fetch conversation with updated messages
        guard let updatedConversation = self.conversation else {
            isGenerating = false
            return
        }
        if isImageRetry {
            guard let prompt = updatedMessages.last(where: { $0.role == .user })?.content else {
                isGenerating = false
                return
            }
            generateImage(
                text: prompt,
                assistantMessage: assistantMessage,
                conversationId: targetConversationId,
                model: retryModel
            )
            return
        }
            var messagesToSend = updatedConversation.getEffectiveHistory()

        // Prepend system prompt if configured
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Get available tools and use helper method
        let tools = aiService.getAllAvailableTools()
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: retryModel,
            conversationId: targetConversationId,
            assistantMessageId: assistantMessage.id,
            tools: tools
        )
    }

    /// Re-send the last user message to get a new AI response after editing.
    func resendAfterEdit() {
        guard !isGenerating else { return }
        guard let conversation else { return }
        let targetConversationId = conversation.id

        guard let updatedConversation = self.conversation else { return }

        isGenerating = true
        errorMessage = nil

        // Add empty assistant message placeholder
        let resendModel = updatedConversation.model
        let isImageResend = aiService.getModelCapability(resendModel) == .imageGeneration
        var assistantMessage = Message(role: .assistant, content: "", model: resendModel)
        if isImageResend {
            assistantMessage.mediaType = .image
        }
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Build messages to send (everything except the new empty assistant message)
        guard let refreshed = self.conversation else {
            isGenerating = false
            return
        }
        if isImageResend {
            guard let prompt = refreshed.messages.dropLast().last(where: { $0.role == .user })?.content else {
                isGenerating = false
                return
            }
            generateImage(
                text: prompt,
                assistantMessage: assistantMessage,
                conversationId: targetConversationId,
                model: resendModel
            )
            return
        }
            var messagesToSend = refreshed.getEffectiveHistory()

        // Prepend system prompt if configured
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: refreshed) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        let tools = aiService.getAllAvailableTools()
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: refreshed.model,
            conversationId: targetConversationId,
            assistantMessageId: assistantMessage.id,
            tools: tools
        )
    }

    /// Switch to a different model and retry the message.
    /// This retries with the specified model without changing the conversation's default model.
    func switchModelAndRetry(beforeMessage: Message, newModel: String) {
        guard !isGenerating else { return }
        guard let conversation else { return }
        let targetConversationId = conversation.id
        let isImageRetry = aiService.getModelCapability(newModel) == .imageGeneration

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔄 Switching model and retrying",
            metadata: [
                "conversationId": targetConversationId.uuidString,
                "newModel": newModel,
            ]
        )

        // Find the index of the message to retry
        guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == beforeMessage.id }) else {
            return
        }

        // Remove the assistant message and any subsequent messages
        let updatedMessages = Array(conversation.messages.prefix(messageIndex))

        // Update the conversation
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == targetConversationId }) {
            conversationManager.conversations[convIndex].messages = updatedMessages
        }

        // Create a new assistant message placeholder with the new model
        var assistantMessage = Message(role: .assistant, content: "", model: newModel)
        if isImageRetry {
            assistantMessage.mediaType = .image
        }
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        isGenerating = true
        errorMessage = nil

        // Re-fetch conversation with updated messages
        guard let updatedConversation = self.conversation else {
            isGenerating = false
            return
        }
        if isImageRetry {
            guard let prompt = updatedMessages.last(where: { $0.role == .user })?.content else {
                isGenerating = false
                return
            }
            generateImage(
                text: prompt,
                assistantMessage: assistantMessage,
                conversationId: targetConversationId,
                model: newModel
            )
            return
        }
            var messagesToSend = updatedConversation.getEffectiveHistory()

        // Prepend system prompt if configured
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Get available tools and use helper method
        let tools = aiService.getAllAvailableTools()
        toolCallDepth = 0

        // Use the new model for this request
        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: newModel,
            conversationId: targetConversationId,
            assistantMessageId: assistantMessage.id,
            tools: tools
        )
    }
}

// MARK: - Multi-Model Message Sending

extension IOSChatViewModel {
    /// Sends a message to multiple models in parallel for comparison
    private func sendToMultipleModels(_ preparation: SendPreparation) {
        guard !isGenerating else { return }
        let text = preparation.text
        guard !text.isEmpty else {
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return
        }

        guard let targetConversation = getOrCreateConversationForMultiModel(
            selectedModels: preparation.selectedModels
        ) else {
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return
        }
        let conversationId = targetConversation.id
        let models = Array(preparation.selectedModels)

        // Check for image generation and route accordingly
        if let firstModel = preparation.selectedModels.sorted().first,
           aiService.getModelCapability(firstModel) == .imageGeneration
        {
            generateImagesWithMultipleModels(
                prompt: text,
                models: models,
                conversation: targetConversation,
                draftText: preparation.draftText
            )
            return
        }

        DiagnosticsLogger.log(.chatView, level: .info, message: "🔀 Starting iOS multi-model request",
                              metadata: ["models": models.joined(separator: ", ")])

        let userMessage = Message(role: .user, content: text)
        conversationManager.addMessage(to: targetConversation, message: userMessage)
        consumePendingAutoSendClaim(afterCommittingTo: conversationId)

        if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: text) {
            DiagnosticsLogger.log(.chatView, level: .info, message: "💾 Memory command processed",
                                  metadata: ["response": memoryResponse])
        }

        if messageText == preparation.draftText {
            messageText = ""
        }
        isGenerating = true
        errorMessage = nil

        let responsePlan = createResponsePlanForMultiModel(
            models: models,
            userMessageId: userMessage.id
        )
        let responseGroupId = responsePlan.responseGroupId
        let messageIdsByModel = responsePlan.messageIDsByModel
        conversationManager.addMultiModelResponse(
            to: targetConversation,
            messages: responsePlan.placeholderMessages,
            responseGroup: responsePlan.responseGroup
        )

        guard let updatedConversation = conversation else {
            isGenerating = false
            return
        }
        var messagesToSend = updatedConversation.getEffectiveHistory().filter { $0.responseGroupId != responseGroupId }
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            messagesToSend.insert(Message(role: .system, content: systemPrompt), at: 0)
        }

            // Send to all models under this view model's owner-specific operation.
            let coordinator = toolChainCoordinator
            activeAssistantMessageId = nil
            activeMultiModelResponseGroupId = responseGroupId
            let operationID = coordinator.beginOperation(conversationID: conversationId)
            multiModelReasoningBuffer.resetAll()
            let request = aiService.sendToMultipleModels(
            messages: messagesToSend,
            models: models,
            temperature: updatedConversation.temperature,
            onChunk: { [weak self] model, chunk in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                        guard let self,
                              coordinator.owns(operationID, conversationID: conversationId)
                        else {
                            return
                        }

                        self.isProcessingMultiModelChunkCallback = true
                        defer {
                            self.isProcessingMultiModelChunkCallback = false
                            if self.pendingResetForNewChat {
                                self.performResetForNewChat()
                            }
                        }

                        self.multiModelChunkWillProcess?()
                        guard coordinator.owns(operationID, conversationID: conversationId) else { return }
                        self.processMultiModelChunk(
                            model: model,
                            chunk: chunk,
                            messageIds: messageIdsByModel,
                            conversationId: conversationId
                        )
                }
            },
            onModelComplete: { [weak self] model in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                        guard let self else { return }
                    self.processMultiModelCompletion(
                        model: model,
                        messageIds: messageIdsByModel,
                        conversationId: conversationId,
                        responseGroupId: responseGroupId
                    )
                }
            },
            onAllComplete: { [weak self] in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                        self?.finishMultiModelGeneration(
                            operationID: operationID, conversationId: conversationId, coordinator: coordinator
                        )
                }
            },
            onError: { [weak self] model, error in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                        guard let self else { return }
                    self.processMultiModelError(
                        model: model,
                        error: error,
                        messageIds: messageIdsByModel,
                        conversationId: conversationId,
                        responseGroupId: responseGroupId
                    )
                }
            },
            onPendingToolCall: nil,
            onReasoning: { [weak self] model, reasoning in
                coordinator.enqueueCallback(for: operationID, conversationID: conversationId) { [weak self] in
                    guard let self, coordinator.owns(operationID, conversationID: conversationId) else { return }
                    self.processMultiModelReasoning(
                        model: model,
                        reasoning,
                        messageIds: messageIdsByModel,
                        conversationId: conversationId
                    )
                }
            }
        )
            coordinator.onCancel(for: operationID) { [weak self] in
                self?.finishAndPersistMultiModelReasoning(conversationId: conversationId)
                request.cancel()
            }
    }

    private func finishMultiModelGeneration(
        operationID: ToolChainCoordinator.OperationID,
        conversationId: UUID,
        coordinator: ToolChainCoordinator
    ) {
        guard coordinator.owns(operationID, conversationID: conversationId) else { return }

        multiModelReasoningBuffer.finishAll()
        flushAllStreamingChunks(conversationId: conversationId)
        isGenerating = false
        if let conversationIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) {
            conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
        }
        activeMultiModelResponseGroupId = nil
        guard coordinator.finishOperation(operationID) else { return }

        if isNewChatMode {
            onConversationCreated?(conversationId)
        }
    }

    private func finishAndPersistMultiModelReasoning(conversationId: UUID) {
        multiModelReasoningBuffer.finishAll()
        if let conversation = conversationManager.conversation(byId: conversationId) {
            conversationManager.saveImmediately(conversation)
        }
    }

    /// Gets or creates a conversation configured for multi-model mode
    func getOrCreateConversationForMultiModel(selectedModels: Set<String>) -> Conversation? {
        if let existing = conversation {
            return existing
        }
        guard isNewChatMode else { return nil }

        conversationManager.createNewConversation()
        guard let newConv = conversationManager.conversations.first else { return nil }
        conversationId = newConv.id

        var updatedConv = newConv
        updatedConv.activeModels = Array(selectedModels)
        updatedConv.multiModelEnabled = true
            if let first = selectedModels.sorted().first {
                updatedConv.model = first
            }
        conversationManager.updateConversation(updatedConv)

        DiagnosticsLogger.log(.chatView, level: .info, message: "🆕 Created new multi-model conversation",
                              metadata: ["conversationId": newConv.id.uuidString])
        return updatedConv
    }

    /// Creates the immutable setup for a multi-model request.
    func createResponsePlanForMultiModel(
        models: [String],
        userMessageId: UUID,
        responseGroupId: UUID = UUID(),
        mediaType: Message.MediaType? = nil
    ) -> MultiModelResponsePlan {
        MultiModelResponsePlan(
            models: models,
            userMessageId: userMessageId,
            responseGroupId: responseGroupId,
            mediaType: mediaType
        )
    }

    /// Processes a streaming chunk for a specific model in multi-model mode
    func processMultiModelChunk(
        model: String,
        chunk: String,
        messageIds: [String: UUID],
        conversationId: UUID
    ) {
        guard let messageId = messageIds[model] else {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Missing message ID for model in multi-model response",
                metadata: ["model": model]
            )
            return
        }

        enqueueStreamingChunk(
            conversationId: conversationId,
            messageId: messageId,
            model: model,
            chunk: chunk
        )
    }

    func processMultiModelReasoning(
        model: String,
        _ reasoning: String,
        messageIds: [String: UUID],
        conversationId: UUID
    ) {
        guard !reasoning.isEmpty,
              let messageId = messageIds[model]
        else {
            return
        }

        let conversationManager = conversationManager
        multiModelReasoningBuffer.buffer(for: messageId) { reasoningChunk in
            guard conversationManager.updateMessage(
                conversationId: conversationId,
                messageId: messageId,
                update: { message in
                    message.reasoning = (message.reasoning ?? "") + reasoningChunk
                }
            ) else {
                return
            }
            if let conversation = conversationManager.conversation(byId: conversationId) {
                conversationManager.save(conversation)
            }
        }.append(reasoning)
    }

    /// Processes completion for a specific model in multi-model mode
    func processMultiModelCompletion(
        model: String,
        messageIds: [String: UUID],
        conversationId: UUID,
        responseGroupId: UUID
    ) {
        guard let messageId = messageIds[model] else { return }
        multiModelReasoningBuffer.finish(for: messageId)
        flushStreamingChunks(
            conversationId: conversationId,
            messageId: messageId,
            model: model
        )

        let success = conversationManager.updateResponseGroupStatus(
            conversationId: conversationId,
            responseGroupId: responseGroupId,
            messageId: messageId,
            status: .completed
        )

        if !success {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Failed to update response group - conversation not found",
                metadata: ["conversationId": conversationId.uuidString]
            )
        }
    }

    /// Processes an error for a specific model in multi-model mode
    func processMultiModelError(
        model: String,
        error: Error,
        messageIds: [String: UUID],
        conversationId: UUID,
        responseGroupId: UUID
    ) {
        guard let messageId = messageIds[model] else { return }
        multiModelReasoningBuffer.finish(for: messageId)
        flushStreamingChunks(
            conversationId: conversationId,
            messageId: messageId,
            model: model
        )

        let success = conversationManager.updateResponseGroupStatus(
            conversationId: conversationId,
            responseGroupId: responseGroupId,
            messageId: messageId,
            status: .failed
        )

        if !success {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Failed to update response group status - conversation not found",
                metadata: ["conversationId": conversationId.uuidString]
            )
        }

        DiagnosticsLogger.log(
            .chatView,
            level: .error,
            message: "❌ Model failed in iOS multi-model",
            metadata: ["model": model, "error": error.localizedDescription]
        )

        if let conv = conversationManager.conversation(byId: conversationId),
           let group = conv.getResponseGroup(responseGroupId),
           group.responses.allSatisfy({ $0.status == .failed })
        {
            errorMessage = "All models failed"
        }
    }
}

// MARK: - Image Generation

    extension IOSChatViewModel {
        /// Cancels only image and tool-chain work owned by this view model.
        /// Used on disappearance so an old view cannot mutate or cancel a replacement owned elsewhere.
        func cancelOwnedOperations() {
            let cancelledAutoSend = cancelPendingAutoSend()
            let cancelledPreparation = cancelSendPreparation()
            let hadActiveTextState = activeAssistantMessageId != nil || activeMultiModelResponseGroupId != nil
            let hadBufferedText = !pendingChunkBuffers.isEmpty || !multiModelReasoningBuffer.isEmpty
            let hadToolExecutions = !toolExecutionStates.isEmpty
            let cancelledToolChain = toolChainCoordinator.cancelCurrentOperation {
                finalizePersistedTextGeneration()
            }
            let cancelledImage = imageGenerationCoordinator.cancelCurrentOperation()
            guard cancelledAutoSend || cancelledPreparation || cancelledImage || cancelledToolChain || hadActiveTextState
                || hadBufferedText || hadToolExecutions
            else {
                return
            }
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
            activeAssistantMessageId = nil
            activeMultiModelResponseGroupId = nil
            pendingUserMessage = nil
        }

        private func finalizePersistedTextGeneration() {
            let assistantMessageId = activeAssistantMessageId
            let responseGroupId = activeMultiModelResponseGroupId
            let flushedReasoning = multiModelReasoningBuffer.finishAll()
            guard let conversationId,
                  let conversationIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId })
            else {
                pendingChunkBuffers.values.forEach { $0.flushTask?.cancel() }
                pendingChunkBuffers.removeAll()
                toolExecutionStates.removeAll()
                activeMultiModelResponseGroupId = nil
                return
            }

            let flushedText = flushAllStreamingChunks(conversationId: conversationId)
            let persistedTools = persistUnfinishedToolExecutions(conversationId: conversationId)
            guard assistantMessageId != nil || responseGroupId != nil || flushedText || flushedReasoning || persistedTools else {
                activeMultiModelResponseGroupId = nil
                return
            }

            ChatGenerationFinalizer.finalize(
                conversation: &conversationManager.conversations[conversationIndex],
                activeAssistantMessageID: assistantMessageId,
                activeResponseGroupID: responseGroupId
            )
            conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            activeMultiModelResponseGroupId = nil
        }

    /// Finds the most recent generated or selected image reference in the conversation for editing context.
    private func previousImageSource(in conversation: Conversation) -> (data: Data?, path: String?)? {
        for message in conversation.messages.reversed() {
            guard message.role == .assistant, message.mediaType == .image else { continue }
            guard message.imageData != nil || message.imagePath != nil else { continue }

            if let groupId = message.responseGroupId {
                if let group = conversation.getResponseGroup(groupId),
                   group.selectedResponseId == message.id
                {
                    return (message.imageData, message.imagePath)
                }
                continue
            }

            return (message.imageData, message.imagePath)
        }
        return nil
    }

    /// Handles image generation or editing for a single model
    func generateImage(
        text: String,
        assistantMessage: Message,
        conversationId: UUID,
        model requestedModel: String? = nil
    ) {
        guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) ?? conversation else {
            return
        }

        let coordinator = imageGenerationCoordinator
        let operationID = coordinator.beginOperation()
        let previousImageSource = previousImageSource(in: conversation)
        let model = requestedModel ?? conversation.model
        let assistantMessageId = assistantMessage.id

        let conversationManager = conversationManager
        coordinator.onCancel(for: operationID) {
            conversationManager.removeMessage(
                conversationId: conversationId,
                messageId: assistantMessageId
            )
            if let conversation = conversationManager.conversation(byId: conversationId) {
                conversationManager.save(conversation)
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let previousImage = await self.loadImageData(from: previousImageSource)
            guard coordinator.owns(operationID), !Task.isCancelled else { return }

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: previousImage != nil ? "📝 Starting image edit" : "🎨 Starting image generation",
                metadata: ["prompt": text, "hasContext": "\(previousImage != nil)"]
            )

            let onComplete: @Sendable (Data) -> Void = { [weak self] data in
                coordinator.schedule(for: operationID) { [weak self] in
                    guard let self else { return }
                    let imagePath = await self.saveImageData(data)
                    guard coordinator.owns(operationID), !Task.isCancelled else {
                        await self.deleteImageData(at: imagePath)
                        return
                    }

                    let messageUpdated = self.conversationManager.updateMessage(
                        conversationId: conversation.id,
                        messageId: assistantMessageId
                    ) { message in
                        message.mediaType = .image
                        if let imagePath {
                            message.imagePath = imagePath
                            message.imageData = nil
                        } else {
                            message.imageData = data
                            message.imagePath = nil
                        }
                        message.content = ""
                    }
                    guard messageUpdated else {
                        await self.deleteImageData(at: imagePath)
                        _ = coordinator.finishOperation(operationID)
                        self.isGenerating = false
                        return
                    }

                    guard coordinator.finishOperation(operationID) else { return }
                    self.isGenerating = false
                    if self.isNewChatMode {
                        self.onConversationCreated?(conversationId)
                    }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "✅ Image generation/edit completed"
                    )
                }
            }

            let onError: @Sendable (Error) -> Void = { [weak self] error in
                coordinator.schedule(for: operationID) { [weak self] in
                    guard let self, coordinator.finishOperation(operationID) else { return }
                    self.isGenerating = false
                    self.errorMessage = ErrorPresenter.userMessage(for: error)
                    self.errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
                    self.conversationManager.removeMessage(
                        conversationId: conversationId,
                        messageId: assistantMessageId
                    )
                    if let conversation = self.conversationManager.conversation(byId: conversationId) {
                        self.conversationManager.save(conversation)
                    }

                    if self.isNewChatMode {
                        self.onConversationCreated?(conversationId)
                    }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Image generation/edit failed: \(error.localizedDescription)"
                    )
                }
            }

            let request: AIImageRequest? = if let previousImage {
                self.aiService.editImage(
                    prompt: text,
                    sourceImage: previousImage,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            } else {
                self.aiService.generateImage(
                    prompt: text,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            }
            coordinator.track(request, for: operationID)
        }
        coordinator.track(task, for: operationID)
    }

    /// Generates images from multiple models in parallel for comparison
    func generateImagesWithMultipleModels(
        prompt: String,
        models: [String],
        conversation: Conversation,
        draftText: String
    ) {
        let coordinator = imageGenerationCoordinator
        let operationID = coordinator.beginOperation()
        guard !models.isEmpty else {
            _ = coordinator.finishOperation(operationID)
            isGenerating = false
            return
        }

        let conversationId = conversation.id
        let previousImageSource = previousImageSource(in: conversation)

        let userMessage = Message(role: .user, content: prompt)
        conversationManager.addMessage(to: conversation, message: userMessage)
        consumePendingAutoSendClaim(afterCommittingTo: conversationId)

        if messageText == draftText {
            messageText = ""
        }
        isGenerating = true
        errorMessage = nil

        let responsePlan = createResponsePlanForMultiModel(
            models: models,
            userMessageId: userMessage.id,
            mediaType: .image
        )
        let responseGroupId = responsePlan.responseGroupId
        let messageIds = responsePlan.messageIDsByModel

        for placeholderMessage in responsePlan.placeholderMessages {
            conversationManager.addMessage(to: conversation, message: placeholderMessage)
        }

        conversationManager.addResponseGroup(to: conversation, group: responsePlan.responseGroup)

        let conversationManager = conversationManager
        let cancelledMessageIDs = Array(messageIds.values)
        coordinator.onCancel(for: operationID) {
            guard let conversation = conversationManager.conversation(byId: conversationId),
                  let responseGroup = conversation.getResponseGroup(responseGroupId)
            else {
                return
            }
            let pendingMessageIDs = ImageGenerationCoordinator.pendingMessageIDs(
                in: responseGroup,
                candidates: cancelledMessageIDs
            )
            for messageID in pendingMessageIDs {
                conversationManager.updateMessage(conversationId: conversationId, messageId: messageID) { message in
                    message.content = "Image generation stopped"
                }
                    conversationManager.updateResponseGroupStatus(
                    conversationId: conversationId,
                    responseGroupId: responseGroupId,
                    messageId: messageID,
                        status: .failed
                    )
                }
                if let conversation = conversationManager.conversation(byId: conversationId) {
                    conversationManager.save(conversation)
                }
            }

        let counter = MainActorCompletionCounter(total: models.count)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let previousImage = await self.loadImageData(from: previousImageSource)
            guard coordinator.owns(operationID), !Task.isCancelled else { return }

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: previousImage != nil ? "📝 Starting multi-model image edit" : "🎨 Starting multi-model image generation",
                metadata: [
                    "prompt": prompt,
                    "models": models.joined(separator: ", "),
                    "hasContext": "\(previousImage != nil)",
                ]
            )

            for model in models {
                guard let messageId = messageIds[model] else { continue }

                let onComplete: @Sendable (Data) -> Void = { [weak self] imageData in
                    coordinator.schedule(for: operationID) { [weak self] in
                        guard let self else { return }
                        await self.processImageSuccess(
                            imageData: imageData,
                            conversationId: conversationId,
                            messageId: messageId,
                            responseGroupId: responseGroupId,
                            counter: counter,
                            operationID: operationID
                        )
                    }
                }

                let onError: @Sendable (Error) -> Void = { [weak self] error in
                    coordinator.schedule(for: operationID) { [weak self] in
                        guard let self else { return }
                        self.processImageError(
                            error: error,
                            model: model,
                            conversationId: conversationId,
                            messageId: messageId,
                            responseGroupId: responseGroupId,
                            counter: counter,
                            operationID: operationID
                        )
                    }
                }

                let request: AIImageRequest? = if let previousImage {
                    self.aiService.editImage(
                        prompt: prompt,
                        sourceImage: previousImage,
                        model: model,
                        onComplete: onComplete,
                        onError: onError
                    )
                } else {
                    self.aiService.generateImage(
                        prompt: prompt,
                        model: model,
                        onComplete: onComplete,
                        onError: onError
                    )
                }
                coordinator.track(request, for: operationID)
            }
        }
        coordinator.track(task, for: operationID)
    }

    /// Processes successful image generation for a model
    private func processImageSuccess(
        imageData: Data,
        conversationId: UUID,
        messageId: UUID,
        responseGroupId: UUID,
        counter: MainActorCompletionCounter,
        operationID: ImageGenerationCoordinator.OperationID
    ) async {
        let imagePath = await saveImageData(imageData)
        guard imageGenerationCoordinator.owns(operationID), !Task.isCancelled else {
            await deleteImageData(at: imagePath)
            return
        }

        updateImageResponseGroupStatus(
            conversationId: conversationId,
            responseGroupId: responseGroupId,
            messageId: messageId,
            status: .completed
        )
        guard let conversation = conversationManager.conversation(byId: conversationId) else {
            await deleteImageData(at: imagePath)
            counter.increment()
            if counter.isComplete {
                finalizeImageGenerationBatch(conversationId: conversationId, operationID: operationID)
            }
            return
        }
        let messageUpdated = conversationManager.updateMessage(
            conversationId: conversation.id,
            messageId: messageId
        ) { message in
            message.content = ""
            if let imagePath {
                message.imagePath = imagePath
                message.imageData = nil
            } else {
                message.imageData = imageData
                message.imagePath = nil
            }
        }
        guard messageUpdated else {
            await deleteImageData(at: imagePath)
            updateImageResponseGroupStatus(
                conversationId: conversationId,
                responseGroupId: responseGroupId,
                messageId: messageId,
                status: .failed
            )
            counter.increment()
            if counter.isComplete {
                finalizeImageGenerationBatch(conversationId: conversationId, operationID: operationID)
            }
            return
        }

        counter.increment()
        if counter.isComplete {
            finalizeImageGenerationBatch(conversationId: conversationId, operationID: operationID)
        }
    }

    /// Processes an error during image generation for a model
    private func processImageError(
        error: Error,
        model: String,
        conversationId: UUID,
        messageId: UUID,
        responseGroupId: UUID,
        counter: MainActorCompletionCounter,
        operationID: ImageGenerationCoordinator.OperationID
    ) {
        guard imageGenerationCoordinator.owns(operationID) else { return }

        DiagnosticsLogger.log(
            .chatView,
            level: .error,
            message: "❌ Image generation failed for \(model): \(error.localizedDescription)",
            metadata: ["model": model]
        )

        updateImageResponseGroupStatus(
            conversationId: conversationId,
            responseGroupId: responseGroupId,
            messageId: messageId,
            status: .failed
        )
        conversationManager.updateMessage(conversationId: conversationId, messageId: messageId) { message in
            message.content = "Image generation failed: \(error.localizedDescription)"
        }
        if let conversation = conversationManager.conversation(byId: conversationId) {
            conversationManager.save(conversation)
        }

        counter.increment()
        if counter.isComplete {
            finalizeImageGenerationBatch(conversationId: conversationId, operationID: operationID)
        }
    }

    /// Updates the status of a response in a response group for image generation
    private func updateImageResponseGroupStatus(
        conversationId: UUID,
        responseGroupId: UUID,
        messageId: UUID,
        status: ResponseGroup.ResponseStatus
    ) {
        if let conversationIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
           let groupIndex = conversationManager.conversations[conversationIndex].responseGroups.firstIndex(where: {
               $0.id == responseGroupId
           }),
           let entryIndex = conversationManager.conversations[conversationIndex].responseGroups[groupIndex]
           .responses.firstIndex(where: { $0.id == messageId })
        {
            conversationManager.conversations[conversationIndex].responseGroups[groupIndex].responses[entryIndex].status = status
        }
    }

    /// Finalizes a batch of image generation requests
    private func finalizeImageGenerationBatch(
        conversationId: UUID,
        operationID: ImageGenerationCoordinator.OperationID
    ) {
        guard imageGenerationCoordinator.finishOperation(operationID) else { return }
        isGenerating = false
        if let conversation = conversationManager.conversation(byId: conversationId) {
            conversationManager.save(conversation)
        }
        if isNewChatMode {
            onConversationCreated?(conversationId)
        }
    }

    private func loadImageData(from source: (data: Data?, path: String?)?) async -> Data? {
        if let data = source?.data {
            return data
        }
        guard let path = source?.path else { return nil }
        return await AttachmentStorage.shared.loadData(path: path)
    }

    private func saveImageData(_ imageData: Data) async -> String? {
        let task = Task.detached(priority: .userInitiated) {
            try? AttachmentStorage.shared.save(data: imageData, extension: "png")
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func deleteImageData(at path: String?) async {
        guard let path else { return }
        await Task.detached(priority: .utility) {
            AttachmentStorage.shared.delete(path: path)
        }.value
    }
}

#endif
