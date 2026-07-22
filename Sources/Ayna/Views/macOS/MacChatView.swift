// swiftlint:disable file_length
#if os(macOS)
//
//  MacChatView.swift
//  ayna
//
//  Created on 11/2/25.
//

import AppKit
import OSLog
import SwiftUI

// ChatView currently wraps the full chat experience (history, composer, attachments, streaming, MCP
// tooling). Splitting it without a broader refactor would scatter tightly coupled state, so we allow
// the larger body here until the view hierarchy is modularized.

// swiftlint:disable:next type_body_length
struct MacChatView: View {
    private struct PendingAutoSendClaim {
        let conversationID: UUID
        let prompt: String
    }

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
    @ObservedObject var aiService = AIService.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared

    @State private var messageText = ""
    @State var isGenerating = false
    @State var errorMessage: String?
    @State var errorRecoverySuggestion: String?
    @State private var failedMessage: String?
    @State private var selectedModel: String
    @State private var attachedFiles: [URL] = []
    @State var toolCallDepth = 0
    @State private var currentToolName: String?
    @State private var isComposerFocused = true
    @State private var toolChainTimeoutTask: Task<Void, Never>?
        @State private var sendPreparationTask: Task<Void, Never>?
        @State private var sendPreparationID: UUID?
        @State private var pendingAutoSendClaim: PendingAutoSendClaim?
        @State var activeAssistantMessageID: UUID?
        @State var activeMultiModelResponseGroupID: UUID?
        @State var toolChainCoordinator = ToolChainCoordinator()
        @State private var toolCallRequestRoundCoordinator = ToolCallRequestRoundCoordinator<ToolExecutionResult>()
    @State var imageGenerationCoordinator = ImageGenerationCoordinator()
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
    @State private var pendingChunks: [String] = []
    @State private var batchUpdateTask: Task<Void, Never>?
    @State private var visibleMessages: [Message] = []
    @State private var cachedConversationIndex: Int?
    @State private var cachedDisplayableItems: [DisplayableItem] = []
    /// Cache the current conversation to avoid repeated lookups
    var currentConversation: Conversation {
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

    /// Helper to filter visible messages
    private func updateVisibleMessages() {
        visibleMessages = currentConversation.messages.filter { message in
            // Hide system messages entirely
            if message.role == .system {
                return false
            }

            // Always show tool messages when they have content (tool replies are the "first" assistant response)
            if message.role == .tool {
                    let isWebSearchResult = message.toolCalls?.contains(where: {
                        $0.toolName == WebSearchCoordinator.toolName
                    }) == true
                    return !isWebSearchResult &&
                        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        let edited = conversationManager.editMessage(
                            in: currentConversation,
                            messageId: message.id,
                            newContent: newContent
                        )
                        if edited {
                            resendMessage(message)
                        }
                    },
                    onAppearAction: {
                        updateVisibleMessages()
                        syncSelectedModelWithConversation()
                    },
                    onConversationChange: {
                        updateVisibleMessages()
                        syncSelectedModelWithConversation()
                    },
                    onMessagesChange: {
                        updateVisibleMessages()
                    },
                    onModelChange: {
                        syncSelectedModelWithConversation()
                    },
                    onGeneratingChange: {
                        updateVisibleMessages()
                    }
                )

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
                ChatInputArea(
                    messageText: $messageText,
                    isComposerFocused: $isComposerFocused,
                    attachedFiles: $attachedFiles,
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
                    onRemoveAppContent: { attachedAppContent = nil }
                )
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
        .onDisappear {
                cancelOwnedGenerationForLifecycle()
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
        guard pendingAutoSendClaim == nil,
              let index = getConversationIndex(),
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

        // Clear and persist the prompt while this view owns the claim. Lifecycle cancellation
        // restores it until the user message is actually committed.
        conversationManager.conversations[index].pendingAutoSendPrompt = nil
        conversationManager.saveImmediately(conversationManager.conversations[index])
        pendingAutoSendClaim = PendingAutoSendClaim(
            conversationID: conversationManager.conversations[index].id,
            prompt: prompt
        )

        // Set the message text and send after the view has had one layout turn.
        messageText = prompt
        beginSendMessage(delay: .milliseconds(100))
    }

    /// Sends the last user message in the conversation (used for Work with Apps)
    private func sendPendingUserMessage() {
            guard currentConversation.messages.contains(where: { $0.role == .user }) else {
            return
        }

        isGenerating = true

        // Build messages for API using the same pattern as sendMessage
            var messagesToSend = currentConversation.getEffectiveHistory()
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
                isInitialRequest: true,
                assistantMessageID: assistantMessage.id
        )
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
            beginSendMessage()
    }

    /// Dismiss the current error without retrying
    private func dismissError() {
        failedMessage = nil
        errorMessage = nil
        errorRecoverySuggestion = nil
    }

        private func cancelOwnedGenerationForLifecycle() {
            sendPreparationTask?.cancel()
            sendPreparationTask = nil
            sendPreparationID = nil
            restorePendingAutoSendClaimIfNeeded()
            toolChainCoordinator.cancelCurrentOperation {
                finalizePersistedTextGeneration()
            }
            imageGenerationCoordinator.cancelCurrentOperation()
            toolChainTimeoutTask?.cancel()
            toolChainTimeoutTask = nil
            activeAssistantMessageID = nil
            activeMultiModelResponseGroupID = nil
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
            }

        private func finalizePersistedTextGeneration() {
            batchUpdateTask?.cancel()
            batchUpdateTask = nil
            let pendingText = pendingChunks.joined()
                pendingChunks.removeAll()

            let assistantMessageID = activeAssistantMessageID
            let responseGroupID = activeMultiModelResponseGroupID
            guard assistantMessageID != nil || responseGroupID != nil || !pendingText.isEmpty,
                  let conversationIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id })
            else {
                activeMultiModelResponseGroupID = nil
                return
            }

