//
//  ContentView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI
import OSLog

struct ContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
  @State private var selectedConversationId: UUID?
  @State private var isCreatingNew: Bool = false

    var body: some View {
    NavigationSplitView {
      SidebarView(selectedConversationId: $selectedConversationId, isCreatingNew: $isCreatingNew)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            if let conversationId = selectedConversationId,
               let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                ChatView(conversation: conversation)
                    .id(conversationId)
      } else if isCreatingNew {
        // New conversation mode - show empty chat that creates on first message
        NewChatView(
          isCreatingNew: $isCreatingNew,
          selectedConversationId: $selectedConversationId
        )
            } else {
                // Empty state
                Color.clear
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "message")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)

                            Text("No conversation selected")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    )
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}

// View for creating a new conversation - only creates on first message
struct NewChatView: View {
  @EnvironmentObject var conversationManager: ConversationManager
  @ObservedObject private var openAIService = OpenAIService.shared
  @Binding var isCreatingNew: Bool
  @Binding var selectedConversationId: UUID?
  @State private var messageText = ""
  @State private var attachedFiles: [URL] = []
  @State private var isGenerating = false
  @State private var currentConversationId: UUID?

  // Cached font for text height calculation (computed property to avoid lazy initialization issues)
  private var textFont: NSFont { NSFont.systemFont(ofSize: 15) }
  private var textAttributes: [NSAttributedString.Key: Any] { [.font: textFont] }

  // Get the current conversation being created
  private var currentConversation: Conversation? {
    guard let id = currentConversationId else { return nil }
    return conversationManager.conversations.first(where: { $0.id == id })
  }

