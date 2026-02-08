//
//  MacChatView.swift
//  ayna
//
//  Created on 11/2/25.
//

// swiftlint:disable file_length

import AppKit
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
private final class ChatViewCompletionCounter {
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

// ChatView currently wraps the full chat experience (history, composer, attachments, streaming, MCP
// tooling). Splitting it without a broader refactor would scatter tightly coupled state, so we allow
// the larger body here until the view hierarchy is modularized.

// swiftlint:disable:next type_body_length
struct MacChatView: View {
    let conversation: Conversation

    init(conversation: Conversation) {
        self.conversation = conversation
        _selectedModel = State(initialValue: conversation.model)
        // Initialize selectedModels with the conversation's active models if available, otherwise fallback to single model
        if conversation.multiModelEnabled, !conversation.activeModels.isEmpty {
            _selectedModels = State(initialValue: Set(conversation.activeModels))
        } else if !conversation.model.isEmpty {
            _selectedModels = State(initialValue: [conversation.model])
        }
    }

    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var aiService = AIService.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared

    @State private var messageText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var errorRecoverySuggestion: String?
    @State private var failedMessage: String?
    @State private var selectedModel: String
    @State private var attachedFiles: [URL] = []
    @State private var toolCallDepth = 0
    @State private var currentToolName: String?
    @State private var isComposerFocused = true
    @State private var toolChainTimeoutTask: Task<Void, Never>?
    @State private var showingSystemPromptSheet = false

    // Multi-model support (unified selection - 1 model = single, 2+ = multi)
    @State private var selectedModels: Set<String> = []
    @State private var showModelSelector = false
    @State private var isToolSectionExpanded = false

    /// Determines the capability type of currently selected models (if any)
    private var selectedCapabilityType: AIService.ModelCapability? {
        guard let firstSelected = selectedModels.first else { return nil }
        return aiService.getModelCapability(firstSelected)
    }

    // App content attachment (Work with Apps)
    @State private var showAppContentPicker = false
    @State private var attachedAppContent: AppContent?

    // Performance optimizations
    @State private var scrollDebounceTask: Task<Void, Never>?
    @State private var isNearBottom = true
    @State private var showScrollToBottom = false
    @State private var pendingChunks: [String] = []
    @State private var batchUpdateTask: Task<Void, Never>?
    @State private var visibleMessages: [Message] = []
    @State private var cachedConversationIndex: Int?
    @State private var cachedDisplayableItems: [DisplayableItem] = []

    /// Cached font for text height calculation (computed property to avoid lazy initialization issues)
    private var textFont: NSFont {
        NSFont.systemFont(ofSize: 15)
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: textFont]
    }

    /// Cache the current conversation to avoid repeated lookups
    private var currentConversation: Conversation {
        if let index = getConversationIndex() {
            return conversationManager.conversations[index]
        }
        return conversation
    }

