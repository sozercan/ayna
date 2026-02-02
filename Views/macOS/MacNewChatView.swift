//
//  MacNewChatView.swift
//  ayna
//
//  New chat view for macOS - handles initial conversation creation and message sending.
//
// swiftlint:disable file_length

import Combine
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

/// Thread-safe counter for tracking async completion
@MainActor
private final class CompletionCounter {
    private var completed: Int = 0
    private let total: Int

    init(total: Int) {
        self.total = total
    }

    func increment() {
        completed += 1
    }

    var isComplete: Bool {
        completed >= total
    }
}

// swiftlint:disable:next type_body_length
struct MacNewChatView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject var aiService = AIService.shared
    @Binding var selectedConversationId: UUID?
    @State private var messageText = ""
    @State private var isComposerFocused = true
    @State private var attachedFiles: [URL] = []
    @State var isGenerating = false
    @State var currentConversationId: UUID?
    @State private var selectedModel = AIService.shared.selectedModel
    @State private var toolCallDepth = 0
    @State private var currentToolName: String?
    @State private var showModelSelector = false
    @State private var selectedModels: Set<String> = []
    @State private var isToolSectionExpanded = false

    @State var errorMessage: String?
    @State var errorRecoverySuggestion: String?
    @State var shouldOfferOpenSettings = false

    // App content attachment (Attach from App)
    @State private var showAppContentPicker = false
    @State private var attachedAppContent: AppContent?

    /// Cached font for text height calculation (computed property to avoid lazy initialization issues)
    private var textFont: NSFont {
        NSFont.systemFont(ofSize: 15)
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: textFont]
    }

    /// Get the current conversation being created
    private var currentConversation: Conversation? {
        guard let id = currentConversationId else { return nil }
        return conversationManager.conversations.first(where: { $0.id == id })
    }

    /// Determines the capability type of currently selected models (if any)
    private var selectedCapabilityType: AIService.ModelCapability? {
        guard let firstSelected = selectedModels.first else { return nil }
        return aiService.getModelCapability(firstSelected)
    }

    // MARK: - Multi-Model Display

    /// Get displayable items using the shared builder
    private var displayableItems: [DisplayableItem] {
        guard let conversation = currentConversation else { return [] }
        return DisplayableItemsBuilder.buildDisplayableItems(
            from: conversation.messages,
            conversation: conversation,
            isGenerating: isGenerating
        )
    }

    private var needsModelSetup: Bool {
        aiService.usableModels.isEmpty
            || aiService.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelSetupIssues: [String] {
        let modelSpecificIssues = aiService.configurationIssues.filter {
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
            in: .whitespacesAndNewlines
        ),
            !conversationModel.isEmpty
        {
            return conversationModel
        }

        return aiService.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                ForEach(displayableItems) { item in
                                    switch item {
                                    case let .message(message):
                                        MacMessageView(
                                            message: message,
                                            modelName: message.model,
                                            onRetry: nil,
                                            onSwitchModel: nil
                                        )
                                        .id(message.id)
                                    case let .responseGroup(groupId, responses):
                                        if let conversation = currentConversation {
                                            MultiModelResponseView(
                                                responseGroupId: groupId,
                                                responses: responses,
                                                conversation: conversation,
                                                onSelectResponse: { messageId in
                                                    conversationManager.selectResponse(
                                                        in: conversation,
                                                        groupId: groupId,
                                                        messageId: messageId
                                                    )
                                                },
                                                onRetry: nil
                                            )
                                            .id(item.id)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 24)
                        }
                        .onChange(of: displayableItems.count) { _, _ in
                            // Scroll to the last item
                            if let lastItem = displayableItems.last {
                                withAnimation {
                                    proxy.scrollTo(lastItem.id, anchor: .bottom)
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

                    ToolExecutionIndicator(toolName: currentToolName)

                    if let errorMessage {
                        ErrorBannerView(
                            message: errorMessage,
                            recoverySuggestion: errorRecoverySuggestion,
                            openSettingsTab: shouldOfferOpenSettings ? SettingsTab.models : nil,
                            onDismiss: { dismissError() },
                            identifierPrefix: "newchat.error"
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    // Input Area
                    inputArea
                }
            }
        }
        .onAppear {
            syncSelectedModelState()
        }
        .onChange(of: currentConversation?.model ?? "") { _, _ in
            syncSelectedModelState()
        }
        .onChange(of: aiService.selectedModel) { _, newValue in
            // Only follow global selection if we don't have a conversation yet
            guard currentConversation == nil else { return }
            selectedModel = newValue
        }
        .sheet(isPresented: $showAppContentPicker) {
            AppContentPickerView(
                onSelect: { content in
                    attachedAppContent = content
                    showAppContentPicker = false
                },
                onDismiss: {
                    showAppContentPicker = false
                }
            )
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 8) {
            MCPToolSummaryView(isExpanded: $isToolSectionExpanded)

            // Attached files preview
            if !attachedFiles.isEmpty {
                attachedFilesPreview
            }

            // Attached app content preview
            if let appContent = attachedAppContent {
                attachedAppContentPreview(appContent)
            }

            // Composer row
            composerRow
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(.ultraThinMaterial)
    }

    private var attachedFilesPreview: some View {
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

    private func attachedAppContentPreview(_ appContent: AppContent) -> some View {
        HStack(spacing: 8) {
            // App icon
            if let icon = appContent.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }

            // App name and window title
            VStack(alignment: .leading, spacing: 2) {
                Text(appContent.appName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                if let windowTitle = appContent.windowTitle, !windowTitle.isEmpty {
                    Text(windowTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Content type badge
            Text(appContent.contentType.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Remove button
            Button {
                attachedAppContent = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove app content")
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
    }

    private var composerRow: some View {
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

                // Attach menu button inside the text box (left side)
                Menu {
                    Button {
                        attachFile()
                    } label: {
                        Label("Attach Files...", systemImage: "doc")
                    }

                    Button {
                        showAppContentPicker = true
                    } label: {
                        Label("Attach from App...", systemImage: "macwindow")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Attach")
                .frame(width: 32, height: 32)
                .padding(.leading, 8)
                .padding(.bottom, 7)
            }

            // Model selector
            modelSelectorButton

            // Send button
            sendButton
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 24)
    }

    private var modelSelectorButton: some View {
        Button(action: { showModelSelector.toggle() }) {
            HStack(spacing: 4) {
                Divider()
                    .frame(height: 24)
                    .padding(.leading, 8)

                if selectedModels.count > 1 {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: Typography.Size.caption))
                        .foregroundStyle(Color.accentColor)
                    Text("\(selectedModels.count) models")
                        .font(Typography.modelName)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(composerModelLabel)
                        .font(Typography.modelName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Typography.Size.xs))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: calculateTextHeight() + 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showModelSelector) {
            modelSelectorPopover
        }
    }

    @ViewBuilder
    private var modelSelectorPopover: some View {
        let multiModelEnabled = AppPreferences.multiModelSelectionEnabled

        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(multiModelEnabled ? "Select models" : "Select model")
                .font(Typography.captionBold)
                .foregroundStyle(Theme.textSecondary)
            if multiModelEnabled {
                Text("1 model = single response, 2+ = compare")
                    .font(Typography.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            Divider()
                .padding(.vertical, Spacing.xxs)

            if aiService.usableModels.isEmpty {
                SettingsLink {
                    Label("Add Model in Settings", systemImage: "slider.horizontal.3")
                }
                .routeSettings(to: .models)
            } else {
                ForEach(aiService.usableModels, id: \.self) { model in
                    let isSelected = selectedModels.contains(model)
                    let modelCapability = aiService.getModelCapability(model)
                    let isCapabilityMismatch: Bool = {
                        guard let selectedType = selectedCapabilityType else { return false }
                        return modelCapability != selectedType
                    }()
                    // Only check capability mismatch in multi-model mode
                    let isDisabled = multiModelEnabled && !isSelected && isCapabilityMismatch

                    Button(action: {
                        toggleModelSelection(model)
                    }) {
                        HStack {
                            // Show checkbox for multi-model, radio for single-model
                            if multiModelEnabled {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                                    .font(.system(size: Typography.Size.body))
                            } else {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                                    .font(.system(size: Typography.Size.body))
                            }
                            Text(model)
                                .font(Typography.modelName)
                            Spacer()

                            // Show capability badge for image gen models
                            if modelCapability == .imageGeneration {
                                Image(systemName: "photo")
                                    .font(.system(size: Typography.Size.xs))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(.vertical, Spacing.xxs)
                        .padding(.horizontal, Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
                                .fill(isSelected ? Theme.selection : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0.5 : 1.0)
                }
            }

            if multiModelEnabled, selectedModels.count > 1 {
                Divider()
                    .padding(.vertical, Spacing.xxs)
                Button(action: {
                    if let first = selectedModels.first {
                        selectedModels = [first]
                        selectedModel = first
                        aiService.selectedModel = first
                    }
                }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Clear multi-selection")
                    }
                    .font(Typography.footnote)
                    .foregroundStyle(Theme.destructive)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(minWidth: 220)
    }

    private var sendButton: some View {
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

    // MARK: - Helper Methods

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
            in: .whitespacesAndNewlines
        ),
            !conversationModel.isEmpty
        {
            selectedModel = conversationModel
            selectedModels = [conversationModel]
        } else {
            selectedModel = aiService.selectedModel
            selectedModels = [aiService.selectedModel]
        }

        // Ensure we have at least one model selected if possible
        if selectedModels.isEmpty, let first = aiService.usableModels.first {
            selectedModels = [first]
            selectedModel = first
        }
    }

    private func toggleModelSelection(_ model: String) {
        let multiModelEnabled = AppPreferences.multiModelSelectionEnabled

        if !multiModelEnabled {
            // Single-select mode: always replace selection
            selectedModels = [model]
            selectedModel = model
            aiService.selectedModel = model
            return
        }

        // Multi-select mode
        if selectedModels.contains(model) {
            // Always allow removing a model (user can select a different one)
            selectedModels.remove(model)
        } else {
            // Check if we're trying to mix capability types
            let modelCapability = aiService.getModelCapability(model)
            if let selectedType = selectedCapabilityType, modelCapability != selectedType {
                // Clear existing selections and start fresh with the new type
                selectedModels.removeAll()
            }
            selectedModels.insert(model)
        }

        // Update single selection state for compatibility
        if selectedModels.count == 1, let first = selectedModels.first {
            selectedModel = first
            aiService.selectedModel = first
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

    func logNewChat(_ message: String, level: OSLogType = .default, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.contentView, level: level, message: message, metadata: metadata)
    }

    func updateResponseGroupStatus(conversationId: UUID, responseGroupId: UUID, messageId: UUID, status: ResponseGroup.ResponseStatus) {
        if let ci = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
           let gi = conversationManager.conversations[ci].responseGroups.firstIndex(where: { $0.id == responseGroupId }),
           let ei = conversationManager.conversations[ci].responseGroups[gi].responses.firstIndex(where: { $0.id == messageId })
        {
            conversationManager.conversations[ci].responseGroups[gi].responses[ei].status = status
        }
    }

    func updateResponseGroupViaGroup(conversationId: UUID, responseGroupId: UUID, messageId: UUID, status: ResponseGroup.ResponseStatus) {
        if let ci = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
           var group = conversationManager.conversations[ci].getResponseGroup(responseGroupId)
        {
            group.updateStatus(for: messageId, status: status)
            conversationManager.conversations[ci].updateResponseGroup(group)
        }
    }

    func saveImageAndUpdateMessage(imageData: Data, conversation: Conversation, messageId: UUID) {
        var imagePath: String?
        do { imagePath = try AttachmentStorage.shared.save(data: imageData, extension: "png") } catch {
            logNewChat("❌ Failed to save generated image: \(error.localizedDescription)", level: .error)
        }
        conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
            message.content = ""
            if let path = imagePath { message.imagePath = path; message.imageData = nil } else {
                message.imageData = imageData; message.imagePath = nil
            }
        }
    }

    // MARK: - Send Message

    private func sendMessage() {
        dismissError()
        if isGenerating {
            // Stop generation immediately
            logNewChat("🛑 Stop button clicked in NewChatView, cancelling...", level: .info)
            AIService.shared.cancelCurrentRequest()
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
            errorMessage = "Select a model in Settings → Models"
            errorRecoverySuggestion = "Add or select a model before sending your first message"
            shouldOfferOpenSettings = true
            return
        }

        aiService.selectedModel = activeModel
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
                let mimeType = MIMETypeHelper.getMimeType(for: fileURL)
                let attachment = Message.FileAttachment(
                    fileName: fileURL.lastPathComponent,
                    mimeType: mimeType,
                    data: fileData
                )
                attachments.append(attachment)
            }
        }

        // Build message content, including app context inline if attached
        let finalMessageContent: String
        if let appContent = attachedAppContent {
            // Format app content inline with the user's message
            let contextHeader = "---\n**Context from \(appContent.appName)**"
            let windowInfo = appContent.windowTitle.map { " (\($0))" } ?? ""
            let contentType = " [\(appContent.contentType.displayName)]"

            finalMessageContent = """
            \(contextHeader)\(windowInfo)\(contentType)

            ```
            \(appContent.redacted.content)
            ```
            ---

            \(textToSend)
            """

            logNewChat(
                "📎 Including app content in message",
                level: .info,
                metadata: [
                    "appName": appContent.appName,
                    "contentType": appContent.contentType.displayName,
                    "contentLength": "\(appContent.content.count)"
                ]
            )
        } else {
            finalMessageContent = textToSend
        }

        // Add the user message
        let userMessage = Message(
            role: .user,
            content: finalMessageContent,
            attachments: attachments.isEmpty ? nil : attachments
        )
        conversationManager.addMessage(to: conversation, message: userMessage)

        // Process memory commands (e.g., "remember that I prefer dark mode")
        if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: finalMessageContent) {
            logNewChat("💾 Memory command processed: \(memoryResponse)", level: .info)
        }

        // Clear input first
        messageText = ""
        isComposerFocused = true
        attachedFiles.removeAll()
        attachedAppContent = nil // Clear app content after sending

        // DON'T switch views yet - stay in NewChatView so the stop button remains visible
        // The view switch will happen in the completion handler after generation finishes

        // Check if we're in image generation mode (any selected model is image gen means all are)
        let modelCapability = aiService.getModelCapability(activeModel)
        if modelCapability == .imageGeneration {
            // Image generation flow - handle multi-model image gen
            isGenerating = true
            if selectedModels.count > 1 {
                generateMultiModelImages(prompt: textToSend, models: Array(selectedModels), conversation: conversation)
            } else {
                generateImage(prompt: textToSend, model: activeModel, conversation: conversation)
            }
            return
        }

        // Send the message immediately (no delay needed)
        if selectedModels.count > 1 {
            isGenerating = true
            sendMultiModelMessage(
                userMessageId: userMessage.id,
                models: Array(selectedModels),
                temperature: conversation.temperature
            )
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
        let tools = aiService.getAllAvailableTools()
        toolCallDepth = 0

        sendMessageWithToolSupport(
            conversation: conversation,
            messages: currentMessages,
            model: activeModel,
            temperature: updatedConversation.temperature,
            tools: tools
        )
    }

    // MARK: - Image Generation

    private func generateImage(prompt: String, model: String, conversation: Conversation) {
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

        aiService.generateImage(
            prompt: prompt,
            model: model,
            onComplete: { imageData in
                Task { @MainActor in
                    saveImageAndUpdateMessage(imageData: imageData, conversation: conversation, messageId: messageId)
                    isGenerating = false
                    selectedConversationId = conversation.id
                }
            },
            onError: { error in
                Task { @MainActor in
                    isGenerating = false
                    logNewChat(
                        "❌ Image generation failed: \(error.localizedDescription)",
                        level: .error,
                        metadata: ["model": model]
                    )
                    presentError(error)

                    // Remove the empty assistant placeholder message since we show error in banner
                    if let index = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversation.id
                    }) {
                        let lastIndex = conversationManager.conversations[index].messages.count - 1
                        if lastIndex >= 0,
                           conversationManager.conversations[index].messages[lastIndex].role == .assistant,
                           conversationManager.conversations[index].messages[lastIndex].content.isEmpty
                        {
                            conversationManager.conversations[index].messages.remove(at: lastIndex)
                        }
                    }
                }
            }
        )
    }

    /// Generates images from multiple models in parallel for comparison
    private func generateMultiModelImages(prompt: String, models: [String], conversation: Conversation) {
        // Create a response group for the multi-model comparison
        let responseGroupId = UUID()
        var responseEntries: [ResponseGroup.ResponseEntry] = []
        var messageIds: [String: UUID] = [:]

        // Create placeholder messages for each model
        for model in models {
            let messageId = UUID()
            messageIds[model] = messageId

            let placeholderMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId,
                mediaType: .image
            )
            conversationManager.addMessage(to: conversation, message: placeholderMessage)

            responseEntries.append(ResponseGroup.ResponseEntry(
                id: messageId,
                modelName: model,
                status: .streaming
            ))
        }

        // Create response group
        let responseGroup = ResponseGroup(
            id: responseGroupId,
            userMessageId: conversation.messages.first(where: { $0.role == .user })?.id
                ?? conversation.messages.last(where: { $0.role == .user })?.id ?? UUID(),
            responses: responseEntries
        )

        // Add response group to conversation
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversationManager.conversations[index].responseGroups.append(responseGroup)
        }

        // Track completion state with actor-isolated counter
        let counter = CompletionCounter(total: models.count)

        // Generate images in parallel
        for model in models {
            guard let messageId = messageIds[model] else { continue }

            aiService.generateImage(
                prompt: prompt,
                model: model,
                onComplete: { imageData in
                    Task { @MainActor in
                        saveImageAndUpdateMessage(imageData: imageData, conversation: conversation, messageId: messageId)
                        updateResponseGroupStatus(conversationId: conversation.id, responseGroupId: responseGroupId, messageId: messageId, status: .completed)
                        counter.increment()
                        if counter.isComplete { isGenerating = false; selectedConversationId = conversation.id }
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        logNewChat(
                            "❌ Image generation failed for \(model): \(error.localizedDescription)",
                            level: .error,
                            metadata: ["model": model]
                        )

                        updateResponseGroupStatus(conversationId: conversation.id, responseGroupId: responseGroupId, messageId: messageId, status: .failed)

                        // Update message with error
                        conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                            message.content = "Image generation failed: \(error.localizedDescription)"
                        }

                        counter.increment()
                        if counter.isComplete {
                            isGenerating = false
                            selectedConversationId = conversation.id
                        }
                    }
                }
            )
        }
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
        aiService.sendToMultipleModels(
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

                    updateResponseGroupViaGroup(conversationId: conversationId, responseGroupId: responseGroupId, messageId: messageId, status: .completed)
                    logNewChat("✅ Model completed in multi-model", level: .info, metadata: ["model": model])
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

                    updateResponseGroupViaGroup(conversationId: conversationId, responseGroupId: responseGroupId, messageId: messageId, status: .failed)
                    logNewChat("❌ Model failed in multi-model", level: .error, metadata: ["model": model, "error": error.localizedDescription])

                    if errorMessage == nil {
                        let safeMessage = ErrorPresenter.userMessage(for: error)
                        errorMessage = "\"\(model)\" failed: \(safeMessage)"
                        errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
                        shouldOfferOpenSettings = ErrorPresenter.suggestedAction(for: error) == .openSettings
                    }
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
        let maxToolCallDepth = AgentSettingsStore.shared.settings.maxToolChainDepth
        let conversationId = conversation.id
        let mcpManager = MCPServerManager.shared
        let toolsWrapper = UncheckedSendable(tools)

        aiService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
            conversationId: conversation.id,
            onChunk: { chunk in
                Task { @MainActor in
                    guard let index = conversationManager.conversations
                        .firstIndex(where: { $0.id == conversationId })
                    else {
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

                    presentError(error)
                }
            },
            onToolCallRequested: { toolCallId, toolName, arguments in
                let argumentsWrapper = UncheckedSendable(arguments)
                // IMPORTANT: Set currentToolName synchronously BEFORE the Task
                // to prevent race condition with onComplete checking if tool call is pending.
                currentToolName = toolName
                Task { @MainActor in
                    let arguments = argumentsWrapper.value
                    guard conversationManager.conversations.contains(where: { $0.id == conversationId }) else {
                        logNewChat(
                            "⚠️ Tool call requested but conversation \(conversationId) no longer exists",
                            level: .error
                        )
                        currentToolName = nil // Clear since we're not processing
                        return
                    }
                    logNewChat(
                        "🔧 Tool call requested: \(toolName)",
                        level: .info,
                        metadata: ["toolName": toolName]
                    )

                    guard toolCallDepth < maxToolCallDepth else {
                        logNewChat("⚠️ Max tool call depth reached in NewChatView", level: .error)
                        isGenerating = false
                        currentToolName = nil
                        errorMessage = "Too many tool calls"
                        errorRecoverySuggestion = "Try again, or disable tools in Settings"
                        shouldOfferOpenSettings = true
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

                            if aiService.isBuiltInTool(toolName) {
                                // Built-in tool (e.g., web_search, agentic tools) - get citations
                                let (toolResult, toolCitations) = await aiService
                                    .executeBuiltInToolWithCitations(
                                        name: toolName,
                                        arguments: argumentsWrapper.value,
                                        conversationId: conversation.id
                                    )
                                result = toolResult
                                citations = toolCitations
                            } else {
                                // MCP tool
                                result = try await mcpManager.executeTool(
                                    name: toolName,
                                    arguments: argumentsWrapper.value
                                )
                            }

                            // For web_search, skip creating a visible tool message
                            let isWebSearch = toolName == "web_search"

                            await MainActor.run {
                                let anyCodableArgs = argumentsWrapper.value
                                    .reduce(into: [String: AnyCodable]()) { result, pair in
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

                                guard let updatedConversation = conversationManager.conversations
                                    .first(where: { $0.id == conversationId })
                                else {
                                    currentToolName = nil
                                    isGenerating = false
                                    selectedConversationId = conversationId
                                    return
                                }

                                // For web_search, attach citations to the new assistant message
                                var newAssistantMessage = Message(
                                    role: .assistant,
                                    content: "",
                                    model: model
                                )
                                if isWebSearch, let citations {
                                    newAssistantMessage.citations = citations
                                }
                                conversationManager.addMessage(
                                    to: updatedConversation,
                                    message: newAssistantMessage
                                )

                                // Re-fetch conversation AFTER adding the new assistant message
                                guard let convWithAssistant = conversationManager.conversations
                                    .first(where: { $0.id == conversationId })
                                else {
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
                                presentError(error)
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

    func presentError(_ error: Error) {
        errorMessage = ErrorPresenter.userMessage(for: error)
        errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
        shouldOfferOpenSettings = ErrorPresenter.suggestedAction(for: error) == .openSettings
    }

    private func dismissError() {
        errorMessage = nil
        errorRecoverySuggestion = nil
        shouldOfferOpenSettings = false
    }
}
