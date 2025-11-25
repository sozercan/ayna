//
//  IOSChatView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import SwiftUI
import UniformTypeIdentifiers

struct IOSChatView: View {
    let conversationId: UUID
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared

    @State private var messageText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var attachedFiles: [URL] = []
    @State private var isFileImporterPresented = false

    var conversation: Conversation? {
        conversationManager.conversations.first(where: { $0.id == conversationId })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 12) {
                            ForEach(conversation.messages) { message in
                                IOSMessageView(message: message)
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
                    .onAppear {
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "📱 IOSChatView appeared",
                            metadata: ["conversationId": conversationId.uuidString]
                        )
                        // Scroll to bottom after a short delay to ensure content is laid out
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            if let lastId = conversation.messages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Conversation not found", systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier(TestIdentifiers.ChatView.emptyState)
            }

            IOSMessageComposer(
                messageText: $messageText,
                isGenerating: $isGenerating,
                errorMessage: $errorMessage,
                attachedFiles: $attachedFiles,
                showAttachmentButton: true,
                identifierPrefix: "chat.composer",
                onSend: sendMessage,
                onCancel: cancelGeneration,
                onAttachmentRequested: { isFileImporterPresented = true }
            )
        }
        .navigationTitle(conversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .toolbar {
            if let conversation {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(conversation.title)
                            .font(.headline)

                        Menu {
                            ForEach(openAIService.usableModels, id: \.self) { model in
                                Button {
                                    conversationManager.updateModel(for: conversation, model: model)
                                } label: {
                                    if conversation.model == model {
                                        Label(model, systemImage: "checkmark")
                                    } else {
                                        Text(model)
                                    }
                                }
                            }
                        } label: {
                            Text(conversation.model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(TestIdentifiers.ChatView.modelSelector)
                    }
                }
            }
        }
    }

    // MARK: - Private Methods

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
            message: "🛑 Cancelling generation",
            metadata: ["conversationId": conversationId.uuidString]
        )
        openAIService.cancelCurrentRequest()
        isGenerating = false
    }

    private func sendMessage() {
        guard let conversation else { return }

        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return }

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "📤 Sending message",
            metadata: [
                "conversationId": conversationId.uuidString,
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

        // We need to get the updated conversation from manager to pass to service
        guard let updatedConversation = self.conversation else { return }

        let capability = openAIService.getModelCapability(updatedConversation.model)

        if capability == .imageGeneration {
            handleImageGeneration(text: text, assistantMessage: assistantMessage)
            return
        }

        // Messages to send (exclude the empty assistant message we just added)
        let messagesToSend = Array(updatedConversation.messages.dropLast())

        openAIService.sendMessage(
            messages: messagesToSend,
            model: updatedConversation.model,
            stream: true,
            onChunk: { chunk in
                Task { @MainActor in
                    updateAssistantMessage(assistantMessage.id, appendingChunk: chunk)
                }
            },
            onComplete: {
                Task { @MainActor in
                    isGenerating = false
                    if let updatedConv = self.conversation {
                        conversationManager.save(updatedConv)
                    }
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "✅ Message generation completed",
                        metadata: ["conversationId": conversationId.uuidString]
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
                        message: "❌ Message generation failed: \(error.localizedDescription)",
                        metadata: ["conversationId": conversationId.uuidString]
                    )
                }
            }
        )
    }

    private func handleImageGeneration(text: String, assistantMessage: Message) {
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
            onComplete: { data in
                Task { @MainActor in
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                       let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == assistantMessage.id })
                    {
                        var updatedMessage = conversationManager.conversations[convIndex].messages[msgIndex]
                        updatedMessage.mediaType = .image
                        updatedMessage.imageData = data
                        updatedMessage.content = "Generated image for: \(text)"
                        conversationManager.conversations[convIndex].messages[msgIndex] = updatedMessage
                        conversationManager.save(conversationManager.conversations[convIndex])
                    }
                    isGenerating = false
                    DiagnosticsLogger.log(
                        .chatView,
                        level: .info,
                        message: "✅ Image generation completed"
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
                        message: "❌ Image generation failed: \(error.localizedDescription)"
                    )
                }
            }
        )
    }

    private func updateAssistantMessage(_ messageId: UUID, appendingChunk chunk: String) {
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
           let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        {
            var updatedMessage = conversationManager.conversations[convIndex].messages[msgIndex]
            updatedMessage.content += chunk
            conversationManager.conversations[convIndex].messages[msgIndex] = updatedMessage
        }
    }
}
