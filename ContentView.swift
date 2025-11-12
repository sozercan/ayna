//
//  ContentView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

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

  var body: some View {
    ZStack {
      // Chat background with subtle gradient
      LinearGradient(
        colors: [
          Color(nsColor: .windowBackgroundColor),
          Color(nsColor: .windowBackgroundColor).opacity(0.95),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 0) {
        // Empty state
        ScrollView {
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
                        .fileSize
                      {
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
              Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(
                  messageText.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor
                )
            }
            .buttonStyle(.plain)
            .disabled(messageText.isEmpty)
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
    let font = NSFont.systemFont(ofSize: 15)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]

    let boundingRect = (messageText as NSString).boundingRect(
      with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes
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

  private func sendMessage() {
    guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    let textToSend = messageText
    let filesToSend = attachedFiles

    // Create the conversation now
    conversationManager.createNewConversation()

    guard let newConversation = conversationManager.conversations.first else {
      return
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
    conversationManager.addMessage(to: newConversation, message: userMessage)

    // Clear input first
    messageText = ""
    attachedFiles.removeAll()

    // Switch to the new conversation - ChatView will be shown
    selectedConversationId = newConversation.id
    isCreatingNew = false

    // Use a small delay to ensure ChatView is loaded, then trigger message sending
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      // The ChatView should now be displayed and will handle sending the message
      // We need to trigger it by simulating what happens in ChatView.sendMessage()
      self.sendMessageForConversation(newConversation)
    }
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

    let currentMessages = updatedConversation.messages

    // Add empty assistant message with current model
    let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
    conversationManager.addMessage(to: conversation, message: assistantMessage)

    // Get available MCP tools
    let mcpManager = MCPServerManager.shared
    let enabledTools = mcpManager.getEnabledTools()
    let tools = enabledTools.isEmpty ? nil : mcpManager.getEnabledToolsAsOpenAIFunctions()

    // Send the message using the public API
    openAIService.sendMessage(
      messages: currentMessages,
      model: updatedConversation.model,
      temperature: updatedConversation.temperature,
      tools: tools,
      conversationId: conversation.id,
      onChunk: { chunk in
        // Properly accumulate chunks by appending to existing content
        if let index = self.conversationManager.conversations.firstIndex(where: {
          $0.id == conversation.id
        }),
          var lastMessage = self.conversationManager.conversations[index].messages.last,
          lastMessage.role == .assistant
        {
          lastMessage.content += chunk
          self.conversationManager.conversations[index].messages[
            self.conversationManager.conversations[index].messages.count - 1] = lastMessage
        }
      },
      onComplete: {
        print("✅ Message sent successfully")
      },
      onError: { error in
        print("❌ Error sending message: \(error)")
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