    /// Helper to get conversation index with caching
    private func getConversationIndex() -> Int? {
        if let cached = cachedConversationIndex,
           cached < conversationManager.conversations.count,
           conversationManager.conversations[cached].id == conversation.id
        {
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

    /// Helper to filter visible messages
    private func updateVisibleMessages() {
        visibleMessages = currentConversation.messages.filter { message in
            // Hide system messages entirely
            if message.role == .system {
                return false
            }

            // Always show tool messages when they have content (tool replies are the "first" assistant response)
            if message.role == .tool {
                return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            // Always show assistant messages that have citations (from web search)
            if message.role == .assistant, let citations = message.citations, !citations.isEmpty {
                return true
            }

            // Show if: has content, has image data, or is generating image
            // Don't show empty assistant messages unless we're actively generating
            if message.role == .assistant && message.content.isEmpty && message.imageData == nil && message.imagePath == nil {
                // Hide assistant messages that only have tool calls (intermediate steps)
                // These are placeholders that triggered tool execution but have no response content
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    return false
                }
                // Always show assistant messages in a response group (multi-model mode)
                // They need to remain visible even after generation to show failed/empty states
                if message.responseGroupId != nil {
                    return true
                }
                // Only show empty assistant message if it's the last message and we're generating
                return message.id == currentConversation.messages.last?.id && isGenerating
            }

            return !message.content.isEmpty || message.imageData != nil || message.imagePath != nil || message.mediaType == .image
        }

        // Update displayable items after visible messages change
        updateDisplayableItems()
    }

    // MARK: - Multi-Model Display

    /// Represents either a single message or a group of parallel responses
    private enum DisplayableItem: Identifiable {
        case message(Message)
        case responseGroup(groupId: UUID, responses: [Message])

        var id: String {
            switch self {
            case let .message(msg):
                msg.id.uuidString
            case let .responseGroup(groupId, _):
                "group-\(groupId.uuidString)"
            }
        }
    }

    /// Updates cached displayable items. Call when messages change or isGenerating changes.
    private func updateDisplayableItems() {
        var items: [DisplayableItem] = []
        var processedGroupIds: Set<UUID> = []

        for message in visibleMessages {
            // Check if this message is part of a response group
            if let groupId = message.responseGroupId {
                // Only process each group once
                guard !processedGroupIds.contains(groupId) else { continue }
                processedGroupIds.insert(groupId)

                // Collect all messages in this group
                let groupResponses = visibleMessages.filter { $0.responseGroupId == groupId }

                // Always show response groups as a group, even if only one response is currently visible
                // This prevents UI jumping when responses arrive sequentially
                items.append(.responseGroup(groupId: groupId, responses: groupResponses))
            } else {
                // Regular message (not part of a response group)
                items.append(.message(message))
            }
        }

        cachedDisplayableItems = items
    }

    private var normalizedSelectedModel: String {
        let explicitSelection = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitSelection.isEmpty {
            return explicitSelection
        }
        return currentConversation.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var composerModelLabel: String {
        let displayName = normalizedSelectedModel
        if displayName.isEmpty {
            return aiService.usableModels.isEmpty ? "Add Model" : "Select Model"
        }
        return displayName
    }

    private func isModelCurrentlySelected(_ model: String) -> Bool {
        normalizedSelectedModel == model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(cachedDisplayableItems) { item in
                                switch item {
                                case let .message(message):
                                    MacMessageView(
                                        message: message,
                                        modelName: message.model,
                                        onRetry: message.role == .assistant
                                            ? {
                                                retryLastMessage(beforeMessage: message)
                                            } : nil,
                                        onSwitchModel: message.role == .assistant
                                            ? { newModel in
                                                switchModelAndRetry(beforeMessage: message, newModel: newModel)
                                            } : nil
                                    )
                                    .id(message.id)
                                case let .responseGroup(groupId, responses):
                                    MultiModelResponseView(
                                        responseGroupId: groupId,
                                        responses: responses,
                                        conversation: currentConversation,
                                        onSelectResponse: { messageId in
                                            conversationManager.selectResponse(
                                                in: currentConversation,
                                                groupId: groupId,
                                                messageId: messageId
                                            )
                                        },
                                        onRetry: { message in
                                            retryLastMessage(beforeMessage: message)
                                        }
                                    )
                                    .id(item.id)
                                }
                            }

                            // Anchor for scroll position detection
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .onAppear { isNearBottom = true; showScrollToBottom = false }
                                .onDisappear { isNearBottom = false; showScrollToBottom = true }
                        }
                        .padding(.horizontal, Spacing.contentPadding)
                        .padding(.vertical, Spacing.contentPadding)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: currentConversation.messages.count) { _, _ in
                        scrollDebounceTask?.cancel()
                        scrollDebounceTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(isGenerating ? 150 : 0))
                            guard !Task.isCancelled, isNearBottom else { return }
                            if let lastMessage = currentConversation.messages.last {
                                if isGenerating {
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
                        updateVisibleMessages()
                        syncSelectedModelWithConversation()
                        // Scroll to bottom after a short delay to ensure content is laid out
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            if let lastMessage = currentConversation.messages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: conversation.id) { _, _ in
                        updateVisibleMessages()
                        syncSelectedModelWithConversation()
                        // Scroll to bottom when switching conversations
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            if let lastMessage = currentConversation.messages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: currentConversation.messages) { _, _ in
                        updateVisibleMessages()
                    }
                    .onChange(of: currentConversation.messages.last?.content) { _, _ in
                        if isGenerating {
                            Task { @MainActor in
                                guard isNearBottom else { return }
                                if let lastMessage = currentConversation.messages.last {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .onChange(of: currentConversation.model) { _, _ in
                        syncSelectedModelWithConversation()
                    }
                    .onChange(of: isGenerating) { _, _ in
                        updateVisibleMessages()
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
                    // Overlay scroll-to-bottom button inside ScrollViewReader so we can use proxy
                    .overlay(alignment: .bottom) {
                        MacScrollToBottomButton(
                            isVisible: showScrollToBottom && !isGenerating,
                            unreadCount: 0
                        ) {
                            withAnimation(Motion.springStandard) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .padding(.bottom, Spacing.md)
                    }
                }

                // Rate Limit Warning Banner (GitHub Models only)
                if aiService.provider == .githubModels {
                    RateLimitWarningBanner(
                        rateLimitInfo: GitHubOAuthService.shared.rateLimitInfo,
                        retryAfterDate: GitHubOAuthService.shared.retryAfterDate
                    )
                    .padding(.horizontal, Spacing.contentPadding)
                }

                // Error Message
                if let error = errorMessage {
                    ErrorBannerView(
                        message: error,
                        recoverySuggestion: errorRecoverySuggestion,
                        onRetry: failedMessage != nil ? { retryFailedMessage() } : nil,
                        onDismiss: { dismissError() },
                        identifierPrefix: "chat.error"
                    )
                    .padding(.horizontal, Spacing.contentPadding)
                }

                // Tool execution status indicator
                if let toolName = currentToolName {
                    ToolExecutionIndicator(toolName: toolName)
                }

                // Pending tool approval requests - reads directly from @Observable PermissionService
                PendingApprovalsSectionView(
                    conversationId: conversation.id,
                    permissionService: aiService.permissionService
                )

                // Input Area
                VStack(spacing: Spacing.sm) {
                    MCPToolSummaryView(isExpanded: $isToolSectionExpanded)

                    // Attached files preview
                    if !attachedFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.sm) {
                                ForEach(attachedFiles, id: \.self) { fileURL in
                                    HStack(spacing: Spacing.sm) {
                                        // Show image thumbnail if it's an image file
                                        if let image = NSImage(contentsOf: fileURL) {
                                            Image(nsImage: image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 48, height: 48)
                                                .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
                                        } else {
                                            Image(systemName: "doc.fill")
                                                .font(.system(size: Typography.IconSize.lg))
                                                .foregroundStyle(Theme.textSecondary)
                                                .frame(width: 48, height: 48)
                                        }

                                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                            Text(fileURL.lastPathComponent)
                                                .font(Typography.caption)
                                                .lineLimit(1)
                                            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                                                .fileSize
                                            {
                                                Text(
                                                    ByteCountFormatter.string(
                                                        fromByteCount: Int64(fileSize), countStyle: .file
                                                    )
                                                )
                                                .font(Typography.footnote)
                                                .foregroundStyle(Theme.textSecondary)
                                            }
                                        }

                                        Button(action: { removeFile(fileURL) }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: Typography.IconSize.md))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove attachment")
                                    }
                                    .padding(Spacing.sm)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
                                }
                            }
                            .padding(.horizontal, Spacing.contentPadding)
                        }
                    }

                    // Attached app content preview
                    if let appContent = attachedAppContent {
                        HStack(spacing: Spacing.sm) {
                            // App icon
                            if let icon = appContent.appIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app.fill")
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle(Theme.textSecondary)
                            }

                            // App name and window title
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appContent.appName)
                                    .font(Typography.captionBold)
                                    .foregroundStyle(Theme.textPrimary)

                                if let windowTitle = appContent.windowTitle, !windowTitle.isEmpty {
                                    Text(windowTitle)
                                        .font(Typography.footnote)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            // Content type badge
                            Text(appContent.contentType.displayName)
                                .font(Typography.footnote)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, 2)
                                .background(Theme.backgroundTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            // Remove button
                            Button {
                                attachedAppContent = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: Typography.IconSize.md))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove app content")
                        }
                        .padding(Spacing.sm)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
                        .padding(.horizontal, Spacing.contentPadding)
                    }

                    HStack(spacing: 0) {
                        ZStack(alignment: .bottomLeading) {
                            DynamicTextEditor(
                                text: $messageText,
                                isFirstResponder: $isComposerFocused,
                                onSubmit: sendMessage,
                                accessibilityIdentifier: TestIdentifiers.ChatComposer.textEditor
                            )
                            .frame(height: calculateTextHeight())
                            .font(Typography.body)
                            .scrollContentBackground(.hidden)
                            .padding(.leading, 48) // Padding for attach button
                            .padding(.trailing, Spacing.md)
                            .padding(.vertical, Spacing.md)
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
                                    .font(.system(size: Typography.IconSize.xl))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Attach")
                            .padding(.leading, Spacing.sm)
                            .padding(.bottom, Spacing.sm)
                        }

                        // Model selector with multi-select support (using Popover for persistence)
                        Button(action: { showModelSelector.toggle() }) {
                            HStack(spacing: Spacing.xxs) {
                                Divider()
                                    .frame(height: 24)
                                    .padding(.leading, Spacing.sm)

                                if selectedModels.count > 1 {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.system(size: Typography.Size.caption))
                                        .foregroundStyle(Theme.accent)
                                    Text("\(selectedModels.count) models")
                                        .font(Typography.modelName)
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Text(composerModelLabel)
                                        .font(Typography.modelName)
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: Typography.Size.xs))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, Spacing.md)
                            .frame(height: calculateTextHeight() + Spacing.xxl)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .popover(isPresented: $showModelSelector) {
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
                                            conversationManager.updateModel(for: conversation, model: first)
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

                        // Send button on the rightmost side
                        Button(action: sendMessage) {
                            ZStack {
                                if isGenerating {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: Typography.IconSize.xl))
                                        .foregroundStyle(Theme.accent)
                                        .symbolEffect(.pulse, value: isGenerating)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: Typography.IconSize.xl))
                                        .foregroundStyle(
                                            messageText.isEmpty ? Theme.textSecondary.opacity(0.5) : Theme.accent
                                        )
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(isGenerating || !messageText.isEmpty)
                        .accessibilityIdentifier(TestIdentifiers.ChatComposer.sendButton)
                        .padding(.horizontal, Spacing.md)
                        .frame(height: calculateTextHeight() + Spacing.xxl)
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.pill + Spacing.CornerRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Spacing.CornerRadius.pill + Spacing.CornerRadius.sm)
                            .stroke(Theme.border, lineWidth: Spacing.Border.hairline)
                    )
                    .shadow(color: Theme.shadow.opacity(0.35), radius: Spacing.Shadow.radiusStandard, x: 0, y: Spacing.Shadow.offsetY)
                    .padding(.horizontal, Spacing.contentPadding)
                }
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.composerBottomPadding)
                .background(.ultraThinMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSystemPromptSheet = true
                } label: {
                    Image(systemName: "text.bubble")
                }
                .accessibilityIdentifier("chat.systemPrompt.button")
                .help("Conversation System Prompt")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: { exportConversation(format: .markdown) }) {
                        Label("Export as Markdown", systemImage: "doc.text")
                    }
                    Button(action: { exportConversation(format: .pdf) }) {
                        Label("Export as PDF", systemImage: "doc.text.image")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuIndicator(.visible)
                .accessibilityLabel("Export conversation")
            }
        }
        .sheet(isPresented: $showingSystemPromptSheet) {
            ConversationSystemPromptSheet(conversation: currentConversation)
                .environmentObject(conversationManager)
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
        .onAppear {
            isComposerFocused = true
            checkAndProcessPendingPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sendPendingMessage)) { notification in
            // Handle Work with Apps: auto-send message when conversation is created with context
            guard let conversationId = notification.userInfo?["conversationId"] as? UUID,
                  conversationId == conversation.id,
                  !isGenerating
            else { return }

            // Check if there's a pending user message without assistant response
            let messages = currentConversation.messages
            if let lastMessage = messages.last,
               lastMessage.role == .user,
               !messages.contains(where: { $0.role == .assistant })
            {
                logChat("📤 Auto-sending message from Work with Apps", level: .info)
                sendPendingUserMessage()
            }
        }
    }

    /// Check for and process a pending auto-send prompt from deep link.
    private func checkAndProcessPendingPrompt() {
        guard let index = getConversationIndex(),
              let prompt = conversationManager.conversations[index].pendingAutoSendPrompt,
              !prompt.isEmpty
        else {
            return
        }

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔗 Processing pending auto-send prompt from deep link",
            metadata: ["promptLength": "\(prompt.count)"]
        )

        // Clear the pending prompt to prevent re-sending
        conversationManager.conversations[index].pendingAutoSendPrompt = nil

        // Set the message text and send
        messageText = prompt
        // Use a small delay to ensure the view is fully loaded
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            sendMessage()
        }
    }

    /// Sends the last user message in the conversation (used for Work with Apps)
    private func sendPendingUserMessage() {
        guard let lastUserMessage = currentConversation.messages.last(where: { $0.role == .user }) else {
            return
        }

        isGenerating = true

        // Build messages for API using the same pattern as sendMessage
        var messagesToSend = currentConversation.messages
        if let systemPrompt = buildFullSystemPrompt(for: currentConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Create assistant placeholder
        let assistantMessage = Message(role: .assistant, content: "", model: currentConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Use unified tool collection (includes Tavily + MCP tools)
        let tools = aiService.getAllAvailableTools()

        // Send to AI
        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: currentConversation.model,
            temperature: currentConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
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

    // MARK: - Export Helpers

    private enum ExportFormat {
        case markdown
        case pdf
    }

    private func exportConversation(format: ExportFormat) {
        let url: URL?
        switch format {
        case .markdown:
            let content = ConversationExporter.generateMarkdown(for: currentConversation)
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "\(currentConversation.title.replacingOccurrences(of: " ", with: "_")).md"
            let fileURL = tempDir.appendingPathComponent(fileName)
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
                url = fileURL
            } catch {
                logChat("❌ Failed to write markdown export: \(error.localizedDescription)", level: .error)
                url = nil
            }
        case .pdf:
            url = ConversationExporter.generatePDF(for: currentConversation)
        }

        if let url {
            showShareSheet(for: url)
        }
    }

    private func showShareSheet(for url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        // Defer to next run loop to ensure window state is ready
        Task { @MainActor in
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
            }
        }
    }

    // MARK: - Model Selection Helpers

    private func resolveModelForSending() -> String? {
        let trimmedSelection = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty {
            return trimmedSelection
        }

        let trimmedConversationModel = currentConversation.model.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedConversationModel.isEmpty {
            return trimmedConversationModel
        }

        let trimmedGlobal = aiService.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedGlobal.isEmpty ? nil : trimmedGlobal
    }

    private func ensureConversationModelMatchesSelection(_ model: String) {
        if currentConversation.model != model {
            conversationManager.updateModel(for: conversation, model: model)
        }
        if selectedModel != model {
            selectedModel = model
        }
    }

    private func syncSelectedModelWithConversation() {
        guard
            let currentConv = conversationManager.conversations.first(where: { $0.id == conversation.id })
        else {
            return
        }

        let latest = currentConv.model
        if latest != selectedModel {
            selectedModel = latest
        }

        // Sync multi-model state from conversation if enabled
        if currentConv.multiModelEnabled, !currentConv.activeModels.isEmpty {
            let activeSet = Set(currentConv.activeModels)
            if selectedModels != activeSet {
                selectedModels = activeSet
            }
        } else if selectedModels.isEmpty {
            // Initialize selectedModels if empty (for new conversations or first load)
            if !latest.isEmpty {
                selectedModels = [latest]
            } else if let firstAvailable = aiService.usableModels.first {
                // Fallback to first available model if conversation model is empty
                selectedModels = [firstAvailable]
                selectedModel = firstAvailable
                conversationManager.updateModel(for: conversation, model: firstAvailable)
            }
        }
    }

    private func updateConversationMultiModelState() {
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            var updatedConversation = conversationManager.conversations[index]
            updatedConversation.activeModels = Array(selectedModels)
            updatedConversation.multiModelEnabled = selectedModels.count > 1
            conversationManager.updateConversation(updatedConversation)
        }
    }

    private func toggleModelSelection(_ model: String) {
        let multiModelEnabled = AppPreferences.multiModelSelectionEnabled

        if !multiModelEnabled {
            // Single-select mode: always replace selection
            selectedModels = [model]
            selectedModel = model
            conversationManager.updateModel(for: conversation, model: model)
            updateConversationMultiModelState()
            return
        }

        // Multi-select mode
        if selectedModels.contains(model) {
            // Always allow removing a model (user can select a different one)
            selectedModels.remove(model)
            // Update primary model if we still have selections
            if selectedModels.count == 1, let remaining = selectedModels.first {
                selectedModel = remaining
                conversationManager.updateModel(for: conversation, model: remaining)
            }
        } else {
            // Check if we're trying to mix capability types
            let modelCapability = aiService.getModelCapability(model)
            if let selectedType = selectedCapabilityType, modelCapability != selectedType {
                // Clear existing selections and start fresh with the new type
                selectedModels.removeAll()
            }
            // Allow up to 4 models
            if selectedModels.count < 4 {
                selectedModels.insert(model)
                // If this is the only selection, make it the primary model
                if selectedModels.count == 1 {
                    selectedModel = model
                    conversationManager.updateModel(for: conversation, model: model)
                }
            }
        }
        updateConversationMultiModelState()
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

    /// Auto-select response if we are continuing from a multi-model state without selection
    private func autoSelectResponseIfNeeded() {
        guard let lastMessage = currentConversation.messages.last,
              let groupId = lastMessage.responseGroupId,
              let group = currentConversation.getResponseGroup(groupId),
              group.selectedResponseId == nil
        else {
            return
        }

        let responses = currentConversation.messages.filter { $0.responseGroupId == groupId }
        var candidateId: UUID?

        // 1. Primary: conversation.model
        if let match = responses.first(where: { $0.model == currentConversation.model }) {
            candidateId = match.id
        }
        // 2. Fallback: First model
        else if let first = responses.first {
            candidateId = first.id
        }

        if let id = candidateId {
            logChat("🤖 Auto-selecting response before sending new message", metadata: ["messageId": id.uuidString])
            conversationManager.selectResponse(in: currentConversation, groupId: groupId, messageId: id)
        }
    }

    // MARK: - Error Handling

    /// Retry the last failed message
    private func retryFailedMessage() {
        guard let message = failedMessage else { return }

        logChat("🔄 Retrying failed message", level: .info, metadata: ["messageLength": "\(message.count)"])

        // Clear error state
        failedMessage = nil
        errorMessage = nil
        errorRecoverySuggestion = nil

        // Set message text and send
        messageText = message
        sendMessage()
    }

    /// Dismiss the current error without retrying
    private func dismissError() {
        failedMessage = nil
        errorMessage = nil
        errorRecoverySuggestion = nil
    }

    // MARK: - Message Sending

    // This method coordinates attachment handling, MCP tool availability, streaming setup, and state
    // resets. Breaking it apart right now would require plumbing a large amount of shared state, so
    // we defer that refactor and explicitly allow the longer body.
    // swiftlint:disable:next function_body_length
    private func sendMessage() {
        if isGenerating {
            // Stop generation immediately
            logChat("🛑 Stop button clicked, cancelling...", level: .info)
            AIService.shared.cancelCurrentRequest()

            // Flush any pending chunks before stopping
            batchUpdateTask?.cancel()
            if !pendingChunks.isEmpty {
                let remainingChunks = pendingChunks.joined()
                pendingChunks.removeAll()

                if let index = conversationManager.conversations.firstIndex(where: {
                    $0.id == conversation.id
                }),
                    var lastMessage = conversationManager.conversations[index].messages.last,
                    lastMessage.role == .assistant
                {
                    lastMessage.content += remainingChunks
                    conversationManager.conversations[index].messages[
                        conversationManager.conversations[index].messages.count - 1
                    ] = lastMessage
                    logChat(
                        "💾 Flushed \(remainingChunks.count) chars before cancellation",
                        level: .info,
                        metadata: ["chunkLength": "\(remainingChunks.count)"]
                    )
                }
            }

            // Save conversations immediately to persist partial message
            if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversationManager.saveImmediately(conversationManager.conversations[index])
                logChat("💾 Saved conversation after cancellation", level: .info)
            } else {
                logChat("⚠️ Could not find conversation to save after cancellation", level: .error)
            }

            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
            toolChainTimeoutTask?.cancel()
            toolChainTimeoutTask = nil
            logChat("✅ isGenerating set to FALSE after stop", level: .info)
            isComposerFocused = true
            return
        }

        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isComposerFocused = true
            return
        }

        // Auto-select response if we are continuing from a multi-model state without selection
        autoSelectResponseIfNeeded()

        guard let activeModel = resolveModelForSending() else {
            logChat("❌ Cannot send message: no model selected", level: .error)
            errorMessage = "Select a model in Settings → Model."
            return
        }

        ensureConversationModelMatchesSelection(activeModel)
        logChat(
            "🎯 Sending message with model \(activeModel)",
            level: .info,
            metadata: ["model": activeModel]
        )

        // Build user message using ChatMessageBuilder
        let userMessage = ChatMessageBuilder.createUserMessage(
            text: messageText,
            appContent: attachedAppContent,
            fileURLs: attachedFiles,
            saveToStorage: true
        )

        if attachedAppContent != nil {
            logChat(
                "📎 Including app content in message",
                level: .info,
                metadata: [
                    "appName": attachedAppContent?.appName ?? "",
                    "contentType": attachedAppContent?.contentType.displayName ?? "",
                    "contentLength": "\(attachedAppContent?.content.count ?? 0)"
                ]
            )
        }

        logChat(
            "📨 Creating message with \(userMessage.attachments?.count ?? 0) attachments",
            level: .info,
            metadata: ["attachmentCount": "\(userMessage.attachments?.count ?? 0)"]
        )
        conversationManager.addMessage(to: conversation, message: userMessage)

        // Process memory commands (e.g., "remember that I prefer dark mode")
        if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: userMessage.content) {
            logChat("💾 Memory command processed: \(memoryResponse)", level: .info)
        }

        let promptText = messageText
        messageText = ""
        isComposerFocused = true
        attachedFiles = [] // Clear attached files after sending
        attachedAppContent = nil // Clear app content after sending
        errorMessage = nil
        errorRecoverySuggestion = nil
        failedMessage = promptText // Store for retry in case of failure
        isGenerating = true
        logChat("🔄 isGenerating set to TRUE", level: .info)

        // Get updated messages after adding user message
        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        // Check if we're in image generation mode (any selected model is image gen means all are)
        let modelCapability = aiService.getModelCapability(activeModel)

        if modelCapability == .imageGeneration {
            // Image generation flow - handle multi-model image gen
            if selectedModels.count >= 2 {
                generateMultiModelImages(prompt: promptText, models: Array(selectedModels))
            } else {
                generateImage(prompt: promptText, model: activeModel)
            }
            return
        }

        // Check if multi-model mode is enabled (2+ models selected)
        if selectedModels.count >= 2 {
            sendMultiModelMessage(
                userMessageId: userMessage.id,
                models: Array(selectedModels),
                temperature: updatedConversation.temperature
            )
            return
        }

        let currentMessages = updatedConversation.messages

        // Prepend system prompt if configured
        var messagesToSend = currentMessages
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Add empty assistant message with current model
        let assistantMessage = Message(role: .assistant, content: "", model: activeModel)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available MCP tools
        let mcpManager = MCPServerManager.shared

        logChat(
            "📊 Total available tools in manager: \(mcpManager.availableTools.count)",
            metadata: ["availableTools": "\(mcpManager.availableTools.count)"]
        )
        logChat(
            "📊 Enabled server configs: \(mcpManager.serverConfigs.filter(\.enabled).map(\.name))",
            metadata: [
                "enabledServers": mcpManager.serverConfigs
                    .filter(\.enabled)
                    .map(\.name)
                    .joined(separator: ",")
            ]
        )

        let enabledMCPTools = mcpManager.getEnabledTools()

        // If we have enabled servers but no tools yet, wait a moment and try again
        // This handles the race condition where servers are connecting at app startup
        if enabledMCPTools.isEmpty {
            let hasEnabledServers = !mcpManager.serverConfigs.filter(\.enabled).isEmpty
            if hasEnabledServers {
                logChat("⏳ Enabled servers found but no tools yet, waiting for discovery...", level: .info)
                // Give discovery a moment to complete (non-blocking)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
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

        // Use unified tool collection (includes Tavily + MCP tools)
        let tools = aiService.getAllAvailableTools()

        if let tools, !tools.isEmpty {
            let toolNames = tools.compactMap { tool -> String? in
                guard let function = tool["function"] as? [String: Any],
                      let name = function["name"] as? String else { return nil }
                return name
            }
            logChat(
                "🔧 Available tools: \(toolNames.joined(separator: ", "))",
                level: .info,
                metadata: ["tools": toolNames.joined(separator: ", ")]
            )
        } else {
            logChat("⚠️ No tools available. Configure web search or MCP servers in Settings", level: .info)
        }

        // Reset tool call depth for new user messages
        toolCallDepth = 0

        // Start timeout watchdog for tool chain (60 seconds max)
        toolChainTimeoutTask?.cancel()
        toolChainTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            if toolCallDepth > 0 {
                logChat("⏰ Tool chain timeout after 60s, resetting state", level: .error)
                toolCallDepth = 0
                currentToolName = nil
                if isGenerating {
                    isGenerating = false
                    errorMessage = "Tool execution timed out after 60 seconds"
                }
            }
        }

        // Auto-select response if we are continuing from a multi-model state without selection
        autoSelectResponseIfNeeded()

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: activeModel,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }

    /// Finds the most recent generated or selected image in the conversation for editing context.
    private func findPreviousImageForEditing() -> Data? {
        // Look for the most recent assistant message with an image
        // Prioritize selected responses from multi-model groups
        for message in conversation.messages.reversed() {
            guard message.role == .assistant, message.mediaType == .image else { continue }

            // If this message is part of a response group, only use it if it was selected
            if let groupId = message.responseGroupId {
                if let group = conversation.getResponseGroup(groupId),
                   group.selectedResponseId == message.id
                {
                    return message.effectiveImageData
                }
                // Skip unselected multi-model responses
                continue
            }

            // Single-model image - use it
            return message.effectiveImageData
        }
        return nil
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

        // Check if we have a previous image to edit
        if let previousImage = findPreviousImageForEditing() {
            // Use image editing API for follow-up requests
            logChat("📝 Using image edit API with previous image context", level: .info)

            aiService.editImage(
                prompt: prompt,
                sourceImage: previousImage,
                model: model,
                onComplete: { imageData in
                    Task { @MainActor in
                        handleImageGenerationSuccess(imageData: imageData, messageId: messageId)
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        handleImageGenerationError(error: error, messageId: messageId)
                    }
                }
            )
        } else {
            // No previous image - use generation API
            aiService.generateImage(
                prompt: prompt,
                model: model,
                onComplete: { imageData in
                    Task { @MainActor in
                        handleImageGenerationSuccess(imageData: imageData, messageId: messageId)
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        handleImageGenerationError(error: error, messageId: messageId)
                    }
                }
            )
        }
    }

    private func handleImageGenerationSuccess(imageData: Data, messageId: UUID) {
        // Save image to disk
        var imagePath: String?
        do {
            imagePath = try AttachmentStorage.shared.save(data: imageData, extension: "png")
        } catch {
            logChat(
                "❌ Failed to save generated image: \(error.localizedDescription)", level: .error
            )
        }

        // Update the placeholder message with actual image using the proper method
        conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
            message.content = ""
            if let path = imagePath {
                message.imagePath = path
                message.imageData = nil // Don't store raw data if saved to disk
            } else {
                // Fallback to storing in message if save failed
                message.imageData = imageData
                message.imagePath = nil
            }
        }

        isGenerating = false
    }

    private func handleImageGenerationError(error: Error, messageId _: UUID) {
        isGenerating = false
        errorMessage = ErrorPresenter.userMessage(for: error)
        errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)

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

    /// Generates images from multiple models in parallel for comparison
    private func generateMultiModelImages(prompt: String, models: [String]) {
        // Check if we have a previous image to edit
        let previousImage = findPreviousImageForEditing()

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
        let userMessageId = conversation.messages.first(where: { $0.role == .user })?.id
            ?? conversation.messages.last(where: { $0.role == .user })?.id ?? UUID()
        let responseGroup = ResponseGroup(
            id: responseGroupId,
            userMessageId: userMessageId,
            responses: responseEntries
        )

        // Add response group to conversation
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversationManager.conversations[index].responseGroups.append(responseGroup)
        }

        // Track completion state with actor-isolated counter
        let counter = ChatViewCompletionCounter(total: models.count)

        // Log whether we're using edit or generation
        if previousImage != nil {
            logChat("📝 Using image edit API with previous image context for multi-model", level: .info)
        }

        // Generate/edit images in parallel
        for model in models {
            guard let messageId = messageIds[model] else { continue }

            let onComplete: @Sendable (Data) -> Void = { imageData in
                Task { @MainActor in
                    // Save image to disk
                    var imagePath: String?
                    do {
                        imagePath = try AttachmentStorage.shared.save(data: imageData, extension: "png")
                    } catch {
                        logChat(
                            "❌ Failed to save generated image: \(error.localizedDescription)",
                            level: .error
                        )
                    }

                    // Update the placeholder message with actual image
                    conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                        message.content = ""
                        if let path = imagePath {
                            message.imagePath = path
                            message.imageData = nil
                        } else {
                            message.imageData = imageData
                            message.imagePath = nil
                        }
                    }

                    // Update response group status
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                       let groupIndex = conversationManager.conversations[convIndex].responseGroups.firstIndex(where: { $0.id == responseGroupId }),
                       let entryIndex = conversationManager.conversations[convIndex].responseGroups[groupIndex].responses.firstIndex(where: { $0.id == messageId })
                    {
                        conversationManager.conversations[convIndex].responseGroups[groupIndex].responses[entryIndex].status = .completed
                    }

                    counter.increment()
                    if counter.isComplete {
                        isGenerating = false
                    }
                }
            }

            let onError: @Sendable (Error) -> Void = { error in
                Task { @MainActor in
                    logChat(
                        "❌ Image generation failed for \(model): \(error.localizedDescription)",
                        level: .error,
                        metadata: ["model": model]
                    )

                    // Update response group status to failed
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                       let groupIndex = conversationManager.conversations[convIndex].responseGroups.firstIndex(where: { $0.id == responseGroupId }),
                       let entryIndex = conversationManager.conversations[convIndex].responseGroups[groupIndex].responses.firstIndex(where: { $0.id == messageId })
                    {
                        conversationManager.conversations[convIndex].responseGroups[groupIndex].responses[entryIndex].status = .failed
                    }

                    // Update message with error
                    conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                        message.content = "Image generation failed: \(error.localizedDescription)"
                    }

                    counter.increment()
                    if counter.isComplete {
                        isGenerating = false
                    }
                }
            }

            if let sourceImage = previousImage {
                // Use image editing API
                aiService.editImage(
                    prompt: prompt,
                    sourceImage: sourceImage,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            } else {
                // Use image generation API
                aiService.generateImage(
                    prompt: prompt,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            }
        }
    }

    // MARK: - Multi-Model Message Sending

    private func sendMultiModelMessage(
        userMessageId: UUID,
        models: [String],
        temperature: Double
    ) {
        logChat(
            "🔀 Starting multi-model request",
            level: .info,
            metadata: ["models": models.joined(separator: ", ")]
        )

        // Get updated conversation
        guard let updatedConversation = conversationManager.conversations.first(where: {
            $0.id == conversation.id
        }) else {
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
            conversationManager.addMessage(to: conversation, message: placeholderMessage)
        }

        // Add response group to conversation
        conversationManager.addResponseGroup(to: conversation, group: responseGroup)

        // Prepare messages for API
        var messagesToSend = updatedConversation.getEffectiveHistory()
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Capture necessary values for closures
        let conversationId = conversation.id

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

                    // Update response group status
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }),
                        var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                    {
                        group.updateStatus(for: messageId, status: .completed)
                        conversationManager.conversations[convIndex].updateResponseGroup(group)
                    }

                    logChat(
                        "✅ Model completed in multi-model",
                        level: .info,
                        metadata: ["model": model]
                    )
                }
            },
            onAllComplete: {
                Task { @MainActor in
                    isGenerating = false
                    logChat("🏁 All models completed", level: .info)

                    // Save the conversation
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }) {
                        conversationManager.save(conversationManager.conversations[convIndex])
                    }
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

                    logChat(
                        "❌ Model failed in multi-model",
                        level: .error,
                        metadata: ["model": model, "error": error.localizedDescription]
                    )
                }
            },
            onPendingToolCall: { model, toolId, toolName, arguments in
                let argumentsWrapper = UncheckedSendable(arguments)
                Task { @MainActor in
                    guard let messageId = messageIds[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: {
                              $0.id == conversationId
                          }),
                          let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: {
                              $0.id == messageId
                          })
                    else { return }

                    // Store as pending tool call (will be activated on selection)
                    let anyCodableArgs = argumentsWrapper.value.reduce(into: [String: AnyCodable]()) { result, pair in
                        result[pair.key] = AnyCodable(pair.value)
                    }
                    let pendingCall = MCPToolCall(
                        id: toolId,
                        toolName: toolName,
                        arguments: anyCodableArgs
                    )

                    var pendingCalls = conversationManager.conversations[convIndex].messages[msgIndex].pendingToolCalls ?? []
                    pendingCalls.append(pendingCall)
                    conversationManager.conversations[convIndex].messages[msgIndex].pendingToolCalls = pendingCalls

                    logChat(
                        "🔧 Pending tool call stored",
                        level: .info,
                        metadata: ["model": model, "tool": toolName]
                    )
                }
            },
            onReasoning: nil
        )
    }

    // Helper function to send messages with automatic tool call handling
    // swiftlint:disable:next function_body_length
    private func sendMessageWithToolSupport(
        messages: [Message],
        model: String,
        temperature: Double,
        tools: [[String: Any]]?,
        isInitialRequest _: Bool
    ) {
        let maxToolCallDepth = AgentSettingsStore.shared.settings.maxToolChainDepth
        let mcpManager = MCPServerManager.shared
        let toolsWrapper = UncheckedSendable(tools)

        // Cache the conversation index to avoid repeated lookups in onChunk
        let conversationIndex = conversationManager.conversations.firstIndex(where: {
            $0.id == conversation.id
        })

        aiService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
            conversationId: conversation.id,
            onChunk: { chunk in
                Task { @MainActor in
                    // Batch chunks for better performance during streaming
                    pendingChunks.append(chunk)

                    // Cancel existing batch task and create new one
                    batchUpdateTask?.cancel()
                    batchUpdateTask = Task { @MainActor in
                        // Wait for batch window (100ms for smoother updates with large text)
                        try? await Task.sleep(for: .milliseconds(100))
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
                            conversationManager.conversations[index].messages[
                                conversationManager.conversations[index].messages.count - 1
                            ] = lastMessage!
                        }

                        // Only update UI state if we're currently viewing this conversation
                        if index == conversationIndex {
                            // Clear tool execution indicator when we start receiving actual content
                            if currentToolName != nil {
                                currentToolName = nil
                            }
                        }
                    }
                }
            },
            onComplete: {
                Task { @MainActor in
                    // Flush any pending chunks immediately
                    batchUpdateTask?.cancel()
                    if !pendingChunks.isEmpty {
                        let remainingChunks = pendingChunks.joined()
                        pendingChunks.removeAll()

                        if let index = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversation.id
                        }),
                            var lastMessage = conversationManager.conversations[index].messages.last,
                            lastMessage.role == .assistant
                        {
                            lastMessage.content += remainingChunks
                            conversationManager.conversations[index].messages[
                                conversationManager.conversations[index].messages.count - 1
                            ] = lastMessage
                        }
                    }

                    // Always save conversations
                    if let index = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversation.id
                    }) {
                        conversationManager.save(conversationManager.conversations[index])
                    }

                    // Only update UI state if we're viewing this conversation
                    guard
                        let currentIndex = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversation.id
                        }),
                        currentIndex == conversationIndex
                    else {
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
                        failedMessage = nil // Clear failed message on success
                        toolChainTimeoutTask?.cancel()
                        toolChainTimeoutTask = nil
                    } else {
                        logChat(
                            "⏳ onComplete: Keeping isGenerating TRUE (tool call pending: \(currentToolName ?? "unknown"))",
                            level: .info,
                            metadata: ["toolName": currentToolName ?? "unknown"]
                        )
                    }
                }
            },
            onError: { error in
                Task { @MainActor in
                    // Clean up batching
                    batchUpdateTask?.cancel()
                    pendingChunks.removeAll()

                    logChat(
                        "❌ Stream error",
                        level: .error,
                        metadata: ["error": error.localizedDescription]
                    )

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

                    // Only update UI state if we're viewing this conversation
                    guard
                        let currentIndex = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversation.id
                        }),
                        currentIndex == conversationIndex
                    else {
                        let safeMessage = ErrorPresenter.userMessage(for: error)
                        logChat(
                            "❌ onError for conversation \(conversation.id) (background): \(safeMessage)",
                            level: .error,
                            metadata: ["error": safeMessage]
                        )
                        return
                    }

                    isGenerating = false
                    currentToolName = nil
                    toolCallDepth = 0
                    toolChainTimeoutTask?.cancel()
                    toolChainTimeoutTask = nil
                    errorMessage = ErrorPresenter.userMessage(for: error)
                    errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
                }
            },
            onToolCallRequested: { toolCallId, toolName, arguments in
                let argumentsWrapper = UncheckedSendable(arguments)
                let toolNameCopy = toolName
                Task { @MainActor in
                    // Set currentToolName first thing to prevent race condition with onComplete
                    // checking if tool call is pending. The stream may send [DONE] immediately
                    // after finish_reason: "tool_calls".
                    currentToolName = toolNameCopy
                    let arguments = argumentsWrapper.value
                    // Validate conversation still exists
                    guard conversationManager.conversations.contains(where: { $0.id == conversation.id }) else {
                        logChat(
                            "⚠️ Tool call requested for conversation \(conversation.id) but conversation no longer exists, ignoring",
                            level: .default
                        )
                        currentToolName = nil // Clear since we're not processing
                        return
                    }

                    // Tool call was requested by the LLM
                    logChat(
                        "🔧 Tool call requested: \(toolName) for conversation \(conversation.id)",
                        level: .info,
                        metadata: ["toolName": toolName]
                    )

                    // Check depth limit
                    guard toolCallDepth < maxToolCallDepth else {
                        logChat("⚠️ Max tool call depth reached, stopping", level: .error)
                        isGenerating = false
                        currentToolName = nil
                        return
                    }

                    toolCallDepth += 1

                    // Store the tool call in the last assistant message
                    if let index = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversation.id
                    }),
                        var lastMessage = conversationManager.conversations[index].messages.last,
                        lastMessage.role == .assistant
                    {
                        // Convert arguments to AnyCodable
                        let toolCall = ToolCallHandler.createToolCall(
                            id: toolCallId,
                            toolName: toolName,
                            arguments: arguments
                        )
                        lastMessage.toolCalls = [toolCall]
                        conversationManager.conversations[index].messages[
                            conversationManager.conversations[index].messages.count - 1
                        ] = lastMessage
                        conversationManager.save(conversationManager.conversations[index])
                    }

                    // Execute the tool asynchronously
                    Task {
                        do {
                            logChat(
                                "⚙️ Executing tool: \(toolName)",
                                level: .info,
                                metadata: ["toolName": toolName]
                            )

                            // Route to appropriate tool handler
                            let result: String
                            var citations: [CitationReference]?

                            if aiService.isBuiltInTool(toolName) {
                                // Built-in tool (e.g., web_search, agentic tools) - get citations
                                let (toolResult, toolCitations) = await aiService.executeBuiltInToolWithCitations(
                                    name: toolName,
                                    arguments: argumentsWrapper.value,
                                    conversationId: conversation.id
                                )
                                result = toolResult
                                citations = toolCitations
                            } else {
                                // MCP tool
                                result = try await mcpManager.executeTool(name: toolName, arguments: argumentsWrapper.value)
                            }

                            logChat(
                                "✅ Tool result received (\(result.count) chars)",
                                level: .info,
                                metadata: ["resultLength": "\(result.count)"]
                            )

                            // For web_search, skip creating a visible tool message
                            let isWebSearch = ToolCallHandler.isWebSearchTool(toolName)

                            // Create a tool message with the result
                            await MainActor.run {
                                if !isWebSearch {
                                    // For non-web-search tools, create the tool message
                                    let toolMessage = ToolCallHandler.createToolMessage(
                                        toolCallId: toolCallId,
                                        toolName: toolName,
                                        arguments: argumentsWrapper.value,
                                        result: result
                                    )
                                    conversationManager.addMessage(to: conversation, message: toolMessage)
                                }

                                // Get updated conversation with tool result
                                guard
                                    let updatedConv = conversationManager.conversations.first(where: {
                                        $0.id == conversation.id
                                    })
                                else {
                                    // Only update UI if viewing this conversation
                                    if let currentIndex = conversationManager.conversations.firstIndex(where: {
                                        $0.id == conversation.id
                                    }),
                                        currentIndex == conversationIndex
                                    {
                                        isGenerating = false
                                        currentToolName = nil
                                        toolCallDepth = 0
                                        toolChainTimeoutTask?.cancel()
                                        toolChainTimeoutTask = nil
                                    }
                                    return
                                }

                                // Continue conversation with tool result
                                // Add a new empty assistant message for the model's response
                                let continuationAssistantMessage = ToolCallHandler.createContinuationMessage(
                                    model: model,
                                    citations: isWebSearch ? citations : nil
                                )
                                conversationManager.addMessage(to: updatedConv, message: continuationAssistantMessage)

                                // Get the conversation again with the new assistant message
                                guard
                                    let convWithAssistant = conversationManager.conversations.first(where: {
                                        $0.id == conversation.id
                                    })
                                else {
                                    return
                                }

                                // Build messages for API using ToolCallHandler
                                let continuationMessages = ToolCallHandler.buildContinuationMessages(
                                    conversationMessages: convWithAssistant.messages,
                                    toolCallId: toolCallId,
                                    toolName: toolName,
                                    arguments: argumentsWrapper.value,
                                    result: result,
                                    isWebSearch: isWebSearch,
                                    systemPrompt: buildFullSystemPrompt(for: convWithAssistant)
                                )

                                // Clear tool name since tool execution is complete
                                // The continuation is now a regular API call
                                currentToolName = nil

                                sendMessageWithToolSupport(
                                    messages: continuationMessages,
                                    model: model,
                                    temperature: temperature,
                                    tools: toolsWrapper.value,
                                    isInitialRequest: false
                                )
                            }
                        } catch {
                            logChat(
                                "❌ Tool execution failed: \(error.localizedDescription)",
                                level: .error,
                                metadata: ["error": error.localizedDescription]
                            )
                            await MainActor.run {
                                isGenerating = false
                                currentToolName = nil
                                toolCallDepth = 0
                                toolChainTimeoutTask?.cancel()
                                toolChainTimeoutTask = nil
                                errorMessage = "Tool execution failed: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
        )
    }

    /// Retry the message that came before the specified assistant message
    private func retryLastMessage(beforeMessage: Message) {
        guard !isGenerating else { return }

        // Find the user message that came before this assistant message
        guard
            let assistantIndex = currentConversation.messages.firstIndex(where: {
                $0.id == beforeMessage.id
            }),
            assistantIndex > 0
        else {
            return
        }

        // Find the last user message before this assistant message
        var userMessageIndex: Int?
        for index in (0 ..< assistantIndex).reversed()
            where currentConversation.messages[index].role == .user
        {
            userMessageIndex = index
            break
        }

        guard let userIndex = userMessageIndex else { return }
        let userMessage = currentConversation.messages[userIndex]

        // Remove all messages from the assistant message onwards
        if let convIndex = conversationManager.conversations.firstIndex(where: {
            $0.id == conversation.id
        }) {
            conversationManager.conversations[convIndex].messages.removeSubrange(assistantIndex...)
            conversationManager.save(conversationManager.conversations[convIndex])
        }

        // Resend the user message
        resendMessage(userMessage)
    }

    /// Switch model and retry
    private func switchModelAndRetry(beforeMessage: Message, newModel: String) {
        // Don't update the global conversation model or selected model
        // Just retry with the specified model for this message only
        retryWithModel(beforeMessage: beforeMessage, model: newModel)
    }

    /// Retry with a specific model (without changing conversation's default model)
    private func retryWithModel(beforeMessage: Message, model: String) {
        guard !isGenerating else { return }

        // Find the user message that came before this assistant message
        guard
            let assistantIndex = currentConversation.messages.firstIndex(where: {
                $0.id == beforeMessage.id
            }),
            assistantIndex > 0
        else {
            return
        }

        // Find the last user message before this assistant message
        var userMessageIndex: Int?
        for index in (0 ..< assistantIndex).reversed()
            where currentConversation.messages[index].role == .user
        {
            userMessageIndex = index
            break
        }

        guard let userIndex = userMessageIndex else { return }
        let userMessage = currentConversation.messages[userIndex]

        // Remove all messages from the assistant message onwards
        if let convIndex = conversationManager.conversations.firstIndex(where: {
            $0.id == conversation.id
        }) {
            conversationManager.conversations[convIndex].messages.removeSubrange(assistantIndex...)
            conversationManager.save(conversationManager.conversations[convIndex])
        }

        // Resend the user message with the specified model
        resendMessageWithModel(userMessage, model: model)
    }

    /// Resend a message
    private func resendMessage(_ message: Message) {
        errorMessage = nil
        isGenerating = true

        // Get updated messages
        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        // Check if current model is for image generation
        let modelCapability = aiService.getModelCapability(updatedConversation.model)

        if modelCapability == .imageGeneration {
            // Image generation flow
            generateImage(prompt: message.content, model: updatedConversation.model)
            return
        }

        let currentMessages = updatedConversation.messages

        // Prepend system prompt if configured
        var messagesToSend = currentMessages
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Add empty assistant message with current model
        let assistantMessage = Message(role: .assistant, content: "", model: updatedConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available tools (Tavily + MCP)
        let tools = aiService.getAllAvailableTools()

        // Reset tool call depth
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: updatedConversation.model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }

    /// Resend a message with a specific model (without changing conversation's default model)
    private func resendMessageWithModel(_ message: Message, model: String) {
        errorMessage = nil
        isGenerating = true

        // Get updated messages
        guard
            let updatedConversation = conversationManager.conversations.first(where: {
                $0.id == conversation.id
            })
        else {
            return
        }

        // Check if specified model is for image generation
        let modelCapability = aiService.getModelCapability(model)

        if modelCapability == .imageGeneration {
            // Image generation flow
            generateImage(prompt: message.content, model: model)
            return
        }

        let currentMessages = updatedConversation.messages

        // Prepend system prompt if configured
        var messagesToSend = currentMessages
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Add empty assistant message with the specified model
        let assistantMessage = Message(role: .assistant, content: "", model: model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        // Get available tools (Tavily + MCP)
        let tools = aiService.getAllAvailableTools()

        // Reset tool call depth
        toolCallDepth = 0

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: model,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true
        )
    }

    // MARK: - System Prompt Helpers

    /// Builds the full system prompt including agentic capabilities context.
    private func buildFullSystemPrompt(for conversation: Conversation) -> String? {
        var components: [String] = []

        // Add user's configured system prompt
        if let userPrompt = conversationManager.effectiveSystemPrompt(for: conversation), !userPrompt.isEmpty {
            components.append(userPrompt)
        }

        // Add agentic tools context if available
        if let agenticContext = aiService.getAgenticSystemPromptContext() {
            components.append(agenticContext)
        }

        return components.isEmpty ? nil : components.joined(separator: "\n\n")
    }
}

// MARK: - Pending Approvals Section View

/// Helper view for pending approvals.
/// Reads directly from PermissionService (@Observable) so SwiftUI tracks changes automatically.
private struct PendingApprovalsSectionView: View {
    let conversationId: UUID
    let permissionService: PermissionService?

    /// Read approvals directly in body to establish Observation tracking
    private var approvals: [PendingApproval] {
        permissionService?.pendingApprovals.filter { $0.conversationId == conversationId } ?? []
    }

    var body: some View {
        Group {
            if let permService = permissionService, !approvals.isEmpty {
                VStack(spacing: 12) {
                    ForEach(approvals) { approval in
                        ApprovalRequestView(
                            approval: approval,
                            onApprove: { rememberForSession in
                                permService.approve(approval.id, rememberForSession: rememberForSession)
                            },
                            onDeny: {
                                permService.deny(approval.id)
                            },
                            pendingCount: approvals.count
                        )
                    }
                }
                .padding(.horizontal)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: approvals.count)
    }
}

#Preview {
    MacChatView(conversation: Conversation())
        .environmentObject(ConversationManager())
        .frame(width: 800, height: 600)
}
