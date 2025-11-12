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
  @ObservedObject private var openAIService = OpenAIService.shared

    @State private var messageText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
  @State private var attachedFiles: [URL] = []
  @State private var toolCallDepth = 0
  @State private var currentToolName: String?

  // Cache the current conversation to avoid repeated lookups
    private var currentConversation: Conversation {
        conversationManager.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

  // Pre-filter messages once for the view body
  private var visibleMessages: [Message] {
    currentConversation.messages.filter { message in
      // Hide system and tool messages (tool messages are internal only)
      guard message.role != .system && message.role != .tool else { return false }

      // Show if: has content, has image data, or is generating image
      // Don't show empty assistant messages unless we're actively generating
      if message.role == .assistant && message.content.isEmpty && message.imageData == nil {
        // Only show empty assistant message if it's the last message and we're generating
        return message.id == currentConversation.messages.last?.id && isGenerating
      }

      return !message.content.isEmpty || message.imageData != nil || message.mediaType == .image
    }
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
                ForEach(visibleMessages) { message in
                                MessageView(
                    message: message,
                                    modelName: message.model,
                                    onRetry: message.role == .assistant ? {
                                        retryLastMessage(beforeMessage: message)
                                    } : nil,
                                    onSwitchModel: message.role == .assistant ? { newModel in
                                        switchModelAndRetry(beforeMessage: message, newModel: newModel)
                                    } : nil
                                )
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

            // Tool execution status indicator
            if let toolName = currentToolName {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                    Text(toolName.hasPrefix("Analyzing") ? "🔄 \(toolName)..." : "🔧 Using tool: \(toolName)...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
            }

            // Input Area
        VStack(spacing: 8) {
          // Attached files preview
          if !attachedFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                ForEach(attachedFiles, id: \.self) { fileURL in
                  HStack(spacing: 8) {
                    // Show image thumbnail if it's an image file
                    if let image = NSImage(contentsOf: fileURL) {
                      Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                      Image(systemName: "doc.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                      Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                      if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                    }

                    Button(action: { removeFile(fileURL) }) {
                      Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                  }
                  .padding(8)
                  .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
              }
              .padding(.horizontal, 24)
            }
          }

          ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomLeading) {
              DynamicTextEditor(text: $messageText, onSubmit: sendMessage)
                .frame(height: calculateTextHeight())
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(.leading, 48)  // Extra padding on left for attach button
                .padding(.trailing, 48)  // Extra padding on right for send button
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                  RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)

              // Attach file button inside the text box (left side)
              Button(action: attachFile) {
                Image(systemName: "plus.circle.fill")
                  .font(.system(size: 24))
                  .foregroundStyle(Color.secondary.opacity(0.7))
              }
              .buttonStyle(.plain)
              .padding(.leading, 8)
              .padding(.bottom, 8)
            }

            // Send button inside the text box (right side)
            Button(action: sendMessage) {
              Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(
                  messageText.isEmpty && !isGenerating
                    ? Color.secondary.opacity(0.5) : Color.accentColor
                )
                .symbolEffect(.bounce, value: isGenerating)
            }
            .buttonStyle(.plain)
            .disabled(messageText.isEmpty && !isGenerating)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
          }
          .padding(.horizontal, 24)
        }
            .padding(.vertical, 20)
            .background(.ultraThinMaterial)
            }
        }
    }

    private func calculateTextHeight() -> CGFloat {
        let baseHeight: CGFloat = 22 // Single line height
        let maxHeight: CGFloat = 220 // Max height (about 10 lines)

        if messageText.isEmpty {
            return baseHeight
        }

        // Calculate the width available for text (accounting for padding and button)
        // Approximate available width in the text view
        let availableWidth: CGFloat = 600 // Approximate - will be constrained by actual view width

        let font = NSFont.systemFont(ofSize: 15)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        let boundingRect = (messageText as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )

        let calculatedHeight = ceil(boundingRect.height) + 4 // Add small padding

        // Clamp between min and max heights
        return min(max(calculatedHeight, baseHeight), maxHeight)
    }

  private func attachFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.message = "Select files to attach"

    panel.begin { response in
      if response == .OK {
        attachedFiles.append(contentsOf: panel.urls)
      }
    }
  }

  private func removeFile(_ fileURL: URL) {
    attachedFiles.removeAll { $0 == fileURL }
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
    case "txt":
      return "text/plain"
    case "json":
      return "application/json"
    case "xml":
      return "application/xml"
    default:
      return "application/octet-stream"
    }
  }

  private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if isGenerating {
            // Stop generation
            OpenAIService.shared.cancelCurrentRequest()
            isGenerating = false
            return
        }

    // Build file attachments
    var attachments: [Message.FileAttachment] = []
    for fileURL in attachedFiles {
      if let fileData = try? Data(contentsOf: fileURL) {
        let mimeType = getMimeType(for: fileURL)
        let attachment = Message.FileAttachment(
          fileName: fileURL.lastPathComponent,
          mimeType: mimeType,
          data: fileData
        )
        attachments.append(attachment)
        print(
          "📎 Attached file: \(fileURL.lastPathComponent) (\(mimeType), \(fileData.count) bytes)")
      }
    }

    let userMessage = Message(
      role: .user,
      content: messageText,
      attachments: attachments.isEmpty ? nil : attachments
    )
    print("📨 Creating message with \(attachments.count) attachments")
        conversationManager.addMessage(to: conversation, message: userMessage)

        let promptText = messageText
        messageText = ""
    attachedFiles = []  // Clear attached files after sending
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

        print("📊 Total available tools in manager: \(mcpManager.availableTools.count)")
        print("📊 Enabled server configs: \(mcpManager.serverConfigs.filter { $0.enabled }.map { $0.name })")

        var enabledTools = mcpManager.getEnabledTools()

        // If we have enabled servers but no tools yet, wait a moment and try again
        // This handles the race condition where servers are connecting at app startup
        if enabledTools.isEmpty {
            let hasEnabledServers = !mcpManager.serverConfigs.filter({ $0.enabled }).isEmpty
            if hasEnabledServers {
                print("⏳ Enabled servers found but no tools yet, waiting for discovery...")
                // Give discovery a moment to complete (non-blocking)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Re-query after a brief delay
                    let updatedTools = mcpManager.getEnabledTools()
                    print("� After delay: \(updatedTools.count) tools available")
                }
            }
        }

        // Use cached OpenAI function format for better performance
        let tools = enabledTools.isEmpty ? nil : MCPServerManager.shared.getEnabledToolsAsOpenAIFunctions()

        if !enabledTools.isEmpty {
            print("🔧 Available MCP tools: \(enabledTools.map { $0.name }.joined(separator: ", "))")
        } else {
            print("⚠️ No MCP tools available. Enable servers in Settings → MCP Tools")
        }

        // Reset tool call depth for new user messages
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: currentMessages,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }

    private func generateImage(prompt: String, model: String) {
        // Create placeholder assistant message with a known ID
        let messageId = UUID()
        let placeholderMessage = Message(
            id: messageId,
            role: .assistant,
            content: "",
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

    // Helper function to send messages with automatic tool call handling
    private func sendMessageWithToolSupport(
        messages: [Message],
        model: String,
        temperature: Double,
        tools: [[String: Any]]?,
    isInitialRequest: Bool
  ) {
    let maxToolCallDepth = 10  // Prevent infinite loops
    let mcpManager = MCPServerManager.shared

        openAIService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
            conversationId: conversation.id,
            onChunk: { chunk in
                // Clear tool execution indicator when we start receiving actual content
                if currentToolName != nil {
                    currentToolName = nil
                }

                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                   var lastMessage = conversationManager.conversations[index].messages.last,
                   lastMessage.role == .assistant {
                    lastMessage.content += chunk
                    conversationManager.conversations[index].messages[conversationManager.conversations[index].messages.count - 1] = lastMessage
                }
            },
            onComplete: {
                // Only clear state if no tool call is pending
                // (if currentToolName is set, a tool call handler will manage the state)
                if currentToolName == nil {
                    isGenerating = false
                }
                conversationManager.saveConversations()
            },
            onError: { error in
                isGenerating = false
                currentToolName = nil
                toolCallDepth = 0
                errorMessage = error.localizedDescription

                // Remove the empty assistant message
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    conversationManager.conversations[index].messages.removeLast()
                }
            },
            onToolCallRequested: { toolCallId, toolName, arguments in
                // Tool call was requested by the LLM
                print("🔧 Tool call requested: \(toolName)")
        currentToolName = toolName

                // Check depth limit
                guard toolCallDepth < maxToolCallDepth else {
                    print("⚠️ Max tool call depth reached, stopping")
                    isGenerating = false
                    currentToolName = nil
                    return
                }

                toolCallDepth += 1

                // Store the tool call in the last assistant message
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                   var lastMessage = conversationManager.conversations[index].messages.last,
          lastMessage.role == .assistant {

                    // Convert arguments to AnyCodable
                    let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                        result[pair.key] = AnyCodable(pair.value)
                    }

                    let toolCall = MCPToolCall(
                        id: toolCallId,
                        toolName: toolName,
                        arguments: anyCodableArgs
                    )
                    lastMessage.toolCalls = [toolCall]
                    conversationManager.conversations[index].messages[conversationManager.conversations[index].messages.count - 1] = lastMessage
                    conversationManager.saveConversations()
                }

                // Execute the tool asynchronously
                Task {
                    do {
                        print("⚙️ Executing tool: \(toolName)")
                        let result = try await mcpManager.executeTool(name: toolName, arguments: arguments)
                        print("✅ Tool result received (\(result.count) chars)")

                        // Create a tool message with the result
                        await MainActor.run {
                            let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                                result[pair.key] = AnyCodable(pair.value)
                            }

                            var toolMessage = Message(
                                role: .tool,
                                content: result
                            )
                            toolMessage.toolCalls = [MCPToolCall(
                                id: toolCallId,
                                toolName: toolName,
                                arguments: anyCodableArgs,
                                result: result
                            )]
                            conversationManager.addMessage(to: conversation, message: toolMessage)

                            // Get updated conversation with tool result
                            guard let updatedConv = conversationManager.conversations.first(where: { $0.id == conversation.id }) else {
                                isGenerating = false
                                currentToolName = nil
                return
                            }

                            // Add new empty assistant message for LLM response
                            let newAssistantMessage = Message(role: .assistant, content: "", model: model)
                            conversationManager.addMessage(to: conversation, message: newAssistantMessage)

                            print("🔄 Sending follow-up request with tool results...")
              currentToolName = "Analyzing \(toolName) results"

                            // Automatically continue the conversation with tool results
                            sendMessageWithToolSupport(
                                messages: updatedConv.messages,
                                model: model,
                                temperature: temperature,
                                tools: tools,
                                isInitialRequest: false
                            )
                        }
                    } catch {
                        await MainActor.run {
                            print("❌ Tool execution error: \(error.localizedDescription)")
                            isGenerating = false
                            currentToolName = nil
                            errorMessage = "Tool execution failed: \(error.localizedDescription)"
                        }
                    }
                }
            },
            onReasoning: { reasoning in
                // Append reasoning content to the last assistant message
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                   var lastMessage = conversationManager.conversations[index].messages.last,
                   lastMessage.role == .assistant {
                    let currentReasoning = lastMessage.reasoning ?? ""
                    lastMessage.reasoning = currentReasoning + reasoning
                    conversationManager.conversations[index].messages[conversationManager.conversations[index].messages.count - 1] = lastMessage
                }
            }
        )
    }

    // Retry the message that came before the specified assistant message
    private func retryLastMessage(beforeMessage: Message) {
        guard !isGenerating else { return }

        // Find the user message that came before this assistant message
        guard let assistantIndex = currentConversation.messages.firstIndex(where: { $0.id == beforeMessage.id }),
              assistantIndex > 0 else {
      return
        }

        // Find the last user message before this assistant message
        var userMessageIndex: Int?
        for index in (0..<assistantIndex).reversed() where currentConversation.messages[index].role == .user {
            userMessageIndex = index
            break
        }

        guard let userIndex = userMessageIndex else { return }
        let userMessage = currentConversation.messages[userIndex]

        // Remove all messages from the assistant message onwards
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversationManager.conversations[convIndex].messages.removeSubrange(assistantIndex...)
            conversationManager.saveConversations()
        }

        // Resend the user message
        resendMessage(userMessage)
    }

    // Switch model and retry
    private func switchModelAndRetry(beforeMessage: Message, newModel: String) {
        // Don't update the global conversation model or selected model
        // Just retry with the specified model for this message only
        retryWithModel(beforeMessage: beforeMessage, model: newModel)
    }

    // Retry with a specific model (without changing conversation's default model)
    private func retryWithModel(beforeMessage: Message, model: String) {
        guard !isGenerating else { return }

        // Find the user message that came before this assistant message
        guard let assistantIndex = currentConversation.messages.firstIndex(where: { $0.id == beforeMessage.id }),
              assistantIndex > 0 else {
            return
        }

        // Find the last user message before this assistant message
        var userMessageIndex: Int?
        for index in (0..<assistantIndex).reversed() where currentConversation.messages[index].role == .user {
            userMessageIndex = index
            break
        }

        guard let userIndex = userMessageIndex else { return }
        let userMessage = currentConversation.messages[userIndex]

        // Remove all messages from the assistant message onwards
        if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversationManager.conversations[convIndex].messages.removeSubrange(assistantIndex...)
            conversationManager.saveConversations()
        }

        // Resend the user message with the specified model
        resendMessageWithModel(userMessage, model: model)
    }

    // Resend a message
    private func resendMessage(_ message: Message) {
        errorMessage = nil
    isGenerating = true

        // Get updated messages
        guard let updatedConversation = conversationManager.conversations.first(where: { $0.id == conversation.id }) else {
      return
        }

        // Check if current model is for image generation
        let modelCapability = openAIService.getModelCapability(updatedConversation.model)

        if modelCapability == .imageGeneration {
            // Image generation flow
            generateImage(prompt: message.content, model: updatedConversation.model)
      return
        }

        let currentMessages = updatedConversation.messages

        // Add empty assistant message with current model
        let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available MCP tools (using cached OpenAI format for performance)
        let mcpManager = MCPServerManager.shared
        let enabledTools = mcpManager.getEnabledTools()
        let tools = enabledTools.isEmpty ? nil : mcpManager.getEnabledToolsAsOpenAIFunctions()

    // Reset tool call depth
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: currentMessages,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }

    // Resend a message with a specific model (without changing conversation's default model)
    private func resendMessageWithModel(_ message: Message, model: String) {
        errorMessage = nil
        isGenerating = true

        // Get updated messages
        guard let updatedConversation = conversationManager.conversations.first(where: { $0.id == conversation.id }) else {
            return
        }

        // Check if specified model is for image generation
        let modelCapability = openAIService.getModelCapability(model)

        if modelCapability == .imageGeneration {
            // Image generation flow
            generateImage(prompt: message.content, model: model)
            return
        }

        let currentMessages = updatedConversation.messages

        // Add empty assistant message with the specified model
        let assistantMessage = Message(role: .assistant, content: "", model: model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available MCP tools (using cached OpenAI format for performance)
        let mcpManager = MCPServerManager.shared
        let enabledTools = mcpManager.getEnabledTools()
        let tools = enabledTools.isEmpty ? nil : mcpManager.getEnabledToolsAsOpenAIFunctions()

    // Reset tool call depth
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: currentMessages,
            model: model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }
}

// Dynamic Text Editor with auto-sizing and keyboard shortcuts
struct DynamicTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

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
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

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
                if event?.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control]) ?? true {
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
