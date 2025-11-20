//
//
//  ContentView.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
import OSLog
import SwiftUI

extension Notification.Name {
    static let newConversationRequested = Notification.Name("newConversationRequested")
}

struct ContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @State private var selectedConversationId: UUID?

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedConversationId: $selectedConversationId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            if let conversationId = selectedConversationId,
               let conversation = conversationManager.conversations.first(where: {
                   $0.id == conversationId
               })
            {
                ChatView(conversation: conversation)
                    .id(conversationId)
            } else {
                NewChatView(
                    selectedConversationId: $selectedConversationId,
                )
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConversationRequested)) { _ in
            selectedConversationId = nil
        }
    }
}

// View for creating a new conversation - only creates on first message
struct NewChatView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var selectedConversationId: UUID?
    @State private var messageText = ""
    @State private var attachedFiles: [URL] = []
    @State private var isGenerating = false
    @State private var currentConversationId: UUID?
    @State private var selectedModel = OpenAIService.shared.selectedModel
    @State private var toolCallDepth = 0
    @State private var currentToolName: String?

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
            if message.role == .system {
                return false
            }

            if message.role == .tool {
                return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            if message.role == .assistant && message.content.isEmpty && message.imageData == nil {
                return message.id == conversation.messages.last?.id && isGenerating
            }
            return !message.content.isEmpty || message.imageData != nil || message.mediaType == .image
        }
    }

    private var needsModelSetup: Bool {
        openAIService.customModels.isEmpty
            || openAIService.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelSetupIssues: [String] {
        let modelSpecificIssues = openAIService.configurationIssues.filter {
            $0.localizedCaseInsensitiveContains("model")
        }
        if !modelSpecificIssues.isEmpty {
            return modelSpecificIssues
        }
        return ["Add at least one model in Settings > Model tab"]
    }

    private var normalizedSelectedModel: String {
        let explicitSelection = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitSelection.isEmpty {
            return explicitSelection
        }

        if let conversationModel = currentConversation?.model.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !conversationModel.isEmpty
        {
            return conversationModel
        }

        return openAIService.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var composerModelLabel: String {
        let label = normalizedSelectedModel
        return label.isEmpty ? "Add Model" : label
    }

    private func isModelCurrentlySelected(_ model: String) -> Bool {
        normalizedSelectedModel == model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            // Chat background with subtle gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.95),
                ],
                startPoint: .top,
                endPoint: .bottom,
            )
            .ignoresSafeArea()

            if needsModelSetup {
                ModelSetupPromptView(issues: modelSetupIssues)
            } else {
                VStack(spacing: 0) {
                    // Messages or empty state
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(visibleMessages) { message in
                                    MessageView(
                                        message: message,
                                        modelName: message.model,
                                        onRetry: nil,
                                        onSwitchModel: nil,
                                    )
                                    .id(message.id)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 24)
                        }
                        .onChange(of: visibleMessages.count) { _, _ in
                            if let lastMessage = visibleMessages.last {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                    }

                    if let toolName = currentToolName {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .controlSize(.small)
                            Text(
                                toolName.hasPrefix("Analyzing")
                                    ? "🔄 \(toolName)..."
                                    : "🔧 Using tool: \(toolName)...",
                            )
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
                        MCPToolSummaryView()

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
                                                            fromByteCount: Int64(fileSize), countStyle: .file,
                                                        ),
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
                                DynamicTextEditor(
                                    text: $messageText,
                                    onSubmit: sendMessage,
                                    accessibilityIdentifier: TestIdentifiers.NewChatComposer.textEditor,
                                )
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
                                if openAIService.customModels.isEmpty {
                                    SettingsLink {
                                        Label("Add Model in Settings", systemImage: "slider.horizontal.3")
                                    }
                                    .routeSettings(to: .models)
                                } else {
                                    ForEach(Array(openAIService.customModels.enumerated()), id: \.offset) { _, model in
                                        Button(action: {
                                            selectedModel = model
                                            openAIService.selectedModel = model
                                            updateCurrentConversationModelIfNeeded(using: model)
                                        }) {
                                            HStack {
                                                Text(model)
                                                if isModelCurrentlySelected(model) {
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

                                    Text(composerModelLabel)
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
                                                messageText.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor,
                                            )
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .allowsHitTesting(isGenerating || !messageText.isEmpty)
                            .accessibilityIdentifier(TestIdentifiers.NewChatComposer.sendButton)
                            .padding(.horizontal, 12)
                            .frame(height: calculateTextHeight() + 24)
                        }
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5),
                        )
                        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                        .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 20)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .onAppear {
            syncSelectedModelState()
        }
        .onChange(of: currentConversation?.model ?? "") { _, _ in
            syncSelectedModelState()
        }
        .onChange(of: openAIService.selectedModel) { _, newValue in
            // Only follow global selection if we don't have a conversation yet
            guard currentConversation == nil else { return }
            selectedModel = newValue
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
            attributes: textAttributes,
        )

        let calculatedHeight = ceil(boundingRect.height) + 4
        return min(max(calculatedHeight, baseHeight), maxHeight)
    }

    private func resolveModelForSending() -> String? {
        let trimmedSelection = normalizedSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSelection.isEmpty ? nil : trimmedSelection
    }

    private func ensureConversationModelMatchesSelection(_ model: String) {
        guard let conversation = currentConversation else { return }
        if conversation.model != model {
            conversationManager.updateModel(for: conversation, model: model)
        }
    }

    private func updateCurrentConversationModelIfNeeded(using model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ensureConversationModelMatchesSelection(trimmed)
    }

    private func syncSelectedModelState() {
        if let conversationModel = currentConversation?.model.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !conversationModel.isEmpty
        {
            selectedModel = conversationModel
        } else {
            selectedModel = openAIService.selectedModel
        }
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
        metadata: [String: String] = [:],
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

        guard let activeModel = resolveModelForSending() else {
            logNewChat("⚠️ Cannot send message: no model selected", level: .error)
            return
        }

        openAIService.selectedModel = activeModel
        ensureConversationModelMatchesSelection(activeModel)

        let textToSend = messageText
        let filesToSend = attachedFiles

        // Get or create the conversation
        let conversation: Conversation
        if let existingId = currentConversationId,
           let existingConversation = conversationManager.conversations.first(where: {
               $0.id == existingId
           })
        {
            // Continue with existing conversation
            conversation = existingConversation
            logNewChat(
                "📝 Continuing with existing conversation: \(existingId)",
                metadata: ["conversationId": existingId.uuidString],
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
                metadata: ["conversationId": newConversation.id.uuidString],
            )
        }

        conversationManager.updateModel(for: conversation, model: activeModel)

        // Build file attachments
        var attachments: [Message.FileAttachment] = []
        for fileURL in filesToSend {
            if let fileData = try? Data(contentsOf: fileURL) {
                let mimeType = getMimeType(for: fileURL)
                let attachment = Message.FileAttachment(
                    fileName: fileURL.lastPathComponent,
                    mimeType: mimeType,
                    data: fileData,
                )
                attachments.append(attachment)
            }
        }

        // Add the user message
        let userMessage = Message(
            role: .user,
            content: textToSend,
            attachments: attachments.isEmpty ? nil : attachments,
        )
        conversationManager.addMessage(to: conversation, message: userMessage)

        // Clear input first
        messageText = ""
        attachedFiles.removeAll()

        // DON'T switch views yet - stay in NewChatView so the stop button remains visible
        // The view switch will happen in the completion handler after generation finishes

        // Send the message immediately (no delay needed)
        sendMessageForConversation(conversation, model: activeModel)
    }

    private func sendMessageForConversation(_ conversation: Conversation, model: String) {
        // Get the conversation with the user message we just added
        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeModel = trimmedModel.isEmpty ? updatedConversation.model : trimmedModel
        if updatedConversation.model != activeModel {
            conversationManager.updateModel(for: updatedConversation, model: activeModel)
        }

        isGenerating = true
        logNewChat(
            "🔄 isGenerating set to TRUE in NewChatView",
            metadata: ["conversationId": conversation.id.uuidString],
        )

        let currentMessages = updatedConversation.messages

        // Add empty assistant message with current model
        let assistantMessage = Message(role: .assistant, content: "", model: activeModel)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available MCP tools
        let mcpManager = MCPServerManager.shared
        let enabledTools = mcpManager.getEnabledTools()
        let tools = enabledTools.isEmpty ? nil : mcpManager.getEnabledToolsAsOpenAIFunctions()
        toolCallDepth = 0

        sendMessageWithToolSupport(
            conversation: conversation,
            messages: currentMessages,
            model: activeModel,
            temperature: updatedConversation.temperature,
            tools: tools,
        )
    }

    // swiftlint:disable:next function_body_length
    private func sendMessageWithToolSupport(
        conversation: Conversation,
        messages: [Message],
        model: String,
        temperature: Double,
        tools: [[String: Any]]?,
    ) {
        let maxToolCallDepth = 10
        let conversationId = conversation.id
        let mcpManager = MCPServerManager.shared

        openAIService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
            conversationId: conversation.id,
            onChunk: { chunk in
                guard let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) else {
                    logNewChat(
                        "⚠️ Conversation \(conversationId) no longer exists, ignoring chunk",
                        level: .info,
                        metadata: ["conversationId": conversationId.uuidString],
                    )
                    return
                }

                if var lastMessage = conversationManager.conversations[index].messages.last,
                   lastMessage.role == .assistant
                {
                    lastMessage.content += chunk
                    conversationManager.conversations[index].messages[
                        conversationManager.conversations[index].messages.count - 1,
                    ] = lastMessage
                }

                if currentToolName != nil {
                    currentToolName = nil
                }
            },
            onComplete: {
                if currentToolName == nil {
                    currentToolName = nil
                    isGenerating = false
                    logNewChat(
                        "✅ Initial message finished streaming, switching to ChatView",
                        level: .info,
                        metadata: ["conversationId": conversationId.uuidString],
                    )
                    selectedConversationId = conversationId
                }
            },
            onError: { error in
                isGenerating = false
                currentToolName = nil
                toolCallDepth = 0
                logNewChat(
                    "❌ Error sending initial message: \(error.localizedDescription)",
                    level: .error,
                    metadata: [
                        "conversationId": conversationId.uuidString,
                        "error": error.localizedDescription,
                    ],
                )
                selectedConversationId = conversationId
            },
            onToolCallRequested: { toolCallId, toolName, arguments in
                guard conversationManager.conversations.contains(where: { $0.id == conversationId }) else {
                    logNewChat(
                        "⚠️ Tool call requested but conversation \(conversationId) no longer exists",
                        level: .error,
                    )
                    return
                }

                currentToolName = toolName
                logNewChat(
                    "🔧 Tool call requested: \(toolName)",
                    level: .info,
                    metadata: ["toolName": toolName],
                )

                guard toolCallDepth < maxToolCallDepth else {
                    logNewChat("⚠️ Max tool call depth reached in NewChatView", level: .error)
                    isGenerating = false
                    currentToolName = nil
                    selectedConversationId = conversationId
                    return
                }

                toolCallDepth += 1

                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                   var lastMessage = conversationManager.conversations[index].messages.last,
                   lastMessage.role == .assistant
                {
                    let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                        result[pair.key] = AnyCodable(pair.value)
                    }

                    let toolCall = MCPToolCall(
                        id: toolCallId,
                        toolName: toolName,
                        arguments: anyCodableArgs,
                    )
                    lastMessage.toolCalls = [toolCall]
                    conversationManager.conversations[index].messages[
                        conversationManager.conversations[index].messages.count - 1,
                    ] = lastMessage
                    conversationManager.saveConversations()
                }

                Task {
                    do {
                        logNewChat(
                            "⚙️ Executing tool: \(toolName)",
                            level: .info,
                            metadata: ["toolName": toolName],
                        )
                        let result = try await mcpManager.executeTool(name: toolName, arguments: arguments)
                        await MainActor.run {
                            let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                                result[pair.key] = AnyCodable(pair.value)
                            }

                            var toolMessage = Message(
                                role: .tool,
                                content: result,
                            )
                            toolMessage.toolCalls = [
                                MCPToolCall(
                                    id: toolCallId,
                                    toolName: toolName,
                                    arguments: anyCodableArgs,
                                    result: result,
                                ),
                            ]
                            conversationManager.addMessage(to: conversation, message: toolMessage)

                            guard let updatedConversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                                currentToolName = nil
                                isGenerating = false
                                selectedConversationId = conversationId
                                return
                            }

                            let newAssistantMessage = Message(role: .assistant, content: "", model: model)
                            conversationManager.addMessage(to: conversation, message: newAssistantMessage)

                            currentToolName = "Analyzing \(toolName) results"

                            logNewChat(
                                "🔄 Sending follow-up request with tool output",
                                level: .info,
                                metadata: [
                                    "conversationId": conversationId.uuidString,
                                    "toolName": toolName,
                                ],
                            )

                            sendMessageWithToolSupport(
                                conversation: conversation,
                                messages: updatedConversation.messages,
                                model: model,
                                temperature: temperature,
                                tools: tools,
                            )
                        }
                    } catch {
                        await MainActor.run {
                            logNewChat(
                                "❌ Tool execution failed: \(error.localizedDescription)",
                                level: .error,
                                metadata: ["toolName": toolName, "error": error.localizedDescription],
                            )
                            isGenerating = false
                            currentToolName = nil
                            selectedConversationId = conversationId
                        }
                    }
                }
            },
            onReasoning: { reasoning in
                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                   var lastMessage = conversationManager.conversations[index].messages.last,
                   lastMessage.role == .assistant
                {
                    let currentReasoning = lastMessage.reasoning ?? ""
                    lastMessage.reasoning = currentReasoning + reasoning
                    conversationManager.conversations[index].messages[
                        conversationManager.conversations[index].messages.count - 1,
                    ] = lastMessage
                }
            },
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

private struct ModelSetupPromptView: View {
    let issues: [String]

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Add a model to start chatting")
                    .font(.title3.weight(.semibold))
                Text("Head to Settings → Model to connect OpenAI, Azure, or AIKit models before sending your first message.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }

            SettingsLink {
                Label("Open Settings", systemImage: "slider.horizontal.3")
            }
            .routeSettings(to: .models)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(ConversationManager())
}
