//
//  IOSChatViewModel.swift
//  ayna
//
//  Created on 11/24/25.
//

import Combine
import Foundation
import os.log

/// A shared ViewModel that encapsulates common chat logic for iOS views.
/// Used by both `IOSChatView` (existing conversations) and `IOSNewChatView` (new conversations).
@MainActor
final class IOSChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messageText = ""
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var attachedFiles: [URL] = []

    // MARK: - Dependencies

    private var conversationManager: ConversationManager
    private let openAIService: OpenAIService

    // MARK: - Configuration

    /// The conversation ID this view model is managing.
    /// For new chats, this starts as nil and gets set when first message is sent.
    private(set) var conversationId: UUID?

    /// Whether this is a "new chat" view model (creates conversation on first message).
    let isNewChatMode: Bool

    /// Selected model for new chats (ignored for existing conversations).
    @Published var selectedModel: String

    /// Callback when a new conversation is created and first response completes.
    /// Used by IOSNewChatView to navigate to IOSChatView.
    var onConversationCreated: ((UUID) -> Void)?

    // MARK: - Initialization

    /// Create a placeholder ViewModel for use with @StateObject.
    /// Must call `configure(with:conversationId:)` in onAppear.
    static func placeholder() -> IOSChatViewModel {
        IOSChatViewModel(
            conversationManager: ConversationManager(),
            openAIService: .shared
        )
    }

    /// Initialize for an existing conversation.
    init(
        conversationId: UUID,
        conversationManager: ConversationManager,
        openAIService: OpenAIService = .shared
    ) {
        self.conversationId = conversationId
        isNewChatMode = false
        self.conversationManager = conversationManager
        self.openAIService = openAIService
        selectedModel = openAIService.selectedModel
    }

    /// Initialize for a new chat (no conversation yet).
    init(
        conversationManager: ConversationManager,
        openAIService: OpenAIService = .shared
    ) {
        conversationId = nil
        isNewChatMode = true
        self.conversationManager = conversationManager
        self.openAIService = openAIService
        selectedModel = openAIService.selectedModel
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
        cleanupAttachedFiles()
        selectedModel = openAIService.selectedModel

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📱 IOSChatViewModel reset for new chat"
        )
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
    func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return }

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
            ]
        )

        var userMessage = Message(role: .user, content: text)

        // Process attachments with proper resource cleanup
        if !attachedFiles.isEmpty {
            let result = IOSFileAttachmentUtils.processAttachments(from: attachedFiles)
            userMessage.attachments = result.attachments
            if !result.errors.isEmpty {
                errorMessage = result.errors.joined(separator: "\n")
            }
            cleanupAttachedFiles()
        }

        conversationManager.addMessage(to: targetConversation, message: userMessage)
        messageText = ""
        isGenerating = true
        errorMessage = nil

        // Create placeholder assistant message
        let assistantMessage = Message(role: .assistant, content: "")
        conversationManager.addMessage(to: targetConversation, message: assistantMessage)

        // Re-fetch conversation with updated messages
        guard let updatedConversation = conversation else { return }

        // Check if this is an image generation model
        let capability = openAIService.getModelCapability(updatedConversation.model)
        if capability == .imageGeneration {
            handleImageGeneration(
                text: text,
                assistantMessage: assistantMessage,
                conversationId: targetConversationId
            )
            return
        }

        // Messages to send (exclude the empty assistant message we just added)
        let messagesToSend = Array(updatedConversation.messages.dropLast())

        openAIService.sendMessage(
            messages: messagesToSend,
            model: updatedConversation.model,
            stream: true,
            onChunk: { [weak self] chunk in
                Task { @MainActor in
                    self?.updateAssistantMessage(assistantMessage.id, appendingChunk: chunk, conversationId: targetConversationId)
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isGenerating = false
                    if let finalConversation = self.conversationManager.conversations.first(where: { $0.id == targetConversationId }) {
                        self.conversationManager.save(finalConversation)
                    }

                    // Notify that conversation is ready (for new chat navigation)
                    if self.isNewChatMode {
                        self.onConversationCreated?(targetConversationId)
                    }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "✅ Message generation completed",
                        metadata: ["conversationId": targetConversationId.uuidString]
                    )
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isGenerating = false
                    self.errorMessage = error.localizedDescription

                    // Still notify for navigation even on error if conversation was created
                    if self.isNewChatMode {
                        self.onConversationCreated?(targetConversationId)
                    }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Message generation failed: \(error.localizedDescription)",
                        metadata: ["conversationId": targetConversationId.uuidString]
                    )
                }
            }
        )
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
        let messagesToSend = Array(updatedConversation.messages.dropLast())

        openAIService.sendMessage(
            messages: messagesToSend,
            model: updatedConversation.model,
            stream: true,
            onChunk: { [weak self] chunk in
                Task { @MainActor in
                    self?.updateAssistantMessage(assistantMessage.id, appendingChunk: chunk, conversationId: targetConversationId)
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isGenerating = false
                    if let finalConversation = self.conversationManager.conversations.first(where: { $0.id == targetConversationId }) {
                        self.conversationManager.save(finalConversation)
                    }
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "✅ Retry completed",
                        metadata: ["conversationId": targetConversationId.uuidString]
                    )
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isGenerating = false
                    self.errorMessage = error.localizedDescription
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Retry failed: \(error.localizedDescription)",
                        metadata: ["conversationId": targetConversationId.uuidString]
                    )
                }
            }
        )
    }

    // MARK: - Private Methods

    private func handleImageGeneration(text: String, assistantMessage: Message, conversationId: UUID) {
        guard let conversation else { return }

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🎨 Starting image generation",
            metadata: ["prompt": text]
        )

        openAIService.generateImage(
            prompt: text,
            model: conversation.model,
            onComplete: { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    if let convIndex = self.conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                       let msgIndex = self.conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == assistantMessage.id })
                    {
                        var updatedMessage = self.conversationManager.conversations[convIndex].messages[msgIndex]
                        updatedMessage.mediaType = .image
                        updatedMessage.imageData = data
                        updatedMessage.content = "Generated image for: \(text)"
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
                        message: "✅ Image generation completed"
                    )
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isGenerating = false
                    self.errorMessage = error.localizedDescription

                    // Still notify for navigation even on error
                    if self.isNewChatMode {
                        self.onConversationCreated?(conversationId)
                    }

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Image generation failed: \(error.localizedDescription)"
                    )
                }
            }
        )
    }

    private func updateAssistantMessage(_ messageId: UUID, appendingChunk chunk: String, conversationId: UUID) {
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
           let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        {
            var updatedMessage = conversationManager.conversations[convIndex].messages[msgIndex]
            updatedMessage.content += chunk
            conversationManager.conversations[convIndex].messages[msgIndex] = updatedMessage
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