            let result = ChatGenerationFinalizer.finalize(
                conversation: &conversationManager.conversations[conversationIndex],
                activeAssistantMessageID: assistantMessageID,
                pendingText: pendingText,
                activeResponseGroupID: responseGroupID
            )
            conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            activeMultiModelResponseGroupID = nil

            if result.appendedCharacterCount > 0 {
                    logChat(
                    "💾 Flushed \(result.appendedCharacterCount) chars before cancellation",
                        level: .info,
                    metadata: ["chunkLength": "\(result.appendedCharacterCount)"]
                    )
                }
                logChat("💾 Saved conversation after cancellation", level: .info)
            }

        private func abortOwnedTextGeneration(
            operationID: ToolChainCoordinator.OperationID,
            conversationID: UUID
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationID) else { return }
            finalizePersistedTextGeneration()
            toolChainTimeoutTask?.cancel()
            toolChainTimeoutTask = nil
            toolChainCoordinator.cancelCurrentOperation()
            activeAssistantMessageID = nil
            activeMultiModelResponseGroupID = nil
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
        }

        private func armToolChainTimeout(
            operationID: ToolChainCoordinator.OperationID,
            assistantMessageID: UUID,
            conversationID: UUID
        ) {
            toolChainTimeoutTask?.cancel()
            let coordinator = toolChainCoordinator
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled,
                      coordinator.owns(operationID, conversationID: conversationID),
                      activeAssistantMessageID == assistantMessageID
                else {
                    return
                }

                logChat("⏰ Tool execution timeout after 60s, cancelling owned work", level: .error)
                abortOwnedTextGeneration(operationID: operationID, conversationID: conversationID)
                errorMessage = "Tool execution timed out after 60 seconds"
            }
            toolChainTimeoutTask = timeoutTask
            coordinator.track(timeoutTask, for: operationID)
        }

        // MARK: - Message Sending

        private func beginSendMessage(delay: Duration? = nil) {
            if isGenerating || sendPreparationTask != nil {
                logChat("🛑 Stop button clicked, cancelling...", level: .info)
                cancelOwnedGenerationForLifecycle()
            logChat("✅ isGenerating set to FALSE after stop", level: .info)
            isComposerFocused = true
            return
        }

        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isComposerFocused = true
            return
        }

            let preparationID = UUID()
            sendPreparationID = preparationID
            isGenerating = true
            let task = Task { @MainActor in
                if let delay {
                    try? await Task.sleep(for: delay)
                }
                guard !Task.isCancelled, sendPreparationID == preparationID else { return }
                await sendMessage(preparationID: preparationID)
            }
            sendPreparationTask = task
        }

        private func discardStoredAttachments(in message: Message) {
            for attachment in message.attachments ?? [] {
                if let localPath = attachment.localPath {
                    AttachmentStorage.shared.delete(path: localPath)
                }
            }
        }

        private func restorePendingAutoSendClaimIfNeeded() {
            guard let claim = pendingAutoSendClaim else { return }
            defer { pendingAutoSendClaim = nil }
            guard messageText == claim.prompt,
                  let index = conversationManager.conversations.firstIndex(where: { $0.id == claim.conversationID })
            else {
                return
            }

            if conversationManager.conversations[index].pendingAutoSendPrompt == nil {
                conversationManager.conversations[index].pendingAutoSendPrompt = claim.prompt
                conversationManager.saveImmediately(conversationManager.conversations[index])
            }
            messageText = ""
        }

        private func isSameAppContent(_ lhs: AppContent?, _ rhs: AppContent?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                true
            case let (lhs?, rhs?):
                lhs.appName == rhs.appName &&
                    lhs.bundleIdentifier == rhs.bundleIdentifier &&
                    lhs.windowTitle == rhs.windowTitle &&
                    lhs.content == rhs.content &&
                    lhs.contentType == rhs.contentType &&
                    lhs.isTruncated == rhs.isTruncated &&
                    lhs.originalLength == rhs.originalLength
            default:
                false
            }
        }

        // This method coordinates attachment handling, MCP tool availability, streaming setup, and state
        // resets. Breaking it apart right now would require plumbing a large amount of shared state, so
        // we defer that refactor and explicitly allow the longer body.
        // swiftlint:disable:next function_body_length
        private func sendMessage(preparationID: UUID) async {
            var handedOff = false
            defer {
                if sendPreparationID == preparationID {
                    sendPreparationTask = nil
                    sendPreparationID = nil
                    if !handedOff {
                        isGenerating = false
                    }
                }
            }

            guard sendPreparationID == preparationID, !Task.isCancelled else { return }

        // Auto-select response if we are continuing from a multi-model state without selection
        autoSelectResponseIfNeeded()

        guard let activeModel = resolveModelForSending() else {
            logChat("❌ Cannot send message: no model selected", level: .error)
            errorMessage = "Select a model in Settings → Model."
            return
        }

        ensureConversationModelMatchesSelection(activeModel)
            let promptText = messageText
            let filesToSend = attachedFiles
            let appContentToSend = attachedAppContent
            let selectedModelsToSend = selectedModels
        logChat(
            "🎯 Sending message with model \(activeModel)",
            level: .info,
            metadata: ["model": activeModel]
        )

        // Build user message using ChatMessageBuilder
        let userMessage = await ChatMessageBuilder.createUserMessage(
                text: promptText,
                appContent: appContentToSend,
                fileURLs: filesToSend,
            saveToStorage: true
        )
            guard sendPreparationID == preparationID, !Task.isCancelled else {
                discardStoredAttachments(in: userMessage)
                return
            }

            if appContentToSend != nil {
            logChat(
                "📎 Including app content in message",
                level: .info,
                metadata: [
                        "appName": appContentToSend?.appName ?? "",
                        "contentType": appContentToSend?.contentType.displayName ?? "",
                        "contentLength": "\(appContentToSend?.content.count ?? 0)"
                ]
            )
        }

            logChat(
                "📨 Creating message with \(userMessage.attachments?.count ?? 0) attachments",
            level: .info,
            metadata: ["attachmentCount": "\(userMessage.attachments?.count ?? 0)"]
            )
            pendingAutoSendClaim = nil
            conversationManager.addMessage(to: conversation, message: userMessage)

        // Process memory commands (e.g., "remember that I prefer dark mode")
        if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: userMessage.content) {
            logChat("💾 Memory command processed: \(memoryResponse)", level: .info)
        }

            if messageText == promptText {
        messageText = ""
            }
        isComposerFocused = true
            attachedFiles.removeAll { filesToSend.contains($0) }
            if isSameAppContent(attachedAppContent, appContentToSend) {
                attachedAppContent = nil
            }
        errorMessage = nil
        errorRecoverySuggestion = nil
        failedMessage = promptText // Store for retry in case of failure
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
                handedOff = true
            // Image generation flow - handle multi-model image gen
                if selectedModelsToSend.count >= 2 {
                    generateMultiModelImages(prompt: promptText, models: Array(selectedModelsToSend))
            } else {
                generateImage(prompt: promptText, model: activeModel)
            }
            return
        }

        // Check if multi-model mode is enabled (2+ models selected)
            if selectedModelsToSend.count >= 2 {
                handedOff = true
            sendMultiModelMessage(
                userMessageId: userMessage.id,
                    models: Array(selectedModelsToSend),
                temperature: updatedConversation.temperature
            )
            return
        }

            let currentMessages = updatedConversation.getEffectiveHistory()

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

        // Auto-select response if we are continuing from a multi-model state without selection
        autoSelectResponseIfNeeded()

            handedOff = true
        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: activeModel,
            temperature: updatedConversation.temperature,
            tools: tools,
            isInitialRequest: true,
            assistantMessageID: assistantMessage.id
        )
    }

    // Helper function to send messages with automatic tool call handling
    // swiftlint:disable:next function_body_length
    func sendMessageWithToolSupport(
        messages: [Message],
        model: String,
        temperature: Double,
        tools: [[String: Any]]?,
        isInitialRequest _: Bool,
        assistantMessageID requestedAssistantMessageID: UUID? = nil,
        operationID existingOperationID: ToolChainCoordinator.OperationID? = nil
    ) {
        let maxToolCallDepth = AgentSettingsStore.shared.settings.maxToolChainDepth
        let mcpManager = MCPServerManager.shared
        let toolsWrapper = UncheckedSendableWrapper(tools)
        let conversationId = conversation.id
        let coordinator = toolChainCoordinator
        let requestRounds = toolCallRequestRoundCoordinator
            let operationID: ToolChainCoordinator.OperationID
            guard let assistantMessageID = requestedAssistantMessageID
                ?? conversationManager.conversation(byId: conversationId)?.messages.last(where: { $0.role == .assistant })?.id
            else {
                isGenerating = false
                return
            }
            activeAssistantMessageID = assistantMessageID

            if let existingOperationID {
                operationID = existingOperationID
            } else {
                activeMultiModelResponseGroupID = nil
                batchUpdateTask?.cancel()
                batchUpdateTask = nil
                pendingChunks.removeAll()
                toolCallDepth = 0
                operationID = coordinator.beginOperation(conversationID: conversationId)
            }

            guard coordinator.owns(operationID, conversationID: conversationId),
                  let requestRoundID = requestRounds.beginRequestRound(
                      for: operationID,
                      coordinatedBy: coordinator
                  )
            else {
                return
            }

            let request = aiService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
                conversationId: conversationId,
            onChunk: { chunk in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                        guard activeAssistantMessageID == assistantMessageID else { return }
                    pendingChunks.append(chunk)
                    batchUpdateTask?.cancel()

                        let batchTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                            guard !Task.isCancelled,
                                  coordinator.owns(operationID, conversationID: conversationId),
                                  activeAssistantMessageID == assistantMessageID
                            else {
                                return
                            }

                        let chunksToProcess = pendingChunks
                        pendingChunks.removeAll()
                        guard !chunksToProcess.isEmpty else { return }

                        let combinedChunk = chunksToProcess.joined()
                            guard conversationManager.appendToMessage(
                                conversationId: conversationId,
                                messageId: assistantMessageID,
                                chunk: combinedChunk
                            ) else {
                            logChat(
                                    "⚠️ Assistant message no longer exists, ignoring chunk",
                                    level: .info,
                                    metadata: ["messageId": assistantMessageID.uuidString]
                            )
                            return
                        }
                            if let conversation = conversationManager.conversation(byId: conversationId) {
                                conversationManager.save(conversation)
                        }
                                currentToolName = nil
                            }
                        batchUpdateTask = batchTask
                        coordinator.track(batchTask, for: operationID)
                }
            },
            onComplete: {
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                        guard activeAssistantMessageID == assistantMessageID else { return }
                    batchUpdateTask?.cancel()
                        batchUpdateTask = nil

                    if !pendingChunks.isEmpty {
                        let remainingChunks = pendingChunks.joined()
                        pendingChunks.removeAll()
                            conversationManager.appendToMessage(
                                conversationId: conversationId,
                                messageId: assistantMessageID,
                                chunk: remainingChunks
                        )
                    }
                        if let conversation = conversationManager.conversation(byId: conversationId) {
                            conversationManager.saveImmediately(conversation)
                    }

                        let resolution = requestRounds.providerDidComplete(
                            operationID: operationID,
                            requestRoundID: requestRoundID
                        )
                        handleToolRoundResolution(
                            resolution,
                            operationID: operationID,
                            sourceAssistantMessageID: assistantMessageID,
                            conversationID: conversationId,
                            model: model,
                            temperature: temperature,
                            tools: toolsWrapper.value
                        )
                }
            },
            onError: { error in
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                        guard activeAssistantMessageID == assistantMessageID else { return }
                        guard coordinator.owns(operationID, conversationID: conversationId) else { return }
                        abortOwnedTextGeneration(operationID: operationID, conversationID: conversationId)
                        if !(error is CancellationError) {
                    logChat(
                        "❌ Stream error",
                        level: .error,
                        metadata: ["error": error.localizedDescription]
                    )
                    errorMessage = ErrorPresenter.userMessage(for: error)
                    errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
                }
                    }
            },
            onToolCallRequested: { toolCallId, toolName, arguments in
                let argumentsWrapper = UncheckedSendableWrapper(arguments)
                    coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                        guard activeAssistantMessageID == assistantMessageID,
                              let token = requestRounds.registerTool(
                                  for: operationID,
                                  requestRoundID: requestRoundID
                        )
                        else {
                        return
                    }

                        if token.registrationIndex == 0 {
                    guard toolCallDepth < maxToolCallDepth else {
                        logChat("⚠️ Max tool call depth reached, stopping", level: .error)
                                abortOwnedTextGeneration(operationID: operationID, conversationID: conversationId)
                                errorMessage = "Tool call limit reached. Please try again."
                        return
                    }
                    toolCallDepth += 1
                            armToolChainTimeout(
                                operationID: operationID,
                                assistantMessageID: assistantMessageID,
                                conversationID: conversationId
                            )
                        }

                        currentToolName = toolName
                        let arguments = argumentsWrapper.value
                        let anyCodableArguments = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
                            result[pair.key] = AnyCodable(pair.value)
                        }
                        let toolCall = MCPToolCall(
                            id: toolCallId,
                            toolName: toolName,
                            arguments: anyCodableArguments
                        )
                        conversationManager.updateMessage(
                            conversationId: conversationId,
                            messageId: assistantMessageID
                        ) { message in
                            var calls = message.toolCalls ?? []
                            if !calls.contains(where: { $0.id == toolCallId }) {
                                calls.append(toolCall)
                            }
                            message.toolCalls = calls
                        }
                        if let conversation = conversationManager.conversation(byId: conversationId) {
                            conversationManager.save(conversation)
                    }

                        coordinator.schedule(for: operationID, conversationID: conversationId) {
                            guard coordinator.owns(operationID, conversationID: conversationId),
                                  activeAssistantMessageID == assistantMessageID,
                                  !Task.isCancelled
                            else {
                                return
                            }

                            let result: ToolExecutionResult
                            do {
                                logChat(
                                    "⚙️ Executing tool: \(toolName)",
                                    level: .info,
                                    metadata: ["toolName": toolName]
                                )

                                let output: String
                                let citations: [CitationReference]?
                                if aiService.isBuiltInTool(toolName) {
                                    (output, citations) = await aiService.executeBuiltInToolWithCitations(
                                        name: toolName,
                                        arguments: argumentsWrapper.value,
                                        conversationId: conversationId
                                    )
                                } else {
                                    output = try await mcpManager.executeTool(
                                        name: toolName,
                                        arguments: argumentsWrapper.value
                                    )
                                    citations = nil
                                }
                                guard coordinator.owns(operationID, conversationID: conversationId),
                                      activeAssistantMessageID == assistantMessageID,
                                      !Task.isCancelled
                                else {
                                    return
                                }
                                result = ToolExecutionResult(
                                    callID: toolCallId,
                                    toolName: toolName,
                                    arguments: anyCodableArguments,
                                    output: output,
                                    citations: citations ?? []
                                )
                            } catch is CancellationError {
                                return
                            } catch {
                                guard coordinator.owns(operationID, conversationID: conversationId),
                                      activeAssistantMessageID == assistantMessageID,
                                      !Task.isCancelled
                                else {
                                    return
                                }
                                logChat(
                                    "❌ Tool execution failed: \(error.localizedDescription)",
                                    level: .error,
                                    metadata: ["toolName": toolName, "error": error.localizedDescription]
                                )
                                result = ToolExecutionResult(
                                    callID: toolCallId,
                                    toolName: toolName,
                                    arguments: anyCodableArguments,
                                    output: "ERROR: \(error.localizedDescription)"
                                )
                            }

                            let resolution = requestRounds.toolDidComplete(token, result: result)
                            handleToolRoundResolution(
                                resolution,
                                operationID: operationID,
                                sourceAssistantMessageID: assistantMessageID,
                                conversationID: conversationId,
                                model: model,
                                temperature: temperature,
                                tools: toolsWrapper.value
                            )
                        }
                    }
                }
            )
            coordinator.track(request, for: operationID)
        }

        private func handleToolRoundResolution(
            _ resolution: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Resolution,
            operationID: ToolChainCoordinator.OperationID,
            sourceAssistantMessageID: UUID,
            conversationID: UUID,
            model: String,
            temperature: Double,
            tools: [[String: Any]]?
        ) {
            switch resolution {
            case .pending:
                return
            case .ignored:
                return
            case .responseCompleted:
                toolChainTimeoutTask?.cancel()
                toolChainTimeoutTask = nil
                guard toolChainCoordinator.finishOperation(operationID) else { return }
                activeAssistantMessageID = nil
                currentToolName = nil
                toolCallDepth = 0
                isGenerating = false
                failedMessage = nil
            case let .launchContinuation(continuation):
                toolChainTimeoutTask?.cancel()
                toolChainTimeoutTask = nil
                launchToolContinuation(
                    continuation,
                    operationID: operationID,
                    sourceAssistantMessageID: sourceAssistantMessageID,
                    conversationID: conversationID,
                    model: model,
                    temperature: temperature,
                    tools: tools
                )
            }
        }

        private func launchToolContinuation(
            _ continuation: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Continuation,
            operationID: ToolChainCoordinator.OperationID,
            sourceAssistantMessageID: UUID,
            conversationID: UUID,
            model: String,
            temperature: Double,
            tools: [[String: Any]]?
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationID),
                  continuation.operationID == operationID,
                  activeAssistantMessageID == sourceAssistantMessageID,
                  let conversation = conversationManager.conversation(byId: conversationID)
            else {
                return
            }

            let results = continuation.toolResults.map(\.result)
            for result in results {
                conversationManager.addMessage(to: conversation, message: result.makeMessage())
            }

            let citations = ToolExecutionResult.combinedCitations(from: results)
            let continuationMessage = ToolCallHandler.createContinuationMessage(
                model: model,
                citations: citations.isEmpty ? nil : citations
            )
            conversationManager.addMessage(to: conversation, message: continuationMessage)

            guard let conversationWithAssistant = conversationManager.conversation(byId: conversationID),
                  toolChainCoordinator.owns(operationID, conversationID: conversationID)
            else {
                return
            }

            var history = conversationWithAssistant
            history.messages.removeAll { $0.id == continuationMessage.id }
            var continuationMessages = history.getEffectiveHistory()
            if let systemPrompt = buildFullSystemPrompt(for: conversationWithAssistant) {
                continuationMessages.insert(Message(role: .system, content: systemPrompt), at: 0)
            }

            currentToolName = nil
            sendMessageWithToolSupport(
                messages: continuationMessages,
                model: model,
                temperature: temperature,
                tools: tools,
                isInitialRequest: false,
                assistantMessageID: continuationMessage.id,
                operationID: operationID
            )
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
#endif
