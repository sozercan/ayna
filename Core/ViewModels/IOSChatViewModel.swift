// swiftlint:disable file_length
//
//  IOSChatViewModel.swift
//  ayna
//
//  Created on 11/24/25.
//

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

// IOSChatViewModel consolidates iOS chat logic to avoid duplicating state across views.
// A shared ViewModel that encapsulates common chat logic for iOS views.
// Used by both `IOSChatView` (existing conversations) and `IOSNewChatView` (new conversations).
@MainActor final class IOSChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messageText = ""
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var attachedFiles: [URL] = []
    @Published var attachedImages: [UIImage] = []

    /// The name of the tool currently being executed (for UI indicator)
    @Published var currentToolName: String?

    /// The last failed message content, stored for retry functionality
    @Published var failedMessage: String?

    /// Recovery suggestion for the current error (if available)
    @Published var errorRecoverySuggestion: String?

    // MARK: - Dependencies

    var conversationManager: ConversationManager
    let openAIService: OpenAIService

    // MARK: - Tool Call State

    /// Tracks the depth of recursive tool calls to prevent infinite loops
    private var toolCallDepth = 0
    private let maxToolCallDepth = 10

    /// Stores the pending user message text for retry on failure
    private var pendingUserMessage: String?

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
            openAIService: nil
        )
    }

    /// Initialize for an existing conversation.
    init(
        conversationId: UUID,
        conversationManager: ConversationManager,
        openAIService: OpenAIService? = nil
    ) {
        let resolvedOpenAIService = openAIService ?? .shared
        self.conversationId = conversationId
        isNewChatMode = false
        self.conversationManager = conversationManager
        self.openAIService = resolvedOpenAIService
        selectedModel = resolvedOpenAIService.selectedModel
        selectedModels = [resolvedOpenAIService.selectedModel]
    }

    /// Initialize for a new chat (no conversation yet).
    init(
        conversationManager: ConversationManager,
        openAIService: OpenAIService? = nil
    ) {
        let resolvedOpenAIService = openAIService ?? .shared
        conversationId = nil
        isNewChatMode = true
        self.conversationManager = conversationManager
        self.openAIService = resolvedOpenAIService
        selectedModel = resolvedOpenAIService.selectedModel
        selectedModels = [resolvedOpenAIService.selectedModel]
    }

    // MARK: - Computed Properties

    /// The current conversation being managed.
    var conversation: Conversation? {
        guard let id = conversationId else { return nil }
        return conversationManager.conversations.first { $0.id == id }
    }

    // MARK: - Configuration Update

    /// Update the conversation manager reference.
    /// Used when view model was created before environment was available.
    func configure(with manager: ConversationManager) {
        conversationManager = manager
    }

    /// Configure with conversation manager and conversation ID.
    /// Used for existing conversation views.
    func configure(with manager: ConversationManager, conversationId: UUID) {
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
        conversationId = nil
        messageText = ""
        isGenerating = false
        errorMessage = nil
        errorRecoverySuggestion = nil
        failedMessage = nil
        cleanupAttachedFiles()
        attachedImages.removeAll()
        selectedModel = openAIService.selectedModel
        selectedModels = [openAIService.selectedModel]

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

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔗 Processing pending auto-send prompt from deep link",
            metadata: ["promptLength": "\(prompt.count)"]
        )

        // Clear the pending prompt to prevent re-sending
        conversationManager.conversations[index].pendingAutoSendPrompt = nil

        // Set the message text and send
        messageText = prompt
        // Use a small delay to ensure the view is fully loaded
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            sendMessage()
        }
    }

    /// Retry the last failed message
    func retryFailedMessage() {
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
        openAIService.cancelCurrentRequest()
        isGenerating = false
    }

    /// Send a message in the current conversation.
    func sendMessage() { // swiftlint:disable:this function_body_length
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🚀 sendMessage() called",
            metadata: [
                "textLength": "\(text.count)",
                "isGenerating": "\(isGenerating)",
                "hasConversation": "\(conversation != nil)",
                "isNewChatMode": "\(isNewChatMode)"
            ]
        )

        guard !text.isEmpty || !attachedFiles.isEmpty || !attachedImages.isEmpty else {
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "⚠️ Empty message, ignoring"
            )
            return
        }

        // Prevent sending while already generating
        guard !isGenerating else {
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "⚠️ Ignoring send request - already generating"
            )
            return
        }

        // Check for multi-model mode
        if selectedModels.count >= 2 {
            sendToMultipleModels()
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
            if newConv.model != selectedModel {
                conversationManager.updateModel(for: newConv, model: selectedModel)
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
            return
        }

        let targetConversationId = targetConversation.id

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📤 Sending message",
            metadata: [
                "conversationId": targetConversationId.uuidString,
                "textLength": "\(text.count)",
                "attachmentCount": "\(attachedFiles.count)",
                "imageCount": "\(attachedImages.count)",
            ]
        )

        var userMessage = Message(role: .user, content: text)

        // Process file attachments with proper resource cleanup
        if !attachedFiles.isEmpty {
            let result = IOSFileAttachmentUtils.processAttachments(from: attachedFiles)
            userMessage.attachments = result.attachments
            if !result.errors.isEmpty {
                errorMessage = result.errors.joined(separator: "\n")
            }
            cleanupAttachedFiles()
        }

        // Process image attachments from photo library
        if !attachedImages.isEmpty {
            let imageAttachments = IOSFileAttachmentUtils.processImageAttachments(from: attachedImages)
            if userMessage.attachments == nil {
                userMessage.attachments = imageAttachments
            } else {
                userMessage.attachments?.append(contentsOf: imageAttachments)
            }
            attachedImages.removeAll()
        }

        conversationManager.addMessage(to: targetConversation, message: userMessage)

        // Process memory commands (e.g., "remember that I prefer dark mode")
        if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: text) {
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "💾 Memory command processed",
                metadata: ["response": memoryResponse]
            )
        }

        // Store the message text for retry in case of failure
        pendingUserMessage = text
        messageText = ""
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

        // Create placeholder assistant message
        let assistantMessage = Message(role: .assistant, content: "")
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
            return
        }

        // Check if this is an image generation model
        let capability = openAIService.getModelCapability(updatedConversation.model)
        if capability == .imageGeneration {
            generateImage(
                text: text,
                assistantMessage: assistantMessage,
                conversationId: targetConversationId
            )
            return
        }

        // Messages to send (exclude the empty assistant message we just added)
        var messagesToSend = Array(updatedConversation.messages.dropLast())

        // Prepend system prompt if configured
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Get available tools (Tavily web search on iOS)
        let tools = openAIService.getAllAvailableTools()
        toolCallDepth = 0

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📡 Calling sendMessageWithToolSupport",
            metadata: [
                "model": updatedConversation.model,
                "messageCount": "\(messagesToSend.count)",
                "hasTools": "\(tools != nil)",
                "toolCount": "\(tools?.count ?? 0)"
            ]
        )

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: updatedConversation.model,
            conversationId: targetConversationId,
            assistantMessageId: assistantMessage.id,
            tools: tools
        )
    }

    /// Helper method to send messages with tool call support
    private func sendMessageWithToolSupport( // swiftlint:disable:this function_body_length
        messages: [Message],
        model: String,
        conversationId: UUID,
        assistantMessageId: UUID,
        tools: [[String: Any]]?
    ) {
        let toolsWrapper = UncheckedSendable(tools)

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔌 sendMessageWithToolSupport: Calling OpenAI service",
            metadata: [
                "assistantMessageId": assistantMessageId.uuidString,
                "model": model
            ]
        )

        openAIService.sendMessage(
            messages: messages,
            model: model,
            stream: true,
            tools: tools,
            onChunk: { [weak self] chunk in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    // Log first chunk received
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
                    // Clear tool indicator when we start receiving content
                    if self.currentToolName != nil {
                        self.currentToolName = nil
                    }
                    self.updateAssistantMessage(
                        assistantMessageId,
                        appendingChunk: chunk,
                        conversationId: conversationId
                    )
                }
            },
            onComplete: { [weak self] in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "✅ onComplete called",
                        metadata: [
                            "currentToolName": self.currentToolName ?? "none",
                            "assistantMessageId": assistantMessageId.uuidString
                        ]
                    )

                    // Only stop generating if no tool call is pending
                    // If a tool call was requested, keep generating until tool execution completes
                    if self.currentToolName == nil {
                        self.isGenerating = false

                        // Clear pending message on success
                        self.pendingUserMessage = nil

                        // Play message received sound
                        SoundEngine.messageReceived()

                        if let finalConversation = self.conversationManager.conversations.first(where: { $0.id == conversationId }) {
                            self.conversationManager.save(finalConversation)
                        }

                        // Notify that conversation is ready (for new chat navigation)
                        if self.isNewChatMode {
                            self.onConversationCreated?(conversationId)
                        }

                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "✅ Message generation completed",
                            metadata: ["conversationId": conversationId.uuidString]
                        )
                    } else {
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "⏳ onComplete: Tool call pending, keeping isGenerating=true",
                            metadata: ["toolName": self.currentToolName ?? "unknown"]
                        )
                    }
                }
            },
            onError: { [weak self] error in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "🚨 onError callback fired",
                        metadata: [
                            "error": ErrorPresenter.userMessage(for: error),
                            "assistantMessageId": assistantMessageId.uuidString
                        ]
                    )

                    self.isGenerating = false

                    // Play error sound
                    SoundEngine.error()

                    self.currentToolName = nil
                    self.toolCallDepth = 0
                    self.errorMessage = ErrorPresenter.userMessage(for: error)
                    self.errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)

                    // Store the failed message for retry
                    self.failedMessage = self.pendingUserMessage
                    self.pendingUserMessage = nil

                    // Remove the empty assistant placeholder message since we show error in banner
                    self.conversationManager.removeMessage(
                        conversationId: conversationId,
                        messageId: assistantMessageId
                    )

                    // Still notify for navigation even on error if conversation was created
                    if self.isNewChatMode {
                        self.onConversationCreated?(conversationId)
                    }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Message generation failed: \(ErrorPresenter.userMessage(for: error))",
                        metadata: ["conversationId": conversationId.uuidString]
                    )
                }
            },
            onToolCallRequested: { [weak self] toolCallId, toolName, arguments in
                let selfRef = self
                let argumentsWrapper = UncheckedSendable(arguments)
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    let arguments = argumentsWrapper.value

                    // Validate conversation still exists
                    guard self.conversationManager.conversations.contains(where: { $0.id == conversationId }) else {
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .default,
                            message: "⚠️ Tool call requested but conversation no longer exists"
                        )
                        self.isGenerating = false
                        self.currentToolName = nil
                        return
                    }

                    self.currentToolName = toolName
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "🔧 Tool call requested: \(toolName)",
                        metadata: ["toolName": toolName]
                    )

                    // Check depth limit
                    guard self.toolCallDepth < self.maxToolCallDepth else {
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .error,
                            message: "⚠️ Max tool call depth reached"
                        )
                        self.isGenerating = false
                        self.currentToolName = nil
                        self.errorMessage = "Tool call limit reached. Please try again."
                        // Remove the empty assistant placeholder message
                        self.conversationManager.removeMessage(
                            conversationId: conversationId,
                            messageId: assistantMessageId
                        )
                        return
                    }

                    self.toolCallDepth += 1

                    // Store tool call in the last assistant message using safe ID-based access
                    if let conv = self.conversationManager.conversation(byId: conversationId),
                       let lastMessage = conv.messages.last,
                       lastMessage.role == .assistant
                    {
                        let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                            result[pair.key] = AnyCodable(pair.value)
                        }
                        let toolCall = MCPToolCall(
                            id: toolCallId,
                            toolName: toolName,
                            arguments: anyCodableArgs
                        )
                        self.conversationManager.updateMessage(
                            conversationId: conversationId,
                            messageId: lastMessage.id
                        ) { message in
                            message.toolCalls = [toolCall]
                        }
                        if let updatedConv = self.conversationManager.conversation(byId: conversationId) {
                            self.conversationManager.save(updatedConv)
                        }
                    }

                    // Execute the tool
                    Task {
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "⚙️ Executing tool: \(toolName)"
                        )

                        // Execute built-in tool with citations (Tavily web search)
                        let (result, citations) = await self.openAIService.executeBuiltInToolWithCitations(
                            name: toolName,
                            arguments: argumentsWrapper.value
                        )

                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "✅ Tool result received (\(result.count) chars, \(citations?.count ?? 0) citations)"
                        )

                        await MainActor.run {
                            let anyCodableArgs = argumentsWrapper.value.reduce(into: [String: AnyCodable]()) { result, pair in
                                result[pair.key] = AnyCodable(pair.value)
                            }

                            // For web_search, skip creating a tool message and attach citations to assistant
                            let isWebSearch = toolName == "web_search"

                            if !isWebSearch {
                                // For non-web-search tools, create the tool message as before
                                var toolMessage = Message(role: .tool, content: result)
                                toolMessage.toolCalls = [
                                    MCPToolCall(
                                        id: toolCallId,
                                        toolName: toolName,
                                        arguments: anyCodableArgs,
                                        result: result
                                    )
                                ]
                                guard let conv = self.conversationManager.conversation(byId: conversationId) else {
                                    self.isGenerating = false
                                    self.currentToolName = nil
                                    self.toolCallDepth = 0
                                    return
                                }
                                self.conversationManager.addMessage(to: conv, message: toolMessage)
                            }

                            // Continue conversation with tool result
                            guard let updatedConv = self.conversationManager.conversation(byId: conversationId) else {
                                self.isGenerating = false
                                self.currentToolName = nil
                                self.toolCallDepth = 0
                                return
                            }

                            // Add a new empty assistant message for the model's response
                            // For web_search, attach citations to this message
                            var continuationAssistantMessage = Message(role: .assistant, content: "", model: model)
                            if isWebSearch, let citations {
                                continuationAssistantMessage.citations = citations
                            }
                            self.conversationManager.addMessage(to: updatedConv, message: continuationAssistantMessage)

                            // Get conversation again with new assistant message
                            guard let convWithAssistant = self.conversationManager.conversation(byId: conversationId) else {
                                self.isGenerating = false
                                self.currentToolName = nil
                                self.toolCallDepth = 0
                                return
                            }

                            // Build messages for API - exclude the continuation assistant message
                            // The continuation message is just a placeholder for where we'll store the response
                            var continuationMessages = Array(convWithAssistant.messages.dropLast())
                            if isWebSearch {
                                // Append a synthetic tool message for the API only
                                var syntheticToolMessage = Message(role: .tool, content: result)
                                syntheticToolMessage.toolCalls = [
                                    MCPToolCall(
                                        id: toolCallId,
                                        toolName: toolName,
                                        arguments: anyCodableArgs,
                                        result: result
                                    )
                                ]
                                // Append the tool message at the end (after the assistant with tool_calls)
                                continuationMessages.append(syntheticToolMessage)
                            }

                            if let sysPrompt = self.conversationManager.effectiveSystemPrompt(for: convWithAssistant) {
                                let sysMessage = Message(role: .system, content: sysPrompt)
                                continuationMessages.insert(sysMessage, at: 0)
                            }

                            // Clear tool name since tool execution is complete
                            // The continuation is now a regular API call
                            self.currentToolName = nil

                            self.sendMessageWithToolSupport(
                                messages: continuationMessages,
                                model: model,
                                conversationId: conversationId,
                                assistantMessageId: continuationAssistantMessage.id,
                                tools: toolsWrapper.value
                            )
                        }
                    }
                }
            }
        )
    }

    /// Get the ID of the last assistant message in the conversation
    private func getLastAssistantMessageId(conversationId: UUID) -> UUID? {
        guard let conv = conversationManager.conversations.first(where: { $0.id == conversationId }),
              let lastMessage = conv.messages.last,
              lastMessage.role == .assistant
        else {
            return nil
        }
        return lastMessage.id
    }

    /// Retry from a specific assistant message.
    func retryMessage(beforeMessage: Message) {
        guard let conversation else { return }
        let targetConversationId = conversation.id

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
        let assistantMessage = Message(role: .assistant, content: "")
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        isGenerating = true
        errorMessage = nil

        // Re-fetch conversation with updated messages
        guard let updatedConversation = self.conversation else { return }
        var messagesToSend = Array(updatedConversation.messages.dropLast())

        // Prepend system prompt if configured
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Get available tools and use helper method
        let tools = openAIService.getAllAvailableTools()
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: updatedConversation.model,
            conversationId: targetConversationId,
            assistantMessageId: assistantMessage.id,
            tools: tools
        )
    }

    /// Switch to a different model and retry the message.
    /// This retries with the specified model without changing the conversation's default model.
    func switchModelAndRetry(beforeMessage: Message, newModel: String) {
        guard let conversation else { return }
        let targetConversationId = conversation.id

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
        let assistantMessage = Message(role: .assistant, content: "", model: newModel)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        isGenerating = true
        errorMessage = nil

        // Re-fetch conversation with updated messages
        guard let updatedConversation = self.conversation else { return }
        var messagesToSend = Array(updatedConversation.messages.dropLast())

        // Prepend system prompt if configured
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Get available tools and use helper method
        let tools = openAIService.getAllAvailableTools()
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

    // MARK: - Multi-Model Message Sending

    // MARK: - Private Methods

    private func updateAssistantMessage(_ messageId: UUID, appendingChunk chunk: String, conversationId: UUID) {
        // Use safe ID-based append instead of index-based access
        let success = conversationManager.appendToMessage(
            conversationId: conversationId,
            messageId: messageId,
            chunk: chunk
        )

        if !success {
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
        for url in attachedFiles where FileManager.default.fileExists(atPath: url.path) {
            // Only delete if it's in the temp directory to be safe
            // Note: temporaryDirectory path might be symlinked, so we just check if it exists and is a file
            try? FileManager.default.removeItem(at: url)
        }
        attachedFiles.removeAll()
    }
}

// MARK: - Multi-Model Message Sending

extension IOSChatViewModel {
    /// Sends a message to multiple models in parallel for comparison
    func sendToMultipleModels() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let targetConversation = getOrCreateConversationForMultiModel() else { return }
        let conversationId = targetConversation.id

        // Check for image generation and route accordingly
        if let firstModel = selectedModels.first,
           openAIService.getModelCapability(firstModel) == .imageGeneration
        {
            generateImagesWithMultipleModels(prompt: text, models: Array(selectedModels), conversation: targetConversation)
            return
        }

        DiagnosticsLogger.log(.chatView, level: .info, message: "🔀 Starting iOS multi-model request",
                              metadata: ["models": selectedModels.map(\.self).joined(separator: ", ")])

        let userMessage = Message(role: .user, content: text)
        conversationManager.addMessage(to: targetConversation, message: userMessage)

        if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: text) {
            DiagnosticsLogger.log(.chatView, level: .info, message: "💾 Memory command processed",
                                  metadata: ["response": memoryResponse])
        }

        messageText = ""
        isGenerating = true
        errorMessage = nil

        let responseGroupId = UUID()
        let models = Array(selectedModels)
        var messageIds: [String: UUID] = [:]
        var placeholderMessages: [Message] = []
        let responseGroup = createPlaceholderMessagesForMultiModel(
            models: models, userMessageId: userMessage.id, responseGroupId: responseGroupId,
            messageIds: &messageIds, placeholderMessages: &placeholderMessages
        )
        conversationManager.addMultiModelResponse(to: targetConversation, messages: placeholderMessages, responseGroup: responseGroup)

        guard let updatedConversation = conversation else { return }
        var messagesToSend = updatedConversation.getEffectiveHistory().filter { $0.responseGroupId != responseGroupId }
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            messagesToSend.insert(Message(role: .system, content: systemPrompt), at: 0)
        }

        // Send to all models
        openAIService.sendToMultipleModels(
            messages: messagesToSend,
            models: models,
            temperature: updatedConversation.temperature,
            onChunk: { [weak self] model, chunk in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    self.processMultiModelChunk(
                        model: model,
                        chunk: chunk,
                        messageIds: messageIds,
                        conversationId: conversationId
                    )
                }
            },
            onModelComplete: { [weak self] model in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    self.processMultiModelCompletion(
                        model: model,
                        messageIds: messageIds,
                        conversationId: conversationId,
                        responseGroupId: responseGroupId
                    )
                }
            },
            onAllComplete: { [weak self] in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    self.isGenerating = false
                    if let convIndex = self.conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) {
                        self.conversationManager.save(self.conversationManager.conversations[convIndex])
                    }

                    // Notify that conversation is ready (for new chat navigation)
                    if self.isNewChatMode {
                        self.onConversationCreated?(conversationId)
                    }
                }
            },
            onError: { [weak self] model, error in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    self.processMultiModelError(
                        model: model,
                        error: error,
                        messageIds: messageIds,
                        conversationId: conversationId,
                        responseGroupId: responseGroupId
                    )
                }
            },
            onPendingToolCall: nil,
            onReasoning: nil
        )
    }

    /// Gets or creates a conversation configured for multi-model mode
    func getOrCreateConversationForMultiModel() -> Conversation? {
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
        if let first = selectedModels.first { updatedConv.model = first }
        conversationManager.updateConversation(updatedConv)

        DiagnosticsLogger.log(.chatView, level: .info, message: "🆕 Created new multi-model conversation",
                              metadata: ["conversationId": newConv.id.uuidString])
        return updatedConv
    }

    /// Creates placeholder messages for each model in a multi-model request
    func createPlaceholderMessagesForMultiModel(
        models: [String],
        userMessageId: UUID,
        responseGroupId: UUID,
        messageIds: inout [String: UUID],
        placeholderMessages: inout [Message]
    ) -> ResponseGroup {
        var responseGroup = ResponseGroup(id: responseGroupId, userMessageId: userMessageId)
        for model in models {
            let messageId = UUID()
            messageIds[model] = messageId
            responseGroup.addResponse(messageId: messageId, modelName: model, status: .streaming)
            placeholderMessages.append(Message(id: messageId, role: .assistant, content: "", model: model, responseGroupId: responseGroupId))
        }
        return responseGroup
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

        let success = conversationManager.appendToMessage(
            conversationId: conversationId,
            messageId: messageId,
            chunk: chunk
        )

        if !success {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Failed to append chunk - conversation or message not found",
                metadata: ["conversationId": conversationId.uuidString, "messageId": messageId.uuidString]
            )
        }
    }

    /// Processes completion for a specific model in multi-model mode
    func processMultiModelCompletion(
        model: String,
        messageIds: [String: UUID],
        conversationId: UUID,
        responseGroupId: UUID
    ) {
        guard let messageId = messageIds[model] else { return }

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
    }
}

