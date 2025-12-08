//
//
//  MacContentView.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
import CoreSpotlight
import OSLog
import SwiftUI

/// A wrapper to make non-Sendable types Sendable by unchecked conformance.
/// Use this only when you are sure the value is thread-safe or accessed safely.
private final class UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

extension Notification.Name {
    static let newConversationRequested = Notification.Name("newConversationRequested")
    static let sendPendingMessage = Notification.Name("sendPendingMessage")
}

struct MacContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager

    var body: some View {
        NavigationSplitView {
            MacSidebarView(selectedConversationId: $conversationManager.selectedConversationId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            Group {
                if let conversationId = conversationManager.selectedConversationId,
                   let conversation = conversationManager.conversations.first(where: {
                       $0.id == conversationId
                   })
                {
                    MacChatView(conversation: conversation)
                        .id(conversationId)
                } else {
                    MacNewChatView(
                        selectedConversationId: $conversationManager.selectedConversationId
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: {
                        conversationManager.selectedConversationId = nil
                        NotificationCenter.default.post(name: .newConversationRequested, object: nil)
                    }) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityIdentifier(TestIdentifiers.Sidebar.newConversationButton)
                }
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConversationRequested)) { _ in
            conversationManager.selectedConversationId = nil
        }
        .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
            if let idString = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let uuid = UUID(uuidString: idString)
            {
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "🔍 Opening conversation from Spotlight",
                    metadata: ["conversationId": idString]
                )
                conversationManager.selectedConversationId = uuid
            }
        }
    }
}

