// swiftformat:options --ifdef no-indent
#if os(iOS)

import os.log
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct IOSChatView: View {
    let conversationId: UUID
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var aiService = AIService.shared

    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingSystemPromptSheet = false
    @State private var showModelSelector = false
    @StateObject private var viewModel = IOSChatViewModel.placeholder()

    @State private var showScrollToBottom = false
    @State private var followsLatest = true
    @State private var restoredPosition = ScrollPosition()

    @State private var cachedDisplayableItems: [ChatTranscriptItem] = []

    private var conversation: Conversation? {
        conversationManager.conversations.first { $0.id == conversationId }
    }

    private func updateDisplayableItems() {
        guard let conversation else {
            cachedDisplayableItems = []
            return
        }

        cachedDisplayableItems = ChatTranscriptPlan(
            conversation: conversation,
            isGenerating: viewModel.isGenerating
        ).items
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: Spacing.messageSpacing) {
                                ForEach(cachedDisplayableItems) { item in
                                    switch item {
                                    case let .message(transcriptMessage):
                                        let message = transcriptMessage.message
                                        IOSMessageView(
                                            message: message,
                                            displayKind: transcriptMessage.displayKind,
                                            isGenerating: viewModel.isGenerating
                                                && message.id == conversation.messages.last?.id,
                                            onRetry: message.role == .assistant && !viewModel.isGenerating ? {
                                                viewModel.retryMessage(beforeMessage: message)
                                            } : nil,
                                            onSwitchModel: message.role == .assistant && !viewModel.isGenerating ? { newModel in
                                                viewModel.switchModelAndRetry(beforeMessage: message, newModel: newModel)
                                            } : nil,
                                            onEdit: message.role == .user && !viewModel.isGenerating ? { newContent in
                                                viewModel.editMessageAndResend(
                                                    message,
                                                    newContent: newContent
                                                )
                                            } : nil,
                                            availableModels: aiService.usableModels
                                        )
                                        .id(message.id)
                                        .accessibilityIdentifier(TestIdentifiers.ChatView.messageRow(for: message.id))
                                    case let .responseGroup(group):
                                        IOSMultiModelResponseView(
                                            responseGroupId: group.id,
                                            responses: group.messages,
                                            conversation: conversation,
                                            onSelectResponse: { messageId in
                                                HapticEngine.selection()
                                                conversationManager.selectResponse(
                                                    in: conversation,
                                                    groupId: group.id,
                                                    messageId: messageId
                                                )
                                            },
                                            onRetry: viewModel.isGenerating ? nil : { message in
                                                viewModel.retryMessage(beforeMessage: message)
                                            },
                                            defaultCandidateId: group.defaultCandidateId
                                        )
                                        .id(item.id)
                                    }
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom")
                            }
                            .padding()
                        }
                        .scrollPosition($restoredPosition)
                        .followsStreamingContent($followsLatest, isAwayFromEnd: $showScrollToBottom)
                        .accessibilityIdentifier(TestIdentifiers.ChatView.messagesList)

                        ScrollToBottomButton(
                            isVisible: showScrollToBottom && !viewModel.isGenerating,
                            unreadCount: 0
                        ) {
                            followsLatest = true
                            withAnimation(Motion.springStandard) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .padding(.bottom, Spacing.md)
                    }
                    .onChange(of: conversation.messages.count) {
                        updateDisplayableItems()
                        if followsLatest {
                            scrollToBottom(proxy: proxy, conversation: conversation)
                        }
                    }
                    .onChange(of: conversation.updatedAt) {
                        updateDisplayableItems()
                    }
                    .onChange(of: conversation.messages.last?.content) {
                        updateDisplayableItems()
                        if viewModel.isGenerating, followsLatest, let lastId = conversation.messages.last?.id {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: conversation.messages.last?.reasoning) {
                        updateDisplayableItems()
                        if viewModel.isGenerating, followsLatest, let lastId = conversation.messages.last?.id {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.isGenerating) { _, newValue in
                        updateDisplayableItems()
                        if newValue, let lastId = conversation.messages.last?.id {
                            followsLatest = true
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
                        let readingPosition = TranscriptReadingPosition.take(for: conversationId)
                        if readingPosition != nil {
                            followsLatest = false
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            if let readingPosition {
                                restoredPosition.scrollTo(y: readingPosition)
                            } else if let lastId = conversation.messages.last?.id {
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
                attachedImages: $viewModel.attachedImages,
                pastedImages: $viewModel.pastedImages,
                pasteImportSessionID: $viewModel.pasteImportSessionID,
                isImportingPastedImages: $viewModel.isImportingPastedImages,
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
            initializeSelectedModelsIfNeeded()
        }
        .onDisappear {
            viewModel.cancelOwnedOperations()
        }
        .onChange(of: conversation?.model) { _, newModel in
            if viewModel.selectedModels.isEmpty, let model = newModel, !model.isEmpty {
                viewModel.selectedModels = [model]
            }
        }
    }

    private func initializeSelectedModelsIfNeeded() {
        guard let conversation else { return }

        if conversation.multiModelEnabled, !conversation.activeModels.isEmpty {
            viewModel.selectedModels = Set(conversation.activeModels)
            return
        }

        guard viewModel.selectedModels.isEmpty else { return }

        if !conversation.model.isEmpty {
            viewModel.selectedModels = [conversation.model]
        } else if let firstAvailable = aiService.usableModels.first {
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

    private func scrollToBottom(proxy: ScrollViewProxy, conversation: Conversation) {
        if let lastId = conversation.messages.last?.id {
            withAnimation {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}

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
#endif
