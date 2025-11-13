//
//  NotchChatView.swift
//  ayna
//
//  Created on 11/12/25.
//

import SwiftUI

class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var notchSize: CGSize
    
    private let positioningService = NotchPositioningService.shared
    private let screen: NSScreen
    
    init() {
        self.screen = NotchPositioningService.shared.getNotchScreen()
        self.notchSize = positioningService.getCollapsedNotchSize(screen: screen)
    }
    
    func toggle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded.toggle()
            notchSize = isExpanded 
                ? positioningService.getExpandedNotchSize(screen: screen)
                : positioningService.getCollapsedNotchSize(screen: screen)
        }
    }
    
    func collapse() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = false
            notchSize = positioningService.getCollapsedNotchSize(screen: screen)
        }
    }
}

struct NotchChatView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var openAIService = OpenAIService.shared
    @StateObject private var notchViewModel = NotchViewModel()
    @State private var messageText = ""
    @State private var isGenerating = false
    @FocusState private var isTextFieldFocused: Bool
    
    // Get the most recent conversation
    private var currentConversation: Conversation? {
        conversationManager.conversations.first
    }
    
    // Get last 5 messages for display
    private var recentMessages: [Message] {
        guard let conversation = currentConversation else { return [] }
        return Array(conversation.messages.filter { message in
            message.role != .system && message.role != .tool && !message.content.isEmpty
        }.suffix(5))
    }
    
    var body: some View {
        ZStack {
            if notchViewModel.isExpanded {
                expandedView
            } else {
                collapsedView
            }
        }
        .frame(width: notchViewModel.notchSize.width, height: notchViewModel.notchSize.height)
        .background(Color.black, in: RoundedRectangle(cornerRadius: notchViewModel.isExpanded ? 16 : 20))
        .overlay(
            RoundedRectangle(cornerRadius: notchViewModel.isExpanded ? 16 : 20)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
    }
    
    // MARK: - Collapsed View
    
    private var collapsedView: some View {
        Button(action: {
            notchViewModel.toggle()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                
                Text("New Chat")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Expanded View
    
    private var expandedView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(currentConversation?.title ?? "New Conversation")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                Spacer()
                
                // Model switcher
                Menu {
                    ForEach(openAIService.customModels, id: \.self) { model in
                        Button(action: {
                            if let conversation = currentConversation {
                                conversationManager.updateModel(for: conversation, model: model)
                            }
                        }) {
                            HStack {
                                Text(model)
                                if currentConversation?.model == model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentConversation?.model ?? openAIService.selectedModel)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Switch Model")
                
                // Show main window button
                Button(action: showMainWindow) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Show Main Window")
                
                // New conversation button
                Button(action: createNewConversation) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("New Conversation")
                
                // Collapse button
                Button(action: {
                    notchViewModel.collapse()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Collapse")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
                .background(.white.opacity(0.1))
            
            // Messages
            if let conversation = currentConversation, !conversation.messages.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(recentMessages) { message in
                            CompactMessageView(message: message)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 240)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "message")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                    
                    Text("Start a conversation")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: 240)
            }
            
            Divider()
                .background(.white.opacity(0.1))
            
            // Input area
            HStack(spacing: 8) {
                TextField("Message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1...3)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        sendMessage()
                    }
                    .onChange(of: isTextFieldFocused) { _, isFocused in
                        if let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow {
                            if isFocused {
                                window.enableKeyWindow()
                            } else {
                                window.disableKeyWindow()
                            }
                        }
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(messageText.isEmpty && !isGenerating ? Color.white.opacity(0.3) : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(messageText.isEmpty && !isGenerating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Actions
    
    private func createNewConversation() {
        conversationManager.createNewConversation()
        print("✅ New conversation created from notch")
    }
    
    private func showMainWindow() {
        // Use AppDelegate's method to show main window
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showMainWindow()
        } else {
            print("⚠️ AppDelegate not found")
        }
    }
    
    private func sendMessage() {
        if isGenerating {
            OpenAIService.shared.cancelCurrentRequest()
            isGenerating = false
            return
        }
        
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        // Create new conversation if none exists
        let conversation: Conversation
        if let existing = currentConversation {
            conversation = existing
        } else {
            conversationManager.createNewConversation()
            guard let newConv = conversationManager.conversations.first else { return }
            conversation = newConv
        }
        
        // Add user message
        let userMessage = Message(role: .user, content: messageText)
        conversationManager.addMessage(to: conversation, message: userMessage)
        
        messageText = ""
        isGenerating = true
        
        // Get updated conversation
        guard let updatedConversation = conversationManager.conversations.first(where: { $0.id == conversation.id }) else {
            return
        }
        
        // Add empty assistant message
        let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)
        
        // Send to API
        OpenAIService.shared.sendMessage(
            messages: updatedConversation.messages,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            tools: nil,
            conversationId: conversation.id,
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
                print("❌ Error sending message: \(error.localizedDescription)")
                
                // Remove empty assistant message
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    conversationManager.conversations[index].messages.removeLast()
                }
            }
        )
    }
}

// MARK: - Compact Message View

struct CompactMessageView: View {
    let message: Message
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar
            Image(systemName: message.role == .user ? "person.circle.fill" : "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(message.role == .user ? .blue : .purple)
                .frame(width: 20)
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "You" : ((message.model ?? "").isEmpty ? "Assistant" : (message.model ?? "")))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .lineLimit(5)
            }
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    NotchChatView()
        .environmentObject(ConversationManager())
        .frame(width: 640, height: 400)
}