// View for creating a new conversation - only creates on first message
// MacNewChatView wraps full new-chat experience (composer, streaming, attachments).
// swiftlint:disable:next type_body_length
struct MacNewChatView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var selectedConversationId: UUID?
    @State private var messageText = ""
    @State private var isComposerFocused = true
    @State private var attachedFiles: [URL] = []
    @State private var isGenerating = false
    @State private var currentConversationId: UUID?
    @State private var selectedModel = OpenAIService.shared.selectedModel
    @State private var toolCallDepth = 0
    @State private var currentToolName: String?
    @State private var showModelSelector = false
    @State private var selectedModels: Set<String> = []
    @State private var isToolSectionExpanded = false

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
                // Always show assistant messages in a response group (multi-model mode)
                // They need to remain visible even after generation to show failed/empty states
                if message.responseGroupId != nil {
                    return true
                }
                return message.id == conversation.messages.last?.id && isGenerating
            }
            return !message.content.isEmpty || message.imageData != nil || message.mediaType == .image
        }
    }

    private var needsModelSetup: Bool {
        openAIService.usableModels.isEmpty
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
        if selectedModels.count > 1 {
            return "\(selectedModels.count) models"
        }
        let label = normalizedSelectedModel
        return label.isEmpty ? "Add Model" : label
    }

    private func isModelCurrentlySelected(_ model: String) -> Bool {
        selectedModels.contains(model)
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

            if needsModelSetup {
                ModelSetupPromptView(issues: modelSetupIssues)
            } else {
                VStack(spacing: 0) {
                    // Messages or empty state
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(visibleMessages) { message in
                                    MacMessageView(
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
                        .onChange(of: visibleMessages.count) { _, _ in
                            if let lastMessage = visibleMessages.last {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                        .onAppear {
                            isComposerFocused = true
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                if isToolSectionExpanded {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isToolSectionExpanded = false
                                    }
                                }
                            }
                        )
                    }

                    if let toolName = currentToolName {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .controlSize(.small)
                            Text(
                                toolName.hasPrefix("Analyzing")
                                    ? "🔄 \(toolName)..."
                                    : "🔧 Using tool: \(toolName)..."
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
                        MCPToolSummaryView(isExpanded: $isToolSectionExpanded)

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
                                                            fromByteCount: Int64(fileSize), countStyle: .file
                                                        )
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
                                            .accessibilityLabel("Remove attachment")
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
                                    isFirstResponder: $isComposerFocused,
                                    onSubmit: sendMessage,
                                    accessibilityIdentifier: TestIdentifiers.NewChatComposer.textEditor
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
                                .accessibilityLabel("Attach file")
                                .padding(.leading, 8)
                                .padding(.bottom, 8)
                            }

                            // Model selector
                            Button(action: { showModelSelector.toggle() }) {
                                HStack(spacing: 4) {
                                    Divider()
                                        .frame(height: 24)
                                        .padding(.leading, 8)

                                    if selectedModels.count > 1 {
                                        Image(systemName: "square.stack.3d.up.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.accentColor)
                                        Text("\(selectedModels.count) models")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        Text(composerModelLabel)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
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
                            .popover(isPresented: $showModelSelector) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Select models")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("1 model = single response, 2+ = compare")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                    Divider()
                                        .padding(.vertical, 4)

                                    if openAIService.usableModels.isEmpty {
                                        SettingsLink {
                                            Label("Add Model in Settings", systemImage: "slider.horizontal.3")
                                        }
                                        .routeSettings(to: .models)
                                    } else {
                                        ForEach(openAIService.usableModels, id: \.self) { model in
                                            Button(action: {
                                                toggleModelSelection(model)
                                            }) {
                                                HStack {
                                                    Image(systemName: selectedModels.contains(model) ? "checkmark.square.fill" : "square")
                                                        .foregroundStyle(selectedModels.contains(model) ? Color.accentColor : Color.secondary)
                                                        .font(.system(size: 14))
                                                    Text(model)
                                                        .font(.system(size: 13))
                                                    Spacer()
                                                }
                                                .padding(.vertical, 4)
                                                .padding(.horizontal, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(selectedModels.contains(model) ? Color.accentColor.opacity(0.1) : Color.clear)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    if selectedModels.count > 1 {
                                        Divider()
                                            .padding(.vertical, 4)
                                        Button(action: {
                                            if let first = selectedModels.first {
                                                selectedModels = [first]
                                                selectedModel = first
                                                openAIService.selectedModel = first
                                            }
                                        }) {
                                            HStack {
                                                Image(systemName: "xmark.circle")
                                                Text("Clear multi-selection")
                                            }
                                            .font(.system(size: 12))
                                            .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding()
                                .frame(minWidth: 220)
                            }

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
                            .accessibilityIdentifier(TestIdentifiers.NewChatComposer.sendButton)
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
                    .padding(.top, 8)
                    .padding(.bottom, 20)
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
            attributes: textAttributes
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
            selectedModels = [conversationModel]
        } else {
            selectedModel = openAIService.selectedModel
            selectedModels = [openAIService.selectedModel]
        }

        // Ensure we have at least one model selected if possible
        if selectedModels.isEmpty, !openAIService.usableModels.isEmpty {
            let first = openAIService.usableModels.first!
            selectedModels = [first]
            selectedModel = first
        }
    }

    private func toggleModelSelection(_ model: String) {
        if selectedModels.contains(model) {
            if selectedModels.count > 1 {
                selectedModels.remove(model)
            }
        } else {
            selectedModels.insert(model)
        }

        // Update single selection state for compatibility
        if selectedModels.count == 1, let first = selectedModels.first {
            selectedModel = first
            openAIService.selectedModel = first
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
            isComposerFocused = true
            return
        }

        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isComposerFocused = true
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

        conversationManager.updateModel(for: conversation, model: activeModel)

        // Update conversation with multi-model settings
        var updatedConversation = conversation
        updatedConversation.activeModels = Array(selectedModels)
        updatedConversation.multiModelEnabled = selectedModels.count > 1
        conversationManager.updateConversation(updatedConversation)

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
        isComposerFocused = true
        attachedFiles.removeAll()

        // DON'T switch views yet - stay in NewChatView so the stop button remains visible
        // The view switch will happen in the completion handler after generation finishes

        // Send the message immediately (no delay needed)
        if selectedModels.count > 1 {
            isGenerating = true
            sendMultiModelMessage(userMessageId: userMessage.id, models: Array(selectedModels), temperature: conversation.temperature)
        } else {
            sendMessageForConversation(conversation, model: activeModel)
        }
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
            metadata: ["conversationId": conversation.id.uuidString]
        )

        let currentMessages = updatedConversation.messages

        // Add empty assistant message with current model
        let assistantMessage = Message(role: .assistant, content: "", model: activeModel)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available tools (Tavily + MCP)
        let tools = openAIService.getAllAvailableTools()
        toolCallDepth = 0

        sendMessageWithToolSupport(
            conversation: conversation,
            messages: currentMessages,
            model: activeModel,
            temperature: updatedConversation.temperature,
            tools: tools
        )
    }

    private func sendMultiModelMessage(
        userMessageId: UUID,
        models: [String],
        temperature: Double
    ) {
        logNewChat(
            "🔀 Starting multi-model request",
            level: .info,
            metadata: ["models": models.joined(separator: ", ")]
        )

        // Get updated conversation
        guard let conversationId = currentConversationId,
              let updatedConversation = conversationManager.conversations.first(where: {
                  $0.id == conversationId
              })
        else {
            isGenerating = false
            return
        }

        // Create response group
        let responseGroupId = UUID()
        var responseGroup = ResponseGroup(id: responseGroupId, userMessageId: userMessageId)

        // Create placeholder messages for each model
        var messageIds: [String: UUID] = [:]
        for model in models {
            let messageId = UUID()
            messageIds[model] = messageId
            responseGroup.addResponse(messageId: messageId, modelName: model, status: .streaming)

            let placeholderMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId
            )
            conversationManager.addMessage(to: updatedConversation, message: placeholderMessage)
        }

        // Add response group to conversation
        conversationManager.addResponseGroup(to: updatedConversation, group: responseGroup)

        // Prepare messages for API
        var messagesToSend = updatedConversation.getEffectiveHistory()
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Send to all models in parallel
        openAIService.sendToMultipleModels(
            messages: messagesToSend,
            models: models,
            temperature: temperature,
            onChunk: { model, chunk in
                Task { @MainActor in
                    guard let messageId = messageIds[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: {
                              $0.id == conversationId
                          }),
                          let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: {
                              $0.id == messageId
                          })
                    else { return }

                    conversationManager.conversations[convIndex].messages[msgIndex].content += chunk
                }
            },
            onModelComplete: { model in
                Task { @MainActor in
                    guard let messageId = messageIds[model] else { return }

                    // Update response group status
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }),
                        var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                    {
                        group.updateStatus(for: messageId, status: .completed)
                        conversationManager.conversations[convIndex].updateResponseGroup(group)
                    }

                    logNewChat(
                        "✅ Model completed in multi-model",
                        level: .info,
                        metadata: ["model": model]
                    )
                }
            },
            onAllComplete: {
                Task { @MainActor in
                    isGenerating = false
                    logNewChat("🏁 All models completed", level: .info)

                    // Save the conversation
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }) {
                        conversationManager.save(conversationManager.conversations[convIndex])
                    }

                    // Switch to chat view
                    selectedConversationId = conversationId
                }
            },
            onError: { model, error in
                Task { @MainActor in
                    guard let messageId = messageIds[model] else { return }

                    // Update response group status to failed
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }),
                        var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                    {
                        group.updateStatus(for: messageId, status: .failed)
                        conversationManager.conversations[convIndex].updateResponseGroup(group)
                    }

                    logNewChat(
                        "❌ Model failed in multi-model",
                        level: .error,
                        metadata: ["model": model, "error": error.localizedDescription]
                    )
                }
            }
        )
    }

    // swiftlint:disable:next function_body_length
    private func sendMessageWithToolSupport(
        conversation: Conversation,
        messages: [Message],
        model: String,
        temperature: Double,
        tools: [[String: Any]]?
    ) {
        let maxToolCallDepth = 10
        let conversationId = conversation.id
        let mcpManager = MCPServerManager.shared
        let toolsWrapper = UncheckedSendable(tools)

        openAIService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
            conversationId: conversation.id,
            onChunk: { chunk in
                Task { @MainActor in
                    guard let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) else {
                        logNewChat(
                            "⚠️ Conversation \(conversationId) no longer exists, ignoring chunk",
                            level: .info,
                            metadata: ["conversationId": conversationId.uuidString]
                        )
                        return
                    }

                    if var lastMessage = conversationManager.conversations[index].messages.last,
                       lastMessage.role == .assistant
                    {
                        lastMessage.content += chunk
                        conversationManager.conversations[index].messages[
                            conversationManager.conversations[index].messages.count - 1
                        ] = lastMessage
                    }

                    if currentToolName != nil {
                        currentToolName = nil
                    }
                }
            },
            onComplete: {
                Task { @MainActor in
                    if currentToolName == nil {
                        currentToolName = nil
                        isGenerating = false
                        logNewChat(
                            "✅ Initial message finished streaming, switching to ChatView",
                            level: .info,
                            metadata: ["conversationId": conversationId.uuidString]
                        )
                        selectedConversationId = conversationId
                    }
                }
            },
            onError: { error in
                Task { @MainActor in
                    isGenerating = false
                    currentToolName = nil
                    toolCallDepth = 0
                    logNewChat(
                        "❌ Error sending initial message: \(error.localizedDescription)",
                        level: .error,
                        metadata: [
                            "conversationId": conversationId.uuidString,
                            "error": error.localizedDescription
                        ]
                    )
                    selectedConversationId = conversationId
                }
            },
            onToolCallRequested: { toolCallId, toolName, arguments in
                let argumentsWrapper = UncheckedSendable(arguments)
                Task { @MainActor in
                    let arguments = argumentsWrapper.value
                    guard conversationManager.conversations.contains(where: { $0.id == conversationId }) else {
                        logNewChat(
                            "⚠️ Tool call requested but conversation \(conversationId) no longer exists",
                            level: .error
                        )
                        return
                    }

                    currentToolName = toolName
                    logNewChat(
                        "🔧 Tool call requested: \(toolName)",
                        level: .info,
                        metadata: ["toolName": toolName]
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
                            arguments: anyCodableArgs
                        )
                        lastMessage.toolCalls = [toolCall]
                        conversationManager.conversations[index].messages[
                            conversationManager.conversations[index].messages.count - 1
                        ] = lastMessage
                        conversationManager.save(conversationManager.conversations[index])
                    }

                    Task {
                        do {
                            logNewChat(
                                "⚙️ Executing tool: \(toolName)",
                                level: .info,
                                metadata: ["toolName": toolName]
                            )

                            // Route to appropriate tool handler
                            let result: String
                            var citations: [CitationReference]?

                            if openAIService.isBuiltInTool(toolName) {
                                // Built-in tool (e.g., web_search via Tavily) - get citations
                                let (toolResult, toolCitations) = await openAIService.executeBuiltInToolWithCitations(
                                    name: toolName,
                                    arguments: argumentsWrapper.value
                                )
                                result = toolResult
                                citations = toolCitations
                            } else {
                                // MCP tool
                                result = try await mcpManager.executeTool(name: toolName, arguments: argumentsWrapper.value)
                            }

                            // For web_search, skip creating a visible tool message
                            let isWebSearch = toolName == "web_search"

                            await MainActor.run {
                                let anyCodableArgs = argumentsWrapper.value.reduce(into: [String: AnyCodable]()) { result, pair in
                                    result[pair.key] = AnyCodable(pair.value)
                                }

                                if !isWebSearch {
                                    // For non-web-search tools, create the tool message as before
                                    var toolMessage = Message(
                                        role: .tool,
                                        content: result
                                    )
                                    toolMessage.toolCalls = [
                                        MCPToolCall(
                                            id: toolCallId,
                                            toolName: toolName,
                                            arguments: anyCodableArgs,
                                            result: result
                                        )
                                    ]
                                    conversationManager.addMessage(to: conversation, message: toolMessage)
                                }

                                guard let updatedConversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                                    currentToolName = nil
                                    isGenerating = false
                                    selectedConversationId = conversationId
                                    return
                                }

                                // For web_search, attach citations to the new assistant message
                                var newAssistantMessage = Message(role: .assistant, content: "", model: model)
                                if isWebSearch, let citations {
                                    newAssistantMessage.citations = citations
                                }
                                conversationManager.addMessage(to: updatedConversation, message: newAssistantMessage)

                                // Re-fetch conversation AFTER adding the new assistant message
                                guard let convWithAssistant = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                                    currentToolName = nil
                                    isGenerating = false
                                    selectedConversationId = conversationId
                                    return
                                }

                                currentToolName = "Analyzing \(toolName) results"

                                logNewChat(
                                    "🔄 Sending follow-up request with tool output",
                                    level: .info,
                                    metadata: [
                                        "conversationId": conversationId.uuidString,
                                        "toolName": toolName
                                    ]
                                )

                                // Build messages for API - exclude the continuation assistant message
                                // The continuation message is just a placeholder for where we'll store the response
                                var messagesForAPI = Array(convWithAssistant.messages.dropLast())
                                if isWebSearch {
                                    // Append a synthetic tool message for the API only (not stored)
                                    var syntheticToolMessage = Message(role: .tool, content: result)
                                    syntheticToolMessage.toolCalls = [
                                        MCPToolCall(
                                            id: toolCallId,
                                            toolName: toolName,
                                            arguments: anyCodableArgs,
                                            result: result
                                        )
                                    ]
                                    // Append the tool message at the end (after the assistant with tool_calls)
                                    messagesForAPI.append(syntheticToolMessage)
                                }

                                // Clear tool name since tool execution is complete
                                // The continuation is now a regular API call
                                currentToolName = nil

                                sendMessageWithToolSupport(
                                    conversation: conversation,
                                    messages: messagesForAPI,
                                    model: model,
                                    temperature: temperature,
                                    tools: toolsWrapper.value
                                )
                            }
                        } catch {
                            await MainActor.run {
                                logNewChat(
                                    "❌ Tool execution failed: \(error.localizedDescription)",
                                    level: .error,
                                    metadata: ["toolName": toolName, "error": error.localizedDescription]
                                )
                                isGenerating = false
                                currentToolName = nil
                                selectedConversationId = conversationId
                            }
                        }
                    }
                }
            },
            onReasoning: { reasoning in
                Task { @MainActor in
                    if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                       var lastMessage = conversationManager.conversations[index].messages.last,
                       lastMessage.role == .assistant
                    {
                        let currentReasoning = lastMessage.reasoning ?? ""
                        lastMessage.reasoning = currentReasoning + reasoning
                        conversationManager.conversations[index].messages[
                            conversationManager.conversations[index].messages.count - 1
                        ] = lastMessage
                    }
                }
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
    MacContentView()
        .environmentObject(ConversationManager())
}
