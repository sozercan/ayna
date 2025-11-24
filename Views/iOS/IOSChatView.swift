//
//  IOSChatView.swift
//  ayna
//
//  Created on 11/22/25.
//

import SwiftUI

struct IOSChatView: View {
    let conversationId: UUID
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared

    @State private var messageText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var conversation: Conversation? {
        conversationManager.conversations.first(where: { $0.id == conversationId })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(conversation.messages) { message in
                                IOSMessageView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: conversation.messages.count) { _ in
                        scrollToBottom(proxy: proxy, conversation: conversation)
                    }
                    .onAppear {
                        scrollToBottom(proxy: proxy, conversation: conversation)
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

            HStack(alignment: .bottom, spacing: 12) {
                Button(action: { }) {
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
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    if messageText.isEmpty && !isGenerating {
                        Button(action: { }) {
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
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(conversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
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
            // Handle stop generation
            return
        }

        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMessage = Message(role: .user, content: text)
        conversationManager.addMessage(to: conversation, message: userMessage)
        messageText = ""
        isGenerating = true
        errorMessage = nil

        // Create placeholder assistant message
        let assistantMessage = Message(role: .assistant, content: "")
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // We need to get the updated conversation from manager to pass to service
        guard let updatedConversation = self.conversation else { return }

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
                       let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == assistantMessage.id }) {

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