  // Get visible messages (filtering out system and tool messages)
  private var visibleMessages: [Message] {
    guard let conversation = currentConversation else { return [] }
    return conversation.messages.filter { message in
      guard message.role != .system && message.role != .tool else { return false }
      if message.role == .assistant && message.content.isEmpty && message.imageData == nil {
        return message.id == conversation.messages.last?.id && isGenerating
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
        // Messages or empty state
        ScrollViewReader { proxy in
          ScrollView {
            if visibleMessages.isEmpty {
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
              // Show messages
              LazyVStack(spacing: 0) {
                ForEach(visibleMessages) { message in
                  MessageView(
                    message: message,
                    modelName: message.model,
                    onRetry: nil,
                    onSwitchModel: nil
                  )
                  .id(message.id)
                }
              }
              .padding(.horizontal, 24)
              .padding(.vertical, 24)
            }
          }
          .onChange(of: visibleMessages.count) { _, _ in
            if let lastMessage = visibleMessages.last {
              withAnimation {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
              }
            }
          }
        }

        // Input Area
        VStack(spacing: 8) {
          // Attached files preview
          if !attachedFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                ForEach(attachedFiles, id: \.self) { fileURL in
                  HStack(spacing: 8) {
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
                      if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                        .fileSize {
                        Text(
                          ByteCountFormatter.string(
                            fromByteCount: Int64(fileSize), countStyle: .file)
                        )
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
                .padding(.leading, 48)
                .padding(.trailing, 12)
                .padding(.vertical, 12)
                .background(.clear)

              // Attach file button
              Button(action: attachFile) {
                Image(systemName: "plus.circle.fill")
                  .font(.system(size: 24))
                  .foregroundStyle(Color.secondary.opacity(0.7))
              }
              .buttonStyle(.plain)
              .padding(.leading, 8)
              .padding(.bottom, 8)
            }

            // Model selector
            Menu {
              ForEach(openAIService.customModels, id: \.self) { model in
                Button(action: {
                  openAIService.selectedModel = model
                }) {
                  HStack {
                    Text(model)
                    if openAIService.selectedModel == model {
                      Image(systemName: "checkmark")
                    }
                  }
                }
              }
            } label: {
              HStack(spacing: 4) {
                Divider()
                  .frame(height: 24)
                  .padding(.leading, 8)

                Text(openAIService.selectedModel)
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

            // Send button
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
                      messageText.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor
                    )
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
    let baseHeight: CGFloat = 22
    let maxHeight: CGFloat = 220

    if messageText.isEmpty {
      return baseHeight
    }

    let availableWidth: CGFloat = 600

    // Use cached font and attributes for better performance
    let boundingRect = (messageText as NSString).boundingRect(
      with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: textAttributes
    )

    let calculatedHeight = ceil(boundingRect.height) + 4
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

  private func logNewChat(
    _ message: String,
    level: OSLogType = .default,
    metadata: [String: String] = [:]
  ) {
    DiagnosticsLogger.log(.contentView, level: level, message: message, metadata: metadata)
  }

  private func sendMessage() {
    if isGenerating {
      // Stop generation immediately
      logNewChat("🛑 Stop button clicked in NewChatView, cancelling...", level: .info)
      OpenAIService.shared.cancelCurrentRequest()
      isGenerating = false
      logNewChat("✅ isGenerating set to FALSE after stop", level: .info)
      return
    }

    guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    let textToSend = messageText
    let filesToSend = attachedFiles

    // Get or create the conversation
    let conversation: Conversation
      if let existingId = currentConversationId,
        let existingConversation = conversationManager.conversations.first(where: {
          $0.id == existingId
        }) {
      // Continue with existing conversation
      conversation = existingConversation
      logNewChat(
        "📝 Continuing with existing conversation: \(existingId)",
        metadata: ["conversationId": existingId.uuidString]
      )
    } else {
      // Create a new conversation
      conversationManager.createNewConversation()
      guard let newConversation = conversationManager.conversations.first else {
        return
      }
      conversation = newConversation
      currentConversationId = newConversation.id
      logNewChat(
        "🆕 Created new conversation: \(newConversation.id)",
        level: .info,
        metadata: ["conversationId": newConversation.id.uuidString]
      )
    }

    // Build file attachments
    var attachments: [Message.FileAttachment] = []
    for fileURL in filesToSend {
      if let fileData = try? Data(contentsOf: fileURL) {
        let mimeType = getMimeType(for: fileURL)
        let attachment = Message.FileAttachment(
          fileName: fileURL.lastPathComponent,
          mimeType: mimeType,
          data: fileData
        )
        attachments.append(attachment)
      }
    }

    // Add the user message
    let userMessage = Message(
      role: .user,
      content: textToSend,
      attachments: attachments.isEmpty ? nil : attachments
    )
    conversationManager.addMessage(to: conversation, message: userMessage)

    // Clear input first
    messageText = ""
    attachedFiles.removeAll()

    // DON'T switch views yet - stay in NewChatView so the stop button remains visible
    // The view switch will happen in the completion handler after generation finishes

    // Send the message immediately (no delay needed)
    sendMessageForConversation(conversation)
  }

  private func sendMessageForConversation(_ conversation: Conversation) {
    // Get the conversation with the user message we just added
    guard
      let updatedConversation = conversationManager.conversations.first(where: {
        $0.id == conversation.id
      })
    else {
      return
    }

    isGenerating = true
    logNewChat(
      "🔄 isGenerating set to TRUE in NewChatView",
      metadata: ["conversationId": conversation.id.uuidString]
    )

    let currentMessages = updatedConversation.messages

    // Add empty assistant message with current model
    let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
    conversationManager.addMessage(to: conversation, message: assistantMessage)

    // Get available MCP tools
    let mcpManager = MCPServerManager.shared
    let enabledTools = mcpManager.getEnabledTools()
    let tools = enabledTools.isEmpty ? nil : mcpManager.getEnabledToolsAsOpenAIFunctions()

    // Send the message using the public API
    // Capture conversation ID for validation in closure
    let expectedConversationId = conversation.id
    openAIService.sendMessage(
      messages: currentMessages,
      model: updatedConversation.model,
      temperature: updatedConversation.temperature,
      tools: tools,
      conversationId: conversation.id,
      onChunk: { chunk in
        // Always update conversation data, regardless of which view is active
        guard let index = self.conversationManager.conversations.firstIndex(where: { $0.id == expectedConversationId }) else {
          logNewChat(
            "⚠️ Conversation \(expectedConversationId) no longer exists, ignoring chunk",
            level: .default,
            metadata: ["conversationId": expectedConversationId.uuidString]
          )
          return
        }

        // Update the message content
          if var lastMessage = self.conversationManager.conversations[index].messages.last,
            lastMessage.role == .assistant {
          lastMessage.content += chunk
          self.conversationManager.conversations[index].messages[
            self.conversationManager.conversations[index].messages.count - 1] = lastMessage
        }
      },
      onComplete: {
        self.isGenerating = false
        logNewChat(
          "✅ Message sent successfully, isGenerating set to FALSE",
          level: .info,
          metadata: ["conversationId": conversation.id.uuidString]
        )

        // Now that generation is complete, switch to ChatView
        self.selectedConversationId = conversation.id
        self.isCreatingNew = false
      },
      onError: { error in
        self.isGenerating = false
        logNewChat(
          "❌ Error sending message: \(error.localizedDescription)",
          level: .error,
          metadata: [
            "conversationId": conversation.id.uuidString,
            "error": error.localizedDescription
          ]
        )

        // On error, also switch to ChatView so user can see the error
        self.selectedConversationId = conversation.id
        self.isCreatingNew = false
      }
    )
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
}

#Preview {
    ContentView()
        .environmentObject(ConversationManager())
}
