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

    @State private var isFileImporterPresented = false
    @State private var showingSystemPromptSheet = false
    @State private var showModelSelector = false
    @State private var selectedModels: Set<String> = []
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
                if groupResponses.count > 1 {
                    items.append(.responseGroup(groupId: groupId, responses: groupResponses))
                } else {
                    items.append(.message(message))
                }
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
                                        }
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                        .padding()
                    }
                    .accessibilityIdentifier(TestIdentifiers.ChatView.messagesList)
                    .defaultScrollAnchor(.bottom)
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

            IOSMessageComposer(
                messageText: $viewModel.messageText,
                isGenerating: $viewModel.isGenerating,
                errorMessage: $viewModel.errorMessage,
                attachedFiles: $viewModel.attachedFiles,
                showAttachmentButton: true,
                identifierPrefix: "chat.composer",
                onSend: {
                    if selectedModels.count >= 2 {
                        sendMultiModelMessage()
                    } else {
                        viewModel.sendMessage()
                    }
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
                                if selectedModels.count > 1 {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.blue)
                                    Text("\(selectedModels.count) models")
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
                List {
                    Section {
                        ForEach(openAIService.usableModels, id: \.self) { model in
                            Button(action: {
                                if let conversation {
                                    toggleModelSelection(model, for: conversation)
                                }
                            }) {
                                HStack {
                                    Text(model)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: selectedModels.contains(model) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedModels.contains(model) ? Color.accentColor : Color.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Select models")
                    } footer: {
                        Text("1 model = single response, 2+ models = compare responses side by side")
                    }

                    if selectedModels.count > 1 {
                        Section {
                            Button(role: .destructive) {
                                if let first = selectedModels.first, let conversation {
                                    selectedModels = [first]
                                    conversationManager.updateModel(for: conversation, model: first)
                                }
                            } label: {
                                Label("Clear multi-selection", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .navigationTitle("Models")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showModelSelector = false
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
            if selectedModels.isEmpty, let model = newModel, !model.isEmpty {
                selectedModels = [model]
            }
        }
    }

    private func initializeSelectedModelsIfNeeded() {
        guard selectedModels.isEmpty else { return }

        if let conversation, !conversation.model.isEmpty {
            selectedModels = [conversation.model]
        } else if let firstAvailable = openAIService.usableModels.first {
            // Fallback to first available model if conversation model is empty
            selectedModels = [firstAvailable]
            if let conversation {
                conversationManager.updateModel(for: conversation, model: firstAvailable)
            }
        }
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

        if selectedModels.contains(model) {
            selectedModels.remove(model)
            // Keep at least one model selected
            if selectedModels.isEmpty {
                selectedModels.insert(model)
            } else if selectedModels.count == 1, let remaining = selectedModels.first {
                conversationManager.updateModel(for: conversation, model: remaining)
            }
        } else {
            // Allow up to 4 models
            if selectedModels.count < 4 {
                selectedModels.insert(model)
                if selectedModels.count == 1 {
                    conversationManager.updateModel(for: conversation, model: model)
                }
            }
        }
    }

    // MARK: - Multi-Model Message Sending

    private func sendMultiModelMessage() {
        let text = viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation else { return }

        DiagnosticsLogger.log(
            .chatView,
            level: .info,
            message: "🔀 Starting iOS multi-model request",
            metadata: ["models": selectedModels.map(\.self).joined(separator: ", ")]
        )

        // Create user message
        let userMessage = Message(role: .user, content: text)
        conversationManager.addMessage(to: conversation, message: userMessage)

        viewModel.messageText = ""
        viewModel.isGenerating = true
        viewModel.errorMessage = nil

        // Create response group
        let responseGroupId = UUID()
        var responseGroup = ResponseGroup(id: responseGroupId, userMessageId: userMessage.id)
        let models = Array(selectedModels)

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

        // Add response group
        conversationManager.addResponseGroup(to: conversation, group: responseGroup)

        // Prepare messages
        guard let updatedConversation = self.conversation else { return }
        var messagesToSend = updatedConversation.getEffectiveHistory()
        // Remove placeholders
        messagesToSend = messagesToSend.filter { $0.responseGroupId != responseGroupId }
        if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        let conversationId = conversation.id

        // Send to all models
        openAIService.sendToMultipleModels(
            messages: messagesToSend,
            models: models,
            temperature: updatedConversation.temperature,
            onChunk: { model, chunk in
                Task { @MainActor in
                    guard let messageId = messageIds[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                          let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
                    else { return }

                    conversationManager.conversations[convIndex].messages[msgIndex].content += chunk
                }
            },
            onModelComplete: { model in
                Task { @MainActor in
                    guard let messageId = messageIds[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                          var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                    else { return }

                    group.updateStatus(for: messageId, status: .completed)
                    conversationManager.conversations[convIndex].updateResponseGroup(group)
                }
            },
            onAllComplete: {
                Task { @MainActor in
                    viewModel.isGenerating = false
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) {
                        conversationManager.save(conversationManager.conversations[convIndex])
                    }
                }
            },
            onError: { model, error in
                Task { @MainActor in
                    guard let messageId = messageIds[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
                          var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                    else { return }

                    group.updateStatus(for: messageId, status: .failed)
                    conversationManager.conversations[convIndex].updateResponseGroup(group)

                    DiagnosticsLogger.log(
                        .chatView,
                        level: .error,
                        message: "❌ Model failed in iOS multi-model",
                        metadata: ["model": model, "error": error.localizedDescription]
                    )
                }
            },
            onPendingToolCall: nil,
            onReasoning: nil
        )
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
