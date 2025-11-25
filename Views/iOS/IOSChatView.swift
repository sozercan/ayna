//
//  IOSChatView.swift
//  ayna
//
//  Created on 11/22/25.
//

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
                            }
                        }
                        .padding()
                    }
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
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            VStack(spacing: 8) {
                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachedFiles, id: \.self) { url in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.fill")
                                        .font(.caption)
                                    Text(url.lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Button {
                                        attachedFiles.removeAll { $0 == url }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                }
                                .padding(6)
                                .background(Color(uiColor: .systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                HStack(alignment: .bottom, spacing: 12) {
                    Button(action: { isFileImporterPresented = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.gray)
                            .padding(8)
                            .background(Color(uiColor: .systemGray5))
                            .clipShape(Circle())
                    }
                    .padding(.bottom, 5)

                    HStack(alignment: .bottom) {
                        TextField("iMessage", text: $messageText, axis: .vertical)
                            .lineLimit(1 ... 5)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                        if messageText.isEmpty, !isGenerating {
                            Button(action: {}) {
                                Image(systemName: "mic.fill")
                                    .foregroundStyle(.gray)
                            }
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                        }
                    }
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                    if !messageText.isEmpty || isGenerating {
                        Button(action: sendMessage) {
                            Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(isGenerating ? .red : .blue)
                        }
                        .padding(.bottom, 2)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(conversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    attachedFiles.append(url)
                }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
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
                    }
                }
            }
        }
    }

    private func getMimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "pdf":
            return "application/pdf"
        case "txt", "md":
            return "text/plain"
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, conversation: Conversation) {
        if let lastId = conversation.messages.last?.id {
            withAnimation {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    private func sendMessage() {
        guard let conversation else { return }

        if isGenerating {
            openAIService.cancelCurrentRequest()
            isGenerating = false
            return
        }

        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return }

        var userMessage = Message(role: .user, content: text)

        if !attachedFiles.isEmpty {
            var attachments: [Message.FileAttachment] = []
            for url in attachedFiles {
                do {
                    let data = try Data(contentsOf: url)
                    attachments.append(Message.FileAttachment(
                        fileName: url.lastPathComponent,
                        mimeType: getMimeType(for: url),
                        data: data
                    ))
                    url.stopAccessingSecurityScopedResource()
                } catch {
                    print("Error reading file: \(error)")
                }
            }
            userMessage.attachments = attachments
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
            openAIService.generateImage(
                prompt: text,
                model: updatedConversation.model,
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
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        isGenerating = false
                        errorMessage = error.localizedDescription
                    }
                }
            )
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
                    if let updatedConv = self.conversation {
                        conversationManager.save(updatedConv)
                    }
                }
            },
            onError: { error in
                Task { @MainActor in
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        )
    }
}
