// swiftformat:options --ifdef no-indent
#if os(macOS)

import AppKit
import OSLog
import SwiftUI

struct MacChatView: View {
    let conversation: Conversation

    init(conversation: Conversation) {
        self.conversation = conversation
        _selectedModel = State(initialValue: conversation.model)
        if conversation.multiModelEnabled, !conversation.activeModels.isEmpty {
            _selectedModels = State(initialValue: Set(conversation.activeModels))
        } else if !conversation.model.isEmpty {
            _selectedModels = State(initialValue: [conversation.model])
        }
    }

    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject var aiService = AIService.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared

    @State var messageText = ""
    @State var isGenerating = false
    @State var errorMessage: String?
    @State var errorRecoverySuggestion: String?
    @State var failedMessage: String?
    @State var selectedModel: String
    @State var attachedFiles: [URL] = []
    @State var pastedImages: [PastedImage] = []
    @State var pasteImportSessionID = UUID()
    @State var isImportingPastedImages = false
    @State var pendingFileDropCount = 0
    @State var failedSendPayload: FailedSendPayload?
    @State var toolCallDepth = 0
    @State var currentToolName: String?
    @State var isComposerFocused = true
    @State var toolChainTimeoutTask: Task<Void, Never>?
    @State var toolChainTimeoutContext: ToolChainTimeoutContext?
    @State var sendPreparationTask: Task<Void, Never>?
    @State var sendPreparationID: UUID?
    @State var pendingAutoSendClaim: MacPendingAutoSendClaim?
    @State var activeAssistantMessageID: UUID?
    @State var activeMultiModelResponseGroupID: UUID?
    @State var toolChainCoordinator = ToolChainCoordinator()
    @State var toolCallRequestRoundCoordinator = ToolCallRequestRoundCoordinator<ToolExecutionResult>()
    @State var imageGenerationCoordinator = ImageGenerationCoordinator()
    @State var multiModelReasoningBuffer = MultiModelStreamingBuffer()
    @State private var showingSystemPromptSheet = false

    @State var selectedModels: Set<String> = []
    @State private var showModelSelector = false
    @State private var isToolSectionExpanded = false

    var selectedCapabilityType: AIService.ModelCapability? {
        guard let firstSelected = selectedModels.first else { return nil }
        return aiService.getModelCapability(firstSelected)
    }

    @State private var showAppContentPicker = false
    @State var attachedAppContent: AppContent?

    @State var pendingChunks: [String] = []
    @State var batchUpdateTask: Task<Void, Never>?
    @State private var cachedConversationIndex: Int?
    @State private var cachedDisplayableItems: [ChatTranscriptItem] = []

    var currentConversation: Conversation {
        if let index = getConversationIndex() {
            return conversationManager.conversations[index]
        }
        return conversation
    }

    func getConversationIndex() -> Int? {
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

    func logChat(
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

    private func updateTranscriptPlan() {
        cachedDisplayableItems = ChatTranscriptPlan(
            conversation: currentConversation,
            isGenerating: isGenerating
        ).items
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                ChatMessageList(
                    displayableItems: cachedDisplayableItems,
                    conversation: currentConversation,
                    isGenerating: isGenerating,
                    isToolSectionExpanded: $isToolSectionExpanded,
                    onRetryMessage: { message in
                        retryLastMessage(beforeMessage: message)
                    },
                    onSwitchModelAndRetry: { message, newModel in
                        switchModelAndRetry(beforeMessage: message, newModel: newModel)
                    },
                    onSelectResponse: { groupId, messageId in
                        conversationManager.selectResponse(
                            in: currentConversation,
                            groupId: groupId,
                            messageId: messageId
                        )
                    },
                    onEditMessage: { message, newContent in
                        editMessageAndResend(message, newContent: newContent)
                    },
                    onAppearAction: {
                        updateTranscriptPlan()
                        syncSelectedModelWithConversation()
                    },
                    onConversationChange: {
                        updateTranscriptPlan()
                        syncSelectedModelWithConversation()
                    },
                    onMessagesChange: {
                        updateTranscriptPlan()
                    },
                    onModelChange: {
                        updateTranscriptPlan()
                        syncSelectedModelWithConversation()
                    },
                    onGeneratingChange: {
                        updateTranscriptPlan()
                    }
                )

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

                if let toolName = currentToolName {
                    ToolExecutionIndicator(toolName: toolName)
                }

                TaskListView(taskManager: ConversationTaskManager.shared, conversationId: conversation.id)
                    .padding(.horizontal, Spacing.contentPadding)

                PendingApprovalsSectionView(
                    conversationId: conversation.id,
                    permissionService: aiService.permissionService
                )

                ChatInputArea(
                    messageText: $messageText,
                    isComposerFocused: $isComposerFocused,
                    attachedFiles: $attachedFiles,
                    pastedImages: $pastedImages,
                    pasteImportSessionID: $pasteImportSessionID,
                    isImportingPastedImages: $isImportingPastedImages,
                    attachedAppContent: $attachedAppContent,
                    selectedModels: $selectedModels,
                    selectedModel: $selectedModel,
                    showModelSelector: $showModelSelector,
                    isToolSectionExpanded: $isToolSectionExpanded,
                    isGenerating: isGenerating,
                    composerModelLabel: composerModelLabel,
                    onSendMessage: { beginSendMessage() },
                    onAttachFile: attachFile,
                    onShowAppContentPicker: { showAppContentPicker = true },
                    onToggleModelSelection: toggleModelSelection,
                    onClearMultiSelection: {
                        selectedModels.removeAll()
                        selectedModel = aiService.selectedModel
                    },
                    onRemoveFile: removeFile,
                    onRemoveAppContent: { attachedAppContent = nil },
                    hasPendingFileDrops: pendingFileDropCount > 0
                )
            }
        }
        .chatAttachmentDropTarget(
            attachedFiles: $attachedFiles,
            pastedImages: $pastedImages,
            importSessionID: $pasteImportSessionID,
            pendingDropCount: $pendingFileDropCount
        )
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
                    Button {
                        Task { await exportConversation(format: .markdown) }
                    } label: {
                        Label("Export as Markdown", systemImage: "doc.text")
                    }
                    Button {
                        Task { await exportConversation(format: .pdf) }
                    } label: {
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
            consumePendingSendIfNeeded()
        }
        .onChange(of: conversationManager.pendingSendConversationIds) { _, _ in
            consumePendingSendIfNeeded()
        }
        .onDisappear {
            cancelOwnedGenerationForLifecycle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pendingApprovalsChanged)) { notification in
            if let notificationConversationId = notification.userInfo?["conversationId"] as? UUID,
               notificationConversationId != conversation.id
            {
                return
            }
            syncToolChainTimeoutForPendingApprovals()
        }
    }
}

#Preview {
    MacChatView(conversation: Conversation())
        .environmentObject(ConversationManager())
        .frame(width: 800, height: 600)
}
#endif