// MARK: - Image Generation

extension IOSChatViewModel {
    /// Finds the most recent generated or selected image in the conversation for editing context.
    func findPreviousImage() -> Data? {
        guard let conversation else { return nil }

        // Look for the most recent assistant message with an image
        // Prioritize selected responses from multi-model groups
        for message in conversation.messages.reversed() {
            guard message.role == .assistant, message.mediaType == .image else { continue }

            // If this message is part of a response group, only use it if it was selected
            if let groupId = message.responseGroupId {
                if let group = conversation.getResponseGroup(groupId),
                   group.selectedResponseId == message.id
                {
                    return message.effectiveImageData
                }
                // Skip unselected multi-model responses
                continue
            }

            // Single-model image - use it
            return message.effectiveImageData
        }
        return nil
    }

    /// Handles image generation or editing for a single model
    func generateImage(text: String, assistantMessage: Message, conversationId: UUID) {
        guard let conversation else { return }

        // Check if we have a previous image to edit
        let previousImage = findPreviousImage()

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: previousImage != nil ? "📝 Starting image edit" : "🎨 Starting image generation",
            metadata: ["prompt": text, "hasContext": "\(previousImage != nil)"]
        )

        let onComplete: @Sendable (Data) -> Void = { [weak self] data in
            let selfRef = self
            Task { @MainActor in
                guard let self = selfRef else { return }

                // Save image to disk
                var imagePath: String?
                do {
                    imagePath = try AttachmentStorage.shared.save(data: data, extension: "png")
                } catch {
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Failed to save generated image: \(error.localizedDescription)"
                    )
                }

                if let convIndex = self.conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                   let msgIndex = self.conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == assistantMessage.id })
                {
                    var updatedMessage = self.conversationManager.conversations[convIndex].messages[msgIndex]
                    updatedMessage.mediaType = .image
                    if let path = imagePath {
                        updatedMessage.imagePath = path
                        updatedMessage.imageData = nil
                    } else {
                        updatedMessage.imageData = data
                        updatedMessage.imagePath = nil
                    }
                    updatedMessage.content = ""
                    self.conversationManager.conversations[convIndex].messages[msgIndex] = updatedMessage
                    self.conversationManager.save(self.conversationManager.conversations[convIndex])
                }
                self.isGenerating = false

                // Notify that conversation is ready (for new chat navigation)
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
            let selfRef = self
            Task { @MainActor in
                guard let self = selfRef else { return }
                self.isGenerating = false
                self.errorMessage = error.localizedDescription

                // Still notify for navigation even on error
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

        if let previousImage {
            // Use image editing API for follow-up requests
            openAIService.editImage(
                prompt: text,
                sourceImage: previousImage,
                model: conversation.model,
                onComplete: onComplete,
                onError: onError
            )
        } else {
            // No previous image - use generation API
            openAIService.generateImage(
                prompt: text,
                model: conversation.model,
                onComplete: onComplete,
                onError: onError
            )
        }
    }

    /// Generates images from multiple models in parallel for comparison
    func generateImagesWithMultipleModels(prompt: String, models: [String], conversation: Conversation) {
        let conversationId = conversation.id

        // Check if we have a previous image to edit (must check BEFORE adding user message)
        let previousImage = findPreviousImage()

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: previousImage != nil ? "📝 Starting multi-model image edit" : "🎨 Starting multi-model image generation",
            metadata: ["prompt": prompt, "models": models.joined(separator: ", "), "hasContext": "\(previousImage != nil)"]
        )

        // Create user message
        let userMessage = Message(role: .user, content: prompt)
        conversationManager.addMessage(to: conversation, message: userMessage)

        messageText = ""
        isGenerating = true
        errorMessage = nil

        // Create a response group for the multi-model comparison
        let responseGroupId = UUID()
        var responseEntries: [ResponseGroup.ResponseEntry] = []
        var messageIds: [String: UUID] = [:]

        // Create placeholder messages for each model
        for model in models {
            let messageId = UUID()
            messageIds[model] = messageId

            let placeholderMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId,
                mediaType: .image
            )
            conversationManager.addMessage(to: conversation, message: placeholderMessage)

            responseEntries.append(ResponseGroup.ResponseEntry(
                id: messageId,
                modelName: model,
                status: .streaming
            ))
        }

        // Create response group
        let responseGroup = ResponseGroup(
            id: responseGroupId,
            userMessageId: userMessage.id,
            responses: responseEntries
        )

        // Add response group to conversation
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) {
            conversationManager.conversations[index].responseGroups.append(responseGroup)
        }

        // Track completion state using a class to allow mutation in closures
        final class CompletionTracker: @unchecked Sendable {
            var count = 0
        }
        let tracker = CompletionTracker()
        let totalCount = models.count

        // Generate/edit images in parallel
        for model in models {
            guard let messageId = messageIds[model] else { continue }

            let onComplete: @Sendable (Data) -> Void = { [weak self] imageData in
                Task { @MainActor in
                    guard let self else { return }
                    self.processImageSuccess(
                        imageData: imageData,
                        conversationId: conversationId,
                        messageId: messageId,
                        responseGroupId: responseGroupId,
                        completedCount: &tracker.count,
                        totalCount: totalCount
                    )
                }
            }

            let onError: @Sendable (Error) -> Void = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.processImageError(
                        error: error,
                        model: model,
                        conversationId: conversationId,
                        messageId: messageId,
                        responseGroupId: responseGroupId,
                        completedCount: &tracker.count,
                        totalCount: totalCount
                    )
                }
            }

            if let previousImage {
                openAIService.editImage(prompt: prompt, sourceImage: previousImage, model: model, onComplete: onComplete, onError: onError)
            } else {
                openAIService.generateImage(prompt: prompt, model: model, onComplete: onComplete, onError: onError)
            }
        }
    }

    /// Processes successful image generation for a model
    func processImageSuccess(
        imageData: Data,
        conversationId: UUID,
        messageId: UUID,
        responseGroupId: UUID,
        completedCount: inout Int,
        totalCount: Int
    ) {
        var imagePath: String?
        do {
            imagePath = try AttachmentStorage.shared.save(data: imageData, extension: "png")
        } catch {
            DiagnosticsLogger.log(
                .chatView,
                level: .error,
                message: "❌ Failed to save generated image: \(error.localizedDescription)"
            )
        }

        conversationManager.updateMessage(conversationId: conversationId, messageId: messageId) { message in
            message.content = ""
            if let path = imagePath {
                message.imagePath = path
                message.imageData = nil
            } else {
                message.imageData = imageData
                message.imagePath = nil
            }
        }

        updateImageResponseGroupStatus(conversationId: conversationId, responseGroupId: responseGroupId, messageId: messageId, status: .completed)

        completedCount += 1
        if completedCount >= totalCount {
            finalizeImageGenerationBatch(conversationId: conversationId)
        }
    }

    /// Processes an error during image generation for a model
    func processImageError(
        error: Error,
        model: String,
        conversationId: UUID,
        messageId: UUID,
        responseGroupId: UUID,
        completedCount: inout Int,
        totalCount: Int
    ) {
        DiagnosticsLogger.log(
            .chatView,
            level: .error,
            message: "❌ Image generation failed for \(model): \(error.localizedDescription)",
            metadata: ["model": model]
        )

        updateImageResponseGroupStatus(conversationId: conversationId, responseGroupId: responseGroupId, messageId: messageId, status: .failed)

        conversationManager.updateMessage(conversationId: conversationId, messageId: messageId) { message in
            message.content = "Image generation failed: \(error.localizedDescription)"
        }

        completedCount += 1
        if completedCount >= totalCount {
            finalizeImageGenerationBatch(conversationId: conversationId)
        }
    }

    /// Updates the status of a response in a response group for image generation
    func updateImageResponseGroupStatus(conversationId: UUID, responseGroupId: UUID, messageId: UUID, status: ResponseGroup.ResponseStatus) {
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
           let groupIndex = conversationManager.conversations[convIndex].responseGroups.firstIndex(where: { $0.id == responseGroupId }),
           let entryIndex = conversationManager.conversations[convIndex].responseGroups[groupIndex].responses.firstIndex(where: { $0.id == messageId })
        {
            conversationManager.conversations[convIndex].responseGroups[groupIndex].responses[entryIndex].status = status
        }
    }

    /// Finalizes a batch of image generation requests
    func finalizeImageGenerationBatch(conversationId: UUID) {
        isGenerating = false
        if let conv = conversationManager.conversations.first(where: { $0.id == conversationId }) {
            conversationManager.save(conv)
        }
        if isNewChatMode {
            onConversationCreated?(conversationId)
        }
    }
}
