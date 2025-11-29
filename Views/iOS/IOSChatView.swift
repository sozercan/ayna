//
//  IOSChatView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import SwiftUI
import UniformTypeIdentifiers

struct IOSChatView: View {
    let conversationId: UUID
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared
    @ObservedObject private var gitHubOAuthService = GitHubOAuthService.shared

    @State private var isFileImporterPresented = false
    @State private var showingSystemPromptSheet = false
    @State private var showModelSelector = false
    @StateObject private var viewModel = IOSChatViewModel.placeholder()

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

    /// Converts visible messages into displayable items, grouping parallel responses
    private var displayableItems: [DisplayableItem] {
        guard let conversation else { return [] }
        var items: [DisplayableItem] = []
        var processedGroupIds: Set<UUID> = []

        let visibleMessages = conversation.messages.filter { message in
            message.role != .system
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

        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 12) {
                            ForEach(displayableItems) { item in
                                switch item {
                                case let .message(message):
                                    IOSMessageView(
                                        message: message,
                                        onRetry: message.role == .assistant ? {
                                            viewModel.retryMessage(beforeMessage: message)
                                        } : nil
                                    )
                                    .id(message.id)
                                    .accessibilityIdentifier(TestIdentifiers.ChatView.messageRow(for: message.id))
                                case let .responseGroup(groupId, responses):
                                    IOSMultiModelResponseView(
                                        responseGroupId: groupId,
                                        responses: responses,
                                        conversation: conversation,
                                        onSelectResponse: { messageId in
                                            let generator = UIImpactFeedbackGenerator(style: .medium)
                                            generator.impactOccurred()
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
                        }
                        .padding()
                    }
                    .accessibilityIdentifier(TestIdentifiers.ChatView.messagesList)
                    .onChange(of: conversation.messages.count) { _ in
                        scrollToBottom(proxy: proxy, conversation: conversation)
                    }
                    .onChange(of: conversation.messages.last?.content) { _ in
                        if viewModel.isGenerating, let lastId = conversation.messages.last?.id {
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
            if openAIService.provider == .githubModels {
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
                showAttachmentButton: true,
                identifierPrefix: "chat.composer",
                onSend: {
                    viewModel.sendMessage()
                },
                onCancel: { viewModel.cancelGeneration() },
                onAttachmentRequested: { isFileImporterPresented = true }
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
                    availableModels: openAIService.usableModels,
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
        } else if let firstAvailable = openAIService.usableModels.first {
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
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndDismiss()
                    }
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
