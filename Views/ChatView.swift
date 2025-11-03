//
//  ChatView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared

    @State private var messageText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            // Chat background with subtle gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                    if conversation.messages.isEmpty {
                        // Empty state
                        VStack(spacing: 16) {
                            Spacer()

                            Image(systemName: "message")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(Color.secondary.opacity(0.4))

                            Text("How can I help you today?")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(Color.primary)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 400)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(conversation.messages.filter { $0.role != .system && !$0.content.isEmpty }) { message in
                                MessageView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                    }
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    if let lastMessage = conversation.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Start at bottom when conversation is first loaded
                    if let lastMessage = conversation.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.id) { _, _ in
                    // Start at bottom when switching conversations
                    if let lastMessage = conversation.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }

            // Error Message
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") {
                        errorMessage = nil
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.red.opacity(0.1))
            }

            // Input Area
            HStack(alignment: .bottom, spacing: 12) {
                DynamicTextEditor(text: $messageText, onSubmit: sendMessage)
                    .frame(height: calculateTextHeight())
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)

                Button(action: sendMessage) {
                    Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(messageText.isEmpty && !isGenerating ? Color.secondary : Color.blue)
                        .symbolEffect(.bounce, value: isGenerating)
                }
                .buttonStyle(.plain)
                .disabled(messageText.isEmpty && !isGenerating)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.ultraThinMaterial)
            }
        }
    }

    private func calculateTextHeight() -> CGFloat {
        if messageText.isEmpty {
            return 20
        }

        let lineCount = messageText.components(separatedBy: .newlines).count
        let lineHeight: CGFloat = 20
        let calculatedHeight = CGFloat(lineCount) * lineHeight

        return min(max(calculatedHeight, 20), 176) // Min 20, max 176 (about 8 lines)
    }

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if isGenerating {
            // Stop generation
            isGenerating = false
            return
        }

        let userMessage = Message(role: .user, content: messageText)
        conversationManager.addMessage(to: conversation, message: userMessage)

        messageText = ""
        errorMessage = nil
        isGenerating = true

        // Get updated messages after adding user message
        guard let updatedConversation = conversationManager.conversations.first(where: { $0.id == conversation.id }) else {
            return
        }
        let currentMessages = updatedConversation.messages

        // Add empty assistant message
        let assistantMessage = Message(role: .assistant, content: "")
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        openAIService.sendMessage(
            messages: currentMessages,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            onChunk: { chunk in
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                   var lastMessage = conversationManager.conversations[index].messages.last,
                   lastMessage.role == .assistant {
                    lastMessage.content += chunk
                    conversationManager.conversations[index].messages[conversationManager.conversations[index].messages.count - 1] = lastMessage
                }
            },
            onComplete: {
                isGenerating = false
                conversationManager.saveConversations()
            },
            onError: { error in
                isGenerating = false
                errorMessage = error.localizedDescription

                // Remove the empty assistant message
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    conversationManager.conversations[index].messages.removeLast()
                }
            }
        )
    }
}

// Dynamic Text Editor with auto-sizing and keyboard shortcuts
struct DynamicTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Remove default scroll view padding
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0

        // Configure scroll view
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: DynamicTextEditor
        var onSubmit: (() -> Void)?

        init(_ parent: DynamicTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle Enter (without modifiers) to send
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if event?.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty ?? true {
                    onSubmit?()
                    return true
                }
            }
            return false
        }
    }
}

#Preview {
    ChatView(conversation: Conversation())
        .environmentObject(ConversationManager())
        .frame(width: 800, height: 600)
}
