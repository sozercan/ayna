//
//  IOSContentView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import SwiftUI
import UniformTypeIdentifiers

struct IOSContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            IOSSidebarView()
        } detail: {
            if let selectedId = conversationManager.selectedConversationId,
               selectedId != ConversationManager.newConversationId
            {
                IOSChatView(conversationId: selectedId)
            } else {
                IOSNewChatView()
                    .id(conversationManager.selectedConversationId)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct IOSNewChatView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared

    @State private var messageText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var selectedModel = OpenAIService.shared.selectedModel
    @State private var attachedFiles: [URL] = []
    @State private var isFileImporterPresented = false

    /// Track the conversation we created in this view session.
    /// This is only used transiently until we navigate to IOSChatView.
    @State private var pendingConversationId: UUID?

    /// The conversation for this new chat session (if created).
    private var pendingConversation: Conversation? {
        guard let id = pendingConversationId else { return nil }
        return conversationManager.conversations.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = pendingConversation {
                // Show messages while generating (before navigating away)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 12) {
                            ForEach(conversation.messages) { message in
                                IOSMessageView(
                                    message: message,
                                    onRetry: message.role == .assistant ? {
                                        retryMessage(beforeMessage: message, in: conversation)
                                    } : nil
                                )
                                .id(message.id)
                                .accessibilityIdentifier(TestIdentifiers.ChatView.messageRow(for: message.id))
                            }
                        }
                        .padding()
                    }
                    .accessibilityIdentifier(TestIdentifiers.ChatView.messagesList)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: conversation.messages.count) { _ in
                        scrollToBottom(proxy: proxy, conversation: conversation)
                    }
                    .onChange(of: conversation.messages.last?.content) { _ in
                        if isGenerating, let lastId = conversation.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            } else {
                // Empty state - welcome screen
                welcomeView
            }

            IOSMessageComposer(
                messageText: $messageText,
                isGenerating: $isGenerating,
                errorMessage: $errorMessage,
                attachedFiles: $attachedFiles,
                showAttachmentButton: true,
                identifierPrefix: "newchat.composer",
                onSend: sendMessage,
                onCancel: cancelGeneration,
                onAttachmentRequested: { isFileImporterPresented = true }
            )
        }
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(openAIService.usableModels, id: \.self) { model in
                        Button {
                            selectedModel = model
                            openAIService.selectedModel = model
                        } label: {
                            if selectedModel == model {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 0) {
                        Text("New Chat")
                            .font(.headline)
                        HStack(spacing: 4) {
                            Text(selectedModel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(TestIdentifiers.ChatView.modelSelector)
            }
        }
        .onAppear {
            // Reset state when this view appears (new chat requested)
            selectedModel = openAIService.selectedModel
            pendingConversationId = nil
            messageText = ""
            isGenerating = false
            errorMessage = nil
            attachedFiles.removeAll()

            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "📱 IOSNewChatView appeared"
            )
        }
    }

    // MARK: - Welcome View

    @ViewBuilder
    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 8) {
                Text("How can I help you?")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Type a message below to start chatting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(TestIdentifiers.ChatView.emptyState)
    }

    // MARK: - Private Methods

    private func retryMessage(beforeMessage: Message, in conversation: Conversation) {
        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔄 Retrying message in new chat",
            metadata: ["conversationId": conversation.id.uuidString]
        )

        // Find the index of the message to retry
        guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == beforeMessage.id }) else {
            return
        }

        // Remove the assistant message and any subsequent messages
        let updatedMessages = Array(conversation.messages.prefix(messageIndex))

        // Update the conversation
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversationManager.conversations[convIndex].messages = updatedMessages
        }

        // Create a new assistant message placeholder
        let assistantMessage = Message(role: .assistant, content: "")
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        isGenerating = true
        errorMessage = nil

        // Re-fetch conversation with updated messages
        guard let updatedConversation = pendingConversation else { return }
        let messagesToSend = Array(updatedConversation.messages.dropLast())

        openAIService.sendMessage(
            messages: messagesToSend,
            model: updatedConversation.model,
            stream: true,
            onChunk: { chunk in
                Task { @MainActor in
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                       let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == assistantMessage.id })
                    {
                        var updatedMessage = conversationManager.conversations[convIndex].messages[msgIndex]
                        updatedMessage.content += chunk
                        conversationManager.conversations[convIndex].messages[msgIndex] = updatedMessage
                    }
                }
            },
            onComplete: {
                Task { @MainActor in
                    isGenerating = false
                    if let finalConversation = conversationManager.conversations.first(where: { $0.id == conversation.id }) {
                        conversationManager.save(finalConversation)
                    }
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "✅ Retry completed in new chat"
                    )
                }
            },
            onError: { error in
                Task { @MainActor in
                    isGenerating = false
                    errorMessage = error.localizedDescription
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Retry failed: \(error.localizedDescription)"
                    )
                }
            }
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Failed to access security-scoped resource: \(url.lastPathComponent)"
                    )
                    continue
                }
                attachedFiles.append(url)
                DiagnosticsLogger.log(
                    .chatView,
                    level: .info,
                    message: "📎 File attached: \(url.lastPathComponent)"
                )
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

    private func scrollToBottom(proxy: ScrollViewProxy, conversation: Conversation) {
        if let lastId = conversation.messages.last?.id {
            withAnimation {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    private func cancelGeneration() {
        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🛑 Cancelling generation in new chat"
        )
        openAIService.cancelCurrentRequest()
        isGenerating = false
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return }

        // Create conversation if needed
        let conversation: Conversation
        if let existing = pendingConversation {
            conversation = existing
        } else {
            conversationManager.createNewConversation()
            guard let newConv = conversationManager.conversations.first else { return }
            conversation = newConv
            pendingConversationId = newConv.id
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "🆕 Created new conversation",
                metadata: ["conversationId": newConv.id.uuidString]
            )
        }

        // Update model if different
        if conversation.model != selectedModel {
            conversationManager.updateModel(for: conversation, model: selectedModel)
        }

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📤 Sending message in new chat",
            metadata: [
                "conversationId": conversation.id.uuidString,
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
            attachedFiles.removeAll()
        }

        conversationManager.addMessage(to: conversation, message: userMessage)
        messageText = ""
        isGenerating = true
        errorMessage = nil

        // Create placeholder assistant message
        let assistantMessage = Message(role: .assistant, content: "")
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get the conversation ID before async work
        let conversationId = conversation.id

        // Get updated conversation for sending
        guard let updatedConversation = pendingConversation else { return }

        // Messages to send (exclude the empty assistant message we just added)
        let messagesToSend = Array(updatedConversation.messages.dropLast())

        openAIService.sendMessage(
            messages: messagesToSend,
            model: updatedConversation.model,
            stream: true,
            onChunk: { chunk in
                Task { @MainActor in
                    // Update the message in the conversation manager
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                       let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == assistantMessage.id })
                    {
                        var updatedMessage = conversationManager.conversations[convIndex].messages[msgIndex]
                        updatedMessage.content += chunk
                        conversationManager.conversations[convIndex].messages[msgIndex] = updatedMessage
                    }
                }
            },
            onComplete: {
                Task { @MainActor in
                    isGenerating = false
                    if let finalConversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                        conversationManager.save(finalConversation)
                        // Navigate to the conversation in IOSChatView
                        conversationManager.selectedConversationId = conversationId
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "✅ Message completed, switching to chat view",
                            metadata: ["conversationId": conversationId.uuidString]
                        )
                    }
                }
            },
            onError: { error in
                Task { @MainActor in
                    isGenerating = false
                    errorMessage = error.localizedDescription
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Message generation failed: \(error.localizedDescription)"
                    )
                    // Navigate to the conversation even on error if it was created
                    if pendingConversationId != nil {
                        conversationManager.selectedConversationId = conversationId
                    }
                }
            }
        )
    }
}
