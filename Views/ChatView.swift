//
//  ChatView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI
import OSLog

// ChatView currently wraps the full chat experience (history, composer, attachments, streaming, MCP
// tooling). Splitting it without a broader refactor would scatter tightly coupled state, so we allow
// the larger body here until the view hierarchy is modularized.
// swiftlint:disable:next type_body_length
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

  // Performance optimizations
  @State private var scrollDebounceTask: Task<Void, Never>?
  @State private var isNearBottom = true
  @State private var pendingChunks: [String] = []
  @State private var batchUpdateTask: Task<Void, Never>?
  @State private var visibleMessages: [Message] = []
  @State private var cachedConversationIndex: Int?

  // Cached font for text height calculation (computed property to avoid lazy initialization issues)
  private var textFont: NSFont { NSFont.systemFont(ofSize: 15) }
  private var textAttributes: [NSAttributedString.Key: Any] { [.font: textFont] }

  // Cache the current conversation to avoid repeated lookups
    private var currentConversation: Conversation {
        conversationManager.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

  // Helper to get conversation index with caching
    private func getConversationIndex() -> Int? {
    if let cached = cachedConversationIndex,
      cached < conversationManager.conversations.count,
      conversationManager.conversations[cached].id == conversation.id {
      return cached
    }
    let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id })
    cachedConversationIndex = index
    return index
  }

    private func logChat(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        var combinedMetadata = metadata
        if combinedMetadata["conversationId"] == nil {
            combinedMetadata["conversationId"] = conversation.id.uuidString
        }
        DiagnosticsLogger.log(.chatView, level: level, message: message, metadata: combinedMetadata)
    }

  // Helper to filter visible messages
    private func updateVisibleMessages() {
        visibleMessages = currentConversation.messages.filter { message in
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

  private var configurationIssues: [String] {
    openAIService.configurationIssues
  }

  private var shouldShowPrompts: Bool {
    configurationIssues.isEmpty
  }

  private func handlePromptSelection(_ prompt: String) {
    messageText = prompt
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
              ChatEmptyStateCard(
                configurationIssues: configurationIssues,
                providerName: openAIService.provider.displayName,
                prompts: OnboardingContent.quickPrompts,
                showPrompts: shouldShowPrompts,
                onInsertPrompt: handlePromptSelection
              )
                        .frame(maxWidth: .infinity)
              .padding(.horizontal, 32)
              .padding(.top, 60)
              .padding(.bottom, 80)
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
                    // Debounce scroll updates during streaming for better performance
                    scrollDebounceTask?.cancel()
                    scrollDebounceTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(isGenerating ? 150 : 0))
                        guard !Task.isCancelled, isNearBottom else { return }
                        if let lastMessage = currentConversation.messages.last {
                            if isGenerating {
                                // No animation during streaming for better performance
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            } else {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .onAppear {
                    // Update visible messages and scroll to bottom
                    updateVisibleMessages()
                    if let lastMessage = currentConversation.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.id) { _, _ in
                    // Update visible messages when switching conversations
                    updateVisibleMessages()
                    if let lastMessage = currentConversation.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: currentConversation.messages) { _, _ in
                    // Update visible messages when messages change
                    updateVisibleMessages()
                }
                .onChange(of: isGenerating) { _, _ in
                    // Update visible messages when generation state changes (affects empty assistant message visibility)
                    updateVisibleMessages()
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

          HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
              DynamicTextEditor(text: $messageText, onSubmit: sendMessage)
                .frame(height: calculateTextHeight())
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(.leading, 48)  // Extra padding on left for attach button
                .padding(.trailing, 12)  // Reduced padding on right
                .padding(.vertical, 12)
                .background(.clear)

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

            // Model selector (seamlessly integrated)
            Menu {
              if openAIService.customModels.isEmpty {
                SettingsLink {
                  Label("Add Model in Settings", systemImage: "slider.horizontal.3")
                }
                .routeSettings(to: .models)
              } else {
                ForEach(openAIService.customModels, id: \.self) { model in
                  Button(action: {
                    conversationManager.updateModel(for: conversation, model: model)
                  }) {
                    HStack {
                      Text(model)
                      if currentConversation.model == model {
                        Image(systemName: "checkmark")
                      }
                    }
                  }
                }
              }
            } label: {
              HStack(spacing: 4) {
                Divider()
                  .frame(height: 24)
                  .padding(.leading, 8)

                Text(
                  currentConversation.model.isEmpty
                    ? (openAIService.customModels.isEmpty ? "Add Model" : "Select Model")
                    : currentConversation.model
                )
                  .font(.system(size: 13))
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
              }
              .padding(.horizontal, 12)
              .frame(height: calculateTextHeight() + 24)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()

            // Send button on the rightmost side
            Button(action: sendMessage) {
              ZStack {
                if isGenerating {
                  Image(systemName: "stop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, value: isGenerating)
                } else {
                  Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(
                      messageText.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
                }
              }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(isGenerating || !messageText.isEmpty)
            .padding(.horizontal, 12)
            .frame(height: calculateTextHeight() + 24)
          }
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
          )
          .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
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

    // Use cached font and attributes for better performance
        let boundingRect = (messageText as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: textAttributes
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

    // This method coordinates attachment handling, MCP tool availability, streaming setup, and state
    // resets. Breaking it apart right now would require plumbing a large amount of shared state, so
    // we defer that refactor and explicitly allow the longer body.
    // swiftlint:disable:next function_body_length
    private func sendMessage() {
    if isGenerating {
      // Stop generation immediately
            logChat("🛑 Stop button clicked, cancelling...", level: .info)
      OpenAIService.shared.cancelCurrentRequest()

      // Flush any pending chunks before stopping
      batchUpdateTask?.cancel()
      if !pendingChunks.isEmpty {
        let remainingChunks = pendingChunks.joined()
        pendingChunks.removeAll()

          if let index = conversationManager.conversations.firstIndex(where: {
            $0.id == conversation.id
          }),
            var lastMessage = conversationManager.conversations[index].messages.last,
            lastMessage.role == .assistant {
          lastMessage.content += remainingChunks
          conversationManager.conversations[index].messages[
            conversationManager.conversations[index].messages.count - 1] = lastMessage
                    logChat(
                        "💾 Flushed \(remainingChunks.count) chars before cancellation",
                        level: .info,
                        metadata: ["chunkLength": "\(remainingChunks.count)"]
                    )
        }
      }

      // Save conversations immediately to persist partial message
      conversationManager.saveConversationsImmediately()
            logChat("💾 Saved conversation after cancellation", level: .info)

      isGenerating = false
      currentToolName = nil
      toolCallDepth = 0
            logChat("✅ isGenerating set to FALSE after stop", level: .info)
            return
    }

    guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
                logChat(
                    "📎 Attached file: \(fileURL.lastPathComponent) (\(mimeType), \(fileData.count) bytes)",
                    level: .info,
                    metadata: [
                        "fileName": fileURL.lastPathComponent,
                        "mimeType": mimeType,
                        "fileSize": "\(fileData.count)"
                    ]
                )
      }
    }

    let userMessage = Message(
      role: .user,
      content: messageText,
      attachments: attachments.isEmpty ? nil : attachments
    )
        logChat(
            "📨 Creating message with \(attachments.count) attachments",
            level: .info,
            metadata: ["attachmentCount": "\(attachments.count)"]
        )
        conversationManager.addMessage(to: conversation, message: userMessage)

        let promptText = messageText
        messageText = ""
    attachedFiles = []  // Clear attached files after sending
    errorMessage = nil
    isGenerating = true
    logChat("🔄 isGenerating set to TRUE", level: .info)

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

                logChat(
                    "📊 Total available tools in manager: \(mcpManager.availableTools.count)",
                    metadata: ["availableTools": "\(mcpManager.availableTools.count)"]
                )
                logChat(
                    "📊 Enabled server configs: \(mcpManager.serverConfigs.filter { $0.enabled }.map { $0.name })",
                    metadata: ["enabledServers": mcpManager.serverConfigs
                        .filter { $0.enabled }
                        .map { $0.name }
                        .joined(separator: ",")
      ]
    )

    let enabledTools = mcpManager.getEnabledTools()

        // If we have enabled servers but no tools yet, wait a moment and try again
        // This handles the race condition where servers are connecting at app startup
        if enabledTools.isEmpty {
            let hasEnabledServers = !mcpManager.serverConfigs.filter({ $0.enabled }).isEmpty
            if hasEnabledServers {
                logChat("⏳ Enabled servers found but no tools yet, waiting for discovery...", level: .info)
                // Give discovery a moment to complete (non-blocking)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Re-query after a brief delay
                    let updatedTools = mcpManager.getEnabledTools()
                                        logChat(
                                            "⏳ After delay: \(updatedTools.count) tools available",
                                            level: .info,
                                            metadata: ["availableTools": "\(updatedTools.count)"]
                                        )
                }
            }
        }

        // Use cached OpenAI function format for better performance
        let tools = enabledTools.isEmpty ? nil : MCPServerManager.shared.getEnabledToolsAsOpenAIFunctions()

        if !enabledTools.isEmpty {
            logChat(
              "🔧 Available MCP tools: \(enabledTools.map { $0.name }.joined(separator: ", "))",
              level: .info,
              metadata: ["tools": enabledTools.map { $0.name }.joined(separator: ", ")]
            )
        } else {
            logChat("⚠️ No MCP tools available. Enable servers in Settings → MCP Tools", level: .info)
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
    // swiftlint:disable:next function_body_length
    private func sendMessageWithToolSupport(
        messages: [Message],
        model: String,
        temperature: Double,
        tools: [[String: Any]]?,
        isInitialRequest: Bool
    ) {
    let maxToolCallDepth = 10  // Prevent infinite loops
    let mcpManager = MCPServerManager.shared

    // Cache the conversation index to avoid repeated lookups in onChunk
    let conversationIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id })

        openAIService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
            conversationId: conversation.id,
            onChunk: { chunk in
                // Batch chunks for better performance during streaming
                pendingChunks.append(chunk)

                // Cancel existing batch task and create new one
                batchUpdateTask?.cancel()
                batchUpdateTask = Task { @MainActor in
                    // Wait for batch window (50ms for smoother updates)
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { return }

                    // Process all pending chunks at once
                    let chunksToProcess = pendingChunks
                    pendingChunks.removeAll()

                    guard !chunksToProcess.isEmpty else { return }

                    let combinedChunk = chunksToProcess.joined()

          // Always update the conversation data, but only update UI state if we're viewing this conversation
          guard let index = getConversationIndex() else {
                                                logChat(
                                                    "⚠️ Conversation \(conversation.id) no longer exists, ignoring chunk",
                                                    level: .info
                                                )
                        return
                    }

                    // Update the message content regardless of which conversation is active
                    var lastMessage = conversationManager.conversations[index].messages.last
                    if lastMessage?.role == .assistant {
                        lastMessage?.content += combinedChunk
                        conversationManager.conversations[index].messages[conversationManager.conversations[index].messages.count - 1] = lastMessage!
                    }

                    // Only update UI state if we're currently viewing this conversation
                    if index == conversationIndex {
                        // Clear tool execution indicator when we start receiving actual content
                        if currentToolName != nil {
                            currentToolName = nil
                        }
                    }
                }
            },
            onComplete: {
                // Flush any pending chunks immediately
                batchUpdateTask?.cancel()
                if !pendingChunks.isEmpty {
                    let remainingChunks = pendingChunks.joined()
                    pendingChunks.removeAll()

                    if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                       var lastMessage = conversationManager.conversations[index].messages.last,
                       lastMessage.role == .assistant {
                        lastMessage.content += remainingChunks
                        conversationManager.conversations[index].messages[conversationManager.conversations[index].messages.count - 1] = lastMessage
                    }
                }

                // Always save conversations
        conversationManager.saveConversations()

                // Only update UI state if we're viewing this conversation
                guard let currentIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                      currentIndex == conversationIndex else {
                                        logChat(
                                            "✅ onComplete for conversation \(conversation.id) (background)",
                                            level: .info
                                        )
                    return
                }

                // Only clear state if no tool call is pending
                // If currentToolName is set, a tool call was requested and will execute
                // The tool execution will manage the state from there
                if currentToolName == nil {
                                        logChat("✅ onComplete: isGenerating set to FALSE (no tool calls pending)", level: .info)
                    isGenerating = false
                } else {
                                        logChat(
                                            "⏳ onComplete: Keeping isGenerating TRUE (tool call pending: \(currentToolName ?? "unknown"))",
                                            level: .info,
                                            metadata: ["toolName": currentToolName ?? "unknown"]
                                        )
                }
            },
            onError: { error in
                // Clean up batching
                batchUpdateTask?.cancel()
                pendingChunks.removeAll()

                // Always remove the empty assistant message
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    conversationManager.conversations[index].messages.removeLast()
                }

                // Only update UI state if we're viewing this conversation
                guard let currentIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                      currentIndex == conversationIndex else {
                                        logChat(
                                            "❌ onError for conversation \(conversation.id) (background): \(error.localizedDescription)",
                                            level: .error,
                                            metadata: ["error": error.localizedDescription]
                                        )
                    return
                }

                isGenerating = false
                currentToolName = nil
                toolCallDepth = 0
                errorMessage = error.localizedDescription
            },
            onToolCallRequested: { toolCallId, toolName, arguments in
                // Validate conversation still exists
                guard conversationManager.conversations.contains(where: { $0.id == conversation.id }) else {
                                        logChat(
                                            "⚠️ Tool call requested for conversation \(conversation.id) but conversation no longer exists, ignoring",
                                            level: .default
                                        )
                    return
                }

                // Tool call was requested by the LLM
                                logChat(
                                    "🔧 Tool call requested: \(toolName) for conversation \(conversation.id)",
                                    level: .info,
                                    metadata: ["toolName": toolName]
                                )

                // Only update UI state if we're currently viewing this conversation
                if let currentIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                   currentIndex == conversationIndex {
                    currentToolName = toolName
                }

                // Check depth limit
                guard toolCallDepth < maxToolCallDepth else {
                    logChat("⚠️ Max tool call depth reached, stopping", level: .error)
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
                                                logChat(
                                                    "⚙️ Executing tool: \(toolName)",
                                                    level: .info,
                                                    metadata: ["toolName": toolName]
                                                )
                        let result = try await mcpManager.executeTool(name: toolName, arguments: arguments)
                                                logChat(
                                                    "✅ Tool result received (\(result.count) chars)",
                                                    level: .info,
                                                    metadata: ["resultLength": "\(result.count)"]
                                                )

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
                                // Only update UI if viewing this conversation
                                if let currentIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                                   currentIndex == conversationIndex {
                                    isGenerating = false
                                    currentToolName = nil
                                }
                                return
                            }

                            // Add new empty assistant message for LLM response
                            let newAssistantMessage = Message(role: .assistant, content: "", model: model)
                            conversationManager.addMessage(to: conversation, message: newAssistantMessage)

              logChat("🔄 Sending follow-up request with tool results...", level: .info)

                            // Only update UI state if viewing this conversation
                            if let currentIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                               currentIndex == conversationIndex {
                                currentToolName = "Analyzing \(toolName) results"
                            }

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
                            logChat(
                                "❌ Tool execution error: \(error.localizedDescription)",
                                level: .error,
                                metadata: ["error": error.localizedDescription]
                            )

                            // Only update UI state if viewing this conversation
                            if let currentIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                               currentIndex == conversationIndex {
                                isGenerating = false
                                currentToolName = nil
                                errorMessage = "Tool execution failed: \(error.localizedDescription)"
                            }
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

struct ChatEmptyStateCard: View {
  let configurationIssues: [String]
  let providerName: String
  let prompts: [String]
  let showPrompts: Bool
  let onInsertPrompt: (String) -> Void

  private let documentationURL = URL(string: "https://github.com/sozercan/ayna#readme")!

  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 8) {
        Image(systemName: showPrompts ? "sparkles" : "key.fill")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(.secondary)

        Text(showPrompts ? "Start your first conversation" : "You're almost ready")
          .font(.title3.weight(.semibold))

        Text(
          showPrompts
            ? "Share a prompt below or paste content you'd like me to analyze."
            : "Complete the setup steps so Ayna can connect to \(providerName)."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }

      if configurationIssues.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text("Try one of these quick prompts")
            .font(.subheadline.weight(.medium))

          VStack(alignment: .leading, spacing: 8) {
            ForEach(prompts, id: \.self) { prompt in
              Button(action: { onInsertPrompt(prompt) }) {
                HStack {
                  Image(systemName: "text.quote")
                    .font(.system(size: 13, weight: .semibold))
                  Text(prompt)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(configurationIssues, id: \.self) { issue in
            Label(issue, systemImage: "exclamationmark.triangle")
              .font(.callout)
              .foregroundStyle(.orange)
          }

          SettingsLink {
            HStack {
              Image(systemName: "slider.horizontal.3")
              Text("Open Settings")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .routeSettings(to: .models)

          Text("Tip: Press ⌘, anytime to open Settings.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Link(destination: documentationURL) {
        Label("Read the quickstart guide", systemImage: "book")
          .font(.footnote)
      }
      .foregroundStyle(.secondary)
    }
    .padding(32)
    .frame(maxWidth: 520)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(Color.white.opacity(0.05))
    )
  }
}

enum OnboardingContent {
  static let quickPrompts: [String] = [
    "Summarize today's meeting notes into three bullet points.",
    "Explain this SwiftUI snippet and suggest improvements.",
    "Help me brainstorm launch ideas for our next release."
    ]
}

#Preview {
    ChatView(conversation: Conversation())
        .environmentObject(ConversationManager())
        .frame(width: 800, height: 600)
}
