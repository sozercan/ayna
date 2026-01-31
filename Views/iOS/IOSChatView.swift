//
//  IOSChatView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct IOSChatView: View {
    let conversationId: UUID
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var aiService = AIService.shared
    @ObservedObject private var gitHubOAuthService = GitHubOAuthService.shared

    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingSystemPromptSheet = false
    @State private var showModelSelector = false
    @StateObject private var viewModel = IOSChatViewModel.placeholder()

    /// Scroll-to-bottom button visibility
    @State private var showScrollToBottom = false
    @State private var isNearBottom = true

    /// Performance: Cached displayable items to avoid O(n) computation on every render
    @State private var cachedDisplayableItems: [DisplayableItem] = []

    /// Get the conversation from the environment's conversation manager
    private var conversation: Conversation? {
        conversationManager.conversations.first { $0.id == conversationId }
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
        guard let conversation else {
            cachedDisplayableItems = []
            return
        }

        var items: [DisplayableItem] = []
        var processedGroupIds: Set<UUID> = []

        let visibleMessages = conversation.messages.filter { message in
            // Hide system messages entirely
            if message.role == .system {
                return false
            }

            // Always show tool messages when they have content
            if message.role == .tool {
                return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

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
                return message.id == conversation.messages.last?.id && viewModel.isGenerating
            }

            return !message.content.isEmpty || message.imageData != nil || message.imagePath != nil || message.mediaType == .image
        }

        for message in visibleMessages {
            if let groupId = message.responseGroupId {
                guard !processedGroupIds.contains(groupId) else { continue }
                processedGroupIds.insert(groupId)

                let groupResponses = visibleMessages.filter { $0.responseGroupId == groupId }
                // Always show response groups as multi-model view to prevent UI jumping
                items.append(.responseGroup(groupId: groupId, responses: groupResponses))
            } else {
                items.append(.message(message))
            }
        }

        cachedDisplayableItems = items
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 12) {
                                ForEach(cachedDisplayableItems) { item in
                                    switch item {
                                    case let .message(message):
                                        IOSMessageView(
                                            message: message,
                                            onRetry: message.role == .assistant ? {
                                                viewModel.retryMessage(beforeMessage: message)
                                            } : nil,
                                            onSwitchModel: message.role == .assistant ? { newModel in
                                                viewModel.switchModelAndRetry(beforeMessage: message, newModel: newModel)
                                            } : nil,
                                            availableModels: aiService.usableModels
                                        )
                                        .id(message.id)
                                        .accessibilityIdentifier(TestIdentifiers.ChatView.messageRow(for: message.id))
                                    case let .responseGroup(groupId, responses):
                                        IOSMultiModelResponseView(
                                            responseGroupId: groupId,
                                            responses: responses,
                                            conversation: conversation,
                                            onSelectResponse: { messageId in
                                                // Use centralized haptic engine
                                                HapticEngine.selection()
                                                conversationManager.selectResponse(
                                                    in: conversation,
                                                    groupId: groupId,
                                                    messageId: messageId
                                                )
                                            },
                                            onRetry: { message in
                                                viewModel.retryMessage(beforeMessage: message)
                                            },
                                            defaultCandidateId: defaultCandidateId(for: responses, in: conversation)
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
                            .padding()
                        }
                        .accessibilityIdentifier(TestIdentifiers.ChatView.messagesList)

                        // Scroll-to-bottom floating button
                        ScrollToBottomButton(
                            isVisible: showScrollToBottom && !viewModel.isGenerating,
                            unreadCount: 0
                        ) {
                            withAnimation(Motion.springStandard) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .padding(.bottom, Spacing.md)
                    }
                    .onChange(of: conversation.messages.count) {
                        updateDisplayableItems()
                        scrollToBottom(proxy: proxy, conversation: conversation)
                    }
                    .onChange(of: conversation.messages.last?.content) {
                        // Only scroll during generation - use transaction to disable animations
                        // This prevents janky scrolling during rapid streaming updates
                        if viewModel.isGenerating, let lastId = conversation.messages.last?.id {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.isGenerating) { _, newValue in
                        updateDisplayableItems()
                        // Scroll to bottom when generation starts
                        if newValue, let lastId = conversation.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        DiagnosticsLogger.log(
                            .chatView,
                            level: .info,
                            message: "📱 IOSChatView appeared",
                            metadata: ["conversationId": conversationId.uuidString]
                        )
                        updateDisplayableItems()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            if let lastId = conversation.messages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Conversation not found", systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier(TestIdentifiers.ChatView.emptyState)
            }

            // Rate Limit Warning Banner (GitHub Models only)
            if aiService.provider == .githubModels {
                RateLimitWarningBanner(
                    rateLimitInfo: gitHubOAuthService.rateLimitInfo,
                    retryAfterDate: gitHubOAuthService.retryAfterDate
                )
                .padding(.horizontal)
            }

            IOSMessageComposer(
                messageText: $viewModel.messageText,
                isGenerating: $viewModel.isGenerating,
                errorMessage: $viewModel.errorMessage,
                attachedFiles: $viewModel.attachedFiles,
                attachedImages: $viewModel.attachedImages,
                errorRecoverySuggestion: viewModel.errorRecoverySuggestion,
                onRetry: viewModel.failedMessage != nil ? { viewModel.retryFailedMessage() } : nil,
                showAttachmentButton: true,
                identifierPrefix: "chat.composer",
                onSend: {
                    viewModel.sendMessage()
                },
                onCancel: { viewModel.cancelGeneration() },
                onDismissError: { viewModel.dismissError() },
                onFileAttachmentRequested: { isFileImporterPresented = true },
                onPhotoAttachmentRequested: { isPhotoPickerPresented = true }
            )
        }
        .navigationTitle(conversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            viewModel.handleFileImport(result)
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: 5,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await viewModel.handlePhotoSelection(newItems)
                selectedPhotoItems = []
            }
        }
        .toolbar {
            if let conversation {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(conversation.title)
                            .font(.headline)

                        Button(action: { showModelSelector = true }) {
                            HStack(spacing: 4) {
                                if viewModel.selectedModels.count > 1 {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.blue)
                                    Text("\(viewModel.selectedModels.count) models")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                } else {
                                    Text(conversation.model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(TestIdentifiers.ChatView.modelSelector)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSystemPromptSheet = true
                    } label: {
                        Image(systemName: "text.bubble")
                    }
                    .accessibilityIdentifier("chat.systemPrompt.button")
                }
            }
        }
        .sheet(isPresented: $showModelSelector) {
            NavigationStack {
                IOSMultiModelSelector(
                    selectedModels: $viewModel.selectedModels,
                    availableModels: aiService.usableModels,
                    maxSelection: 4
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showModelSelector = false
                            if let conversation {
                                updateConversationMultiModelState()
                                // If single model selected, update conversation model
                                if viewModel.selectedModels.count == 1, let first = viewModel.selectedModels.first {
                                    conversationManager.updateModel(for: conversation, model: first)
                                }
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingSystemPromptSheet) {
            if let conversation {
                IOSConversationSystemPromptSheet(conversation: conversation)
                    .environmentObject(conversationManager)
            }
        }
        .onAppear {
            viewModel.configure(with: conversationManager, conversationId: conversationId)
            // Initialize selectedModels with current conversation model
            initializeSelectedModelsIfNeeded()
        }
        .onChange(of: conversation?.model) { _, newModel in
            // Re-initialize if the conversation model changes and selectedModels is empty
            if viewModel.selectedModels.isEmpty, let model = newModel, !model.isEmpty {
                viewModel.selectedModels = [model]
            }
        }
    }

    private func initializeSelectedModelsIfNeeded() {
        guard let conversation else { return }

        // If conversation has multi-model enabled, restore those selections
        if conversation.multiModelEnabled, !conversation.activeModels.isEmpty {
            viewModel.selectedModels = Set(conversation.activeModels)
            return
        }

        guard viewModel.selectedModels.isEmpty else { return }

        if !conversation.model.isEmpty {
            viewModel.selectedModels = [conversation.model]
        } else if let firstAvailable = aiService.usableModels.first {
            // Fallback to first available model if conversation model is empty
            viewModel.selectedModels = [firstAvailable]
            conversationManager.updateModel(for: conversation, model: firstAvailable)
        }
    }

    private func updateConversationMultiModelState() {
        guard let conversation else { return }
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            var updatedConversation = conversationManager.conversations[index]
            updatedConversation.activeModels = Array(viewModel.selectedModels)
            updatedConversation.multiModelEnabled = viewModel.selectedModels.count > 1
            conversationManager.updateConversation(updatedConversation)
        }
    }

    private func autoSelectResponseIfNeeded() {
        guard let conversation else { return }
        guard let lastMessage = conversation.messages.last,
              let groupId = lastMessage.responseGroupId,
              let group = conversation.getResponseGroup(groupId),
              group.selectedResponseId == nil
        else {
            return
        }

        let responses = conversation.messages.filter { $0.responseGroupId == groupId }
        var candidateId: UUID?

        // 1. Primary: conversation.model
        if let match = responses.first(where: { $0.model == conversation.model }) {
            candidateId = match.id
        }
        // 2. Fallback: First model
        else if let first = responses.first {
            candidateId = first.id
        }

        if let id = candidateId {
            DiagnosticsLogger.log(
                .chatView,
                level: .info,
                message: "🤖 Auto-selecting response before sending new message",
                metadata: ["messageId": id.uuidString]
            )
            conversationManager.selectResponse(in: conversation, groupId: groupId, messageId: id)
        }
    }

    /// Calculates which response would be auto-selected if user continues without choosing (for visual cue)
    private func defaultCandidateId(for responses: [Message], in conversation: Conversation) -> UUID? {
        // 1. Primary: conversation.model
        if let match = responses.first(where: { $0.model == conversation.model }) {
            return match.id
        }
        // 2. Fallback: First response
        return responses.first?.id
    }

    private func scrollToBottom(proxy: ScrollViewProxy, conversation: Conversation) {
        if let lastId = conversation.messages.last?.id {
            withAnimation {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    private func toggleModelSelection(_ model: String, for conversation: Conversation) {
        // Use centralized haptic engine
        HapticEngine.selection()

        let multiModelEnabled = AppPreferences.multiModelSelectionEnabled

        if !multiModelEnabled {
            // Single-select mode: always replace selection
            viewModel.selectedModels = [model]
            conversationManager.updateModel(for: conversation, model: model)
            updateConversationMultiModelState()
            return
        }

        // Multi-select mode
        if viewModel.selectedModels.contains(model) {
            viewModel.selectedModels.remove(model)
            // Keep at least one model selected
            if viewModel.selectedModels.isEmpty {
                viewModel.selectedModels.insert(model)
            } else if viewModel.selectedModels.count == 1, let remaining = viewModel.selectedModels.first {
                conversationManager.updateModel(for: conversation, model: remaining)
            }
        } else {
            // Allow up to 4 models
            if viewModel.selectedModels.count < 4 {
                viewModel.selectedModels.insert(model)
                if viewModel.selectedModels.count == 1 {
                    conversationManager.updateModel(for: conversation, model: model)
                }
            }
        }
        updateConversationMultiModelState()
    }

    // MARK: - Multi-Model Message Sending

    private func sendMultiModelMessage() {
        // Delegated to ViewModel
        viewModel.sendMessage()
    }
}

// MARK: - Conversation System Prompt Sheet

struct IOSConversationSystemPromptSheet: View {
    let conversation: Conversation
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversationManager: ConversationManager

    @State private var selectedMode: SystemPromptModeSelection = .inheritGlobal
    @State private var customPrompt: String = ""

    enum SystemPromptModeSelection: String, CaseIterable {
        case inheritGlobal = "Global"
        case custom = "Custom"
        case disabled = "None"
    }

    init(conversation: Conversation) {
        self.conversation = conversation

        // Initialize state from conversation
        switch conversation.systemPromptMode {
        case .inheritGlobal:
            _selectedMode = State(initialValue: .inheritGlobal)
            _customPrompt = State(initialValue: "")
        case let .custom(prompt):
            _selectedMode = State(initialValue: .custom)
            _customPrompt = State(initialValue: prompt)
        case .disabled:
            _selectedMode = State(initialValue: .disabled)
            _customPrompt = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(SystemPromptModeSelection.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("chat.systemPromptMode.picker")
                } header: {
                    Text("System Prompt Mode")
                }

                if selectedMode == .inheritGlobal {
                    Section {
                        let globalPrompt = AppPreferences.globalSystemPrompt
                        if globalPrompt.isEmpty {
                            Text("No global prompt set")
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            Text(globalPrompt)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Current Global Prompt")
                    }
                } else if selectedMode == .custom {
                    Section {
                        TextEditor(text: $customPrompt)
                            .frame(minHeight: 120)
                            .accessibilityIdentifier("chat.systemPrompt.customEditor")
                    } header: {
                        Text("Custom Prompt")
                    }
                } else {
                    Section {
                        Text("No system prompt will be used for this conversation.")
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }
            }
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("chat.systemPrompt.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .accessibilityIdentifier("chat.systemPrompt.saveButton")
                }
            }
        }
    }

    private func saveAndDismiss() {
        let mode: SystemPromptMode = switch selectedMode {
        case .inheritGlobal:
            .inheritGlobal
        case .custom:
            .custom(customPrompt)
        case .disabled:
            .disabled
        }

        conversationManager.updateSystemPromptMode(for: conversation, mode: mode)
        dismiss()
    }
}
