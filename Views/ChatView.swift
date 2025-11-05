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

    // Get the current conversation from the manager to ensure we have the latest data
    private var currentConversation: Conversation {
        conversationManager.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

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
                    if currentConversation.messages.isEmpty {
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
                            ForEach(currentConversation.messages.filter { message in
                                // Hide system messages
                                guard message.role != .system else { return false }

                                // Show if: has content, has image data, is generating image, or is empty assistant (shows typing indicator)
                                return !message.content.isEmpty ||
                                       message.imageData != nil ||
                                       message.mediaType == .image ||
                                       message.role == .assistant
                            }) { message in
                                MessageView(message: message, modelName: message.model)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                    }
                }
                .onChange(of: currentConversation.messages.count) { _, _ in
                    if let lastMessage = currentConversation.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Start at bottom when conversation is first loaded
                    if let lastMessage = currentConversation.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.id) { _, _ in
                    // Start at bottom when switching conversations
                    if let lastMessage = currentConversation.messages.last {
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

        let promptText = messageText
        messageText = ""
        errorMessage = nil
        isGenerating = true

        // Get updated messages after adding user message
        guard let updatedConversation = conversationManager.conversations.first(where: { $0.id == conversation.id }) else {
            return
        }

        // Check if current model is for image generation
        let modelCapability = openAIService.getModelCapability(updatedConversation.model)

        if modelCapability == .imageGeneration {
            // Image generation flow
            generateImage(prompt: promptText, model: updatedConversation.model)
            return
        }

        let currentMessages = updatedConversation.messages

        // Add empty assistant message with current model
        let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available MCP tools
        let mcpManager = MCPServerManager.shared
        let enabledTools = mcpManager.getEnabledTools()
        let tools = enabledTools.isEmpty ? nil : enabledTools.map { $0.toOpenAIFunction() }

        if !enabledTools.isEmpty {
            print("🔧 Available MCP tools: \(enabledTools.map { $0.name }.joined(separator: ", "))")
        } else {
            print("⚠️ No MCP tools available. Enable servers in Settings → MCP Tools")
        }

        openAIService.sendMessage(
            messages: currentMessages,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            tools: tools,
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
            },
            onToolCall: { callId, toolName, arguments in
                // Execute the MCP tool
                do {
                    let result = try await mcpManager.executeTool(name: toolName, arguments: arguments)
                    return result
                } catch {
                    return "Error executing tool: \(error.localizedDescription)"
                }
            }
        )
    }

    private func generateImage(prompt: String, model: String) {
        // Create placeholder assistant message with a known ID
        let messageId = UUID()
        let placeholderMessage = Message(
            id: messageId,
            role: .assistant,
            content: "Generating image...",
            model: model,
            mediaType: .image
        )
        conversationManager.addMessage(to: conversation, message: placeholderMessage)

        openAIService.generateImage(
            prompt: prompt,
            model: model,
            onComplete: { imageData in
                // Update the placeholder message with actual image using the proper method
                conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                    message.content = ""
                    message.imageData = imageData
                }

                isGenerating = false
            },
            onError: { error in
                isGenerating = false
                errorMessage = error.localizedDescription

                // Remove the placeholder message
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
