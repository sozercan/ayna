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
        @State private var activeToolRequestStageID: UUID?
        @State var activeAIRequestOwnerID: UUID?
        @State private var activeToolExecutionTask: Task<Void, Never>?
        @State private var activeToolCallBatchState: MacToolCallBatchState?
        @State private var activeToolCallbackQueue: OrderedMainActorEventQueue?
        @State private var cancellingToolRequestStageID: UUID?
        @State var activeMultiModelCallbackQueue: OrderedMainActorEventQueue?
        @State var activeMultiModelResponseGroupID: UUID?
        @State var activeImageGenerationID: UUID?
        @State var imageRequestTracker = ImageRequestTracker()
        @State private var isComposerFocused = true
        @State private var toolChainTimeoutTask: Task<Void, Never>?
        @State private var showingSystemPromptSheet = false
        @State private var isPreparingMessageSend = false

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
                    if message.toolCalls?.first?.toolName == "web_search" {
                        return false
                    }
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

        /// Updates cached displayable items. Call when messages change or isGenerating changes.
        private func updateDisplayableItems() {
            cachedDisplayableItems = DisplayableMessageGrouper.displayableItems(
                from: visibleMessages,
                makeMessage: { .message($0) },
                makeResponseGroup: { groupId, responses in
                    // Always show response groups as a group, even if only one response is currently visible
                    // This prevents UI jumping when responses arrive sequentially
                    .responseGroup(groupId: groupId, responses: responses)
                }
            )
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
                        onSendMessage: { Task { await sendMessage() } },
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
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .conversationHistoryClearStarted,
                object: conversationManager
            )) { _ in
                cancelActiveGeneration()
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
                await sendMessage()
            }
        }

        /// Sends the last user message in the conversation (used for Work with Apps)
        private func sendPendingUserMessage() {
            guard currentConversation.messages.contains(where: { $0.role == .user }) else {
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

        // MARK: - Export Helpers

        private enum ExportFormat {
            case markdown
            case pdf
        }

        private func exportConversation(format: ExportFormat) async {
            guard let conversationForExport = await conversationManager.ensureConversationLoaded(currentConversation.id) else {
                logChat("❌ Cannot export conversation: failed to load conversation history", level: .error)
                errorMessage = "Could not load this conversation for export. Please try again."
                return
            }

            let url: URL?
            switch format {
            case .markdown:
                let content = ConversationExporter.generateMarkdown(for: conversationForExport)
                let tempDir = FileManager.default.temporaryDirectory
                let fileName = "\(conversationForExport.title.replacingOccurrences(of: " ", with: "_")).md"
                let fileURL = tempDir.appendingPathComponent(fileName)
                do {
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                    url = fileURL
                } catch {
                    logChat("❌ Failed to write markdown export: \(error.localizedDescription)", level: .error)
                    url = nil
                }
            case .pdf:
                url = ConversationExporter.generatePDF(for: conversationForExport)
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
            Task { await sendMessage() }
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
        private func sendMessage() async {
            if isGenerating {
                // Stop generation immediately
                logChat("🛑 Stop button clicked, cancelling...", level: .info)
                cancelActiveGeneration()
                isComposerFocused = true
                return
            }

            guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isComposerFocused = true
                return
            }

            guard !isPreparingMessageSend else {
                logChat("⏳ Ignoring duplicate send while message preparation is in progress", level: .info)
                return
            }
            isPreparingMessageSend = true
            defer { isPreparingMessageSend = false }

            if conversationManager.isMetadataOnlyConversation(conversation.id) {
                guard await conversationManager.ensureConversationLoaded(conversation.id) != nil else {
                    logChat("❌ Cannot send message: failed to load conversation history", level: .error)
                    errorMessage = "Could not load this conversation. Please try again."
                    return
                }
                cachedConversationIndex = nil
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
            let userMessage = await ChatMessageBuilder.createUserMessage(
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

            sendMessageWithToolSupport(
                messages: messagesToSend,
                model: activeModel,
                temperature: updatedConversation.temperature,
                tools: tools,
                isInitialRequest: true
            )
        }

        // Helper function to send messages with automatic tool call handling
        // swiftlint:disable:next function_body_length
        func sendMessageWithToolSupport(
            messages: [Message],
            model: String,
            temperature: Double,
            tools: [[String: Any]]?,
            isInitialRequest _: Bool
        ) {
            let maxToolCallDepth = AgentSettingsStore.shared.settings.maxToolChainDepth
            let toolsWrapper = UncheckedSendableWrapper(tools)

            let conversationId = conversation.id
            let requestStageID = UUID()
            activeToolRequestStageID = requestStageID
            cancellingToolRequestStageID = nil
            activeAIRequestOwnerID = requestStageID
            let callbackQueue = OrderedMainActorEventQueue()
            activeToolCallbackQueue = callbackQueue
            let toolCallBatchState = MacToolCallBatchState()
            activeToolCallBatchState = toolCallBatchState

            aiService.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                tools: tools,
                conversationId: conversation.id,
                requestOwnerID: requestStageID,
                onChunk: { chunk in
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
                        // Batch chunks for better performance during streaming
                        pendingChunks.append(chunk)

                        // Cancel existing batch task and create new one
                        batchUpdateTask?.cancel()
                        batchUpdateTask = Task { @MainActor in
                            // Wait for batch window (100ms for smoother updates with large text)
                            try? await Task.sleep(for: .milliseconds(100))
                            guard !Task.isCancelled, activeToolRequestStageID == requestStageID else { return }

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

                            // Persist during streaming so content isn't lost on quit
                            conversationManager.save(conversationManager.conversations[index])

                            // Only update UI state if we're currently viewing this conversation
                            if conversationManager.conversations[index].id == conversationId {
                                // Clear tool execution indicator when we start receiving actual content
                                if currentToolName != nil {
                                    currentToolName = nil
                                }
                            }
                        }
                    }
                },
                onComplete: {
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
                        guard cancellingToolRequestStageID != requestStageID else { return }
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

                        // Always save conversations immediately on completion
                        if let index = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversation.id
                        }) {
                            conversationManager.saveImmediately(conversationManager.conversations[index])
                        }

                        // Only update UI state if we're viewing this conversation
                        guard let currentIndex = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversationId
                        }) else {
                            isGenerating = false
                            logChat(
                                "✅ onComplete for conversation \(conversationId) (background)",
                                level: .info
                            )
                            return
                        }

                        guard conversationManager.conversations[currentIndex].id == conversationId else {
                            isGenerating = false
                            logChat(
                                "✅ onComplete for conversation \(conversationId) (background)",
                                level: .info
                            )
                            return
                        }

                        if let toolCalls = toolCallBatchState.beginProcessing() {
                            guard toolCallDepth + toolCalls.count <= maxToolCallDepth else {
                                persistUnfinishedToolResults(
                                    toolCalls,
                                    excluding: Set<String>(),
                                    result: "Tool call skipped because the tool call limit was reached.",
                                    conversationId: conversationId
                                )
                                toolCallBatchState.finishProcessing()
                                activeToolCallBatchState = nil
                                activeToolRequestStageID = nil
                                activeAIRequestOwnerID = nil
                                isGenerating = false
                                currentToolName = nil
                                toolCallDepth = 0
                                toolChainTimeoutTask?.cancel()
                                toolChainTimeoutTask = nil
                                errorMessage = "Tool call limit reached. Please try again."
                                return
                            }
                            toolCallDepth += toolCalls.count
                            executeQueuedToolCalls(
                                toolCalls,
                                batchState: toolCallBatchState,
                                requestStageID: requestStageID,
                                conversationId: conversationId,
                                model: model,
                                temperature: temperature,
                                tools: toolsWrapper.value
                            )
                        } else if !toolCallBatchState.hasPendingToolCall {
                            activeToolCallBatchState = nil
                            activeToolRequestStageID = nil
                            activeAIRequestOwnerID = nil
                            logChat("✅ onComplete: isGenerating set to FALSE (no tool calls pending)", level: .info)
                            isGenerating = false
                            failedMessage = nil // Clear failed message on success
                            toolChainTimeoutTask?.cancel()
                            toolChainTimeoutTask = nil
                        } else {
                            logChat(
                                "⏳ onComplete: Keeping isGenerating TRUE while tool calls execute",
                                level: .info
                            )
                        }
                    }
                },
                onError: { error in
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
                        let isCancellation = error is CancellationError
                            || (error as NSError).code == NSURLErrorCancelled
                        // Clean up batching
                        batchUpdateTask?.cancel()
                        if !pendingChunks.isEmpty,
                           let index = conversationManager.conversations.firstIndex(where: {
                               $0.id == conversationId
                           }),
                           var lastMessage = conversationManager.conversations[index].messages.last,
                           lastMessage.role == .assistant
                        {
                            lastMessage.content += pendingChunks.joined()
                            conversationManager.conversations[index].messages[
                                conversationManager.conversations[index].messages.count - 1
                            ] = lastMessage
                        }
                        pendingChunks.removeAll()
                        finalizePendingToolCalls(
                            result: isCancellation
                                ? "Tool call cancelled before completion."
                                : "Tool execution failed: \(error.localizedDescription)",
                            conversationId: conversationId
                        )
                        activeToolRequestStageID = nil
                        activeAIRequestOwnerID = nil

                        if isCancellation {
                            isGenerating = false
                            currentToolName = nil
                            toolCallDepth = 0
                            toolChainTimeoutTask?.cancel()
                            toolChainTimeoutTask = nil
                            if let index = conversationManager.conversations.firstIndex(where: {
                                $0.id == conversationId
                            }) {
                                conversationManager.saveImmediately(conversationManager.conversations[index])
                            }
                            return
                        }
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
                        guard conversationManager.conversations.firstIndex(where: {
                            $0.id == conversationId
                        }) != nil else {
                            isGenerating = false
                            let safeMessage = ErrorPresenter.userMessage(for: error)
                            logChat(
                                "❌ onError for conversation \(conversationId) (background): \(safeMessage)",
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
                    let argumentsWrapper = UncheckedSendableWrapper(arguments)
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
                        let arguments = argumentsWrapper.value
                        guard conversationManager.conversations.contains(where: { $0.id == conversation.id }) else {
                            logChat(
                                "⚠️ Tool call requested for conversation \(conversation.id) but conversation no longer exists, ignoring",
                                level: .default
                            )
                            currentToolName = nil
                            return
                        }

                        let queuedToolCall = MacQueuedToolCall(
                            id: toolCallId,
                            name: toolName,
                            arguments: arguments
                        )
                        toolCallBatchState.enqueue(queuedToolCall)
                        currentToolName = toolName

                        logChat(
                            "🔧 Queued tool call: \(toolName) for conversation \(conversation.id)",
                            level: .info,
                            metadata: ["toolName": toolName]
                        )

                        if let index = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversation.id
                        }),
                            var lastMessage = conversationManager.conversations[index].messages.last,
                            lastMessage.role == .assistant
                        {
                            let toolCall = ToolCallHandler.createToolCall(
                                id: toolCallId,
                                toolName: toolName,
                                arguments: arguments
                            )
                            var existingToolCalls = lastMessage.toolCalls ?? []
                            if !existingToolCalls.contains(where: { $0.id == toolCall.id }) {
                                existingToolCalls.append(toolCall)
                            }
                            lastMessage.toolCalls = existingToolCalls
                            conversationManager.conversations[index].messages[
                                conversationManager.conversations[index].messages.count - 1
                            ] = lastMessage
                            conversationManager.save(conversationManager.conversations[index])
                        }
                    }
                }
            )
        }

        @discardableResult
        private func persistToolResult(
            _ completedToolCall: MacCompletedToolCall,
            conversationId: UUID
        ) -> Bool {
            guard let index = conversationManager.conversations.firstIndex(where: {
                $0.id == conversationId
            }) else {
                return false
            }
            var updatedConversation = conversationManager.conversations[index]
            guard ToolCallHandler.insertToolResult(
                completedToolCall,
                into: &updatedConversation
            ) else {
                return false
            }
            conversationManager.conversations[index] = updatedConversation
            conversationManager.save(updatedConversation)
            return true
        }

        private func persistUnfinishedToolResults(
            _ toolCalls: [MacQueuedToolCall],
            excluding completedToolCallIds: Set<String>,
            result: String,
            conversationId: UUID
        ) {
            for toolCall in toolCalls where !completedToolCallIds.contains(toolCall.id) {
                _ = persistToolResult(
                    MacCompletedToolCall(
                        toolCall: toolCall,
                        result: result,
                        citations: nil
                    ),
                    conversationId: conversationId
                )
            }
        }

        private func finalizePendingToolCalls(result: String, conversationId: UUID) {
            guard let batchState = activeToolCallBatchState else { return }
            let toolCalls = batchState.takeAllToolCalls()
            if !toolCalls.isEmpty {
                persistUnfinishedToolResults(
                    toolCalls,
                    excluding: Set<String>(),
                    result: result,
                    conversationId: conversationId
                )
            }
            activeToolCallBatchState = nil
        }

        private func cancelActiveGeneration() {
            if let callbackQueue = activeToolCallbackQueue,
               let requestStageID = activeToolRequestStageID
            {
                cancellingToolRequestStageID = requestStageID
                activeToolExecutionTask?.cancel()
                callbackQueue.enqueue {
                    guard activeToolRequestStageID == requestStageID else { return }
                    cancelActiveGenerationNow()
                }
                return
            }
            cancelActiveGenerationNow()
        }

        private func cancelActiveGenerationNow() {
            let requestOwnerID = activeAIRequestOwnerID
            let multiModelCallbackQueue = activeMultiModelCallbackQueue
            let multiModelResponseGroupID = activeMultiModelResponseGroupID
            activeToolRequestStageID = nil
            cancellingToolRequestStageID = nil
            activeToolCallbackQueue = nil
            if multiModelCallbackQueue == nil {
                activeAIRequestOwnerID = nil
            }
            activeToolExecutionTask?.cancel()
            activeToolExecutionTask = nil
            cancelActiveImageRequests()
            if let requestOwnerID {
                AIService.shared.cancelCurrentRequest(ifOwnedBy: requestOwnerID)
            }

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
            finalizePendingToolCalls(
                result: "Tool call cancelled before completion.",
                conversationId: conversation.id
            )
            if multiModelCallbackQueue == nil,
               let index = conversationManager.conversations.firstIndex(where: {
                   $0.id == conversation.id
               }),
               let lastMessage = conversationManager.conversations[index].messages.last,
               lastMessage.role == .assistant,
               lastMessage.content.isEmpty,
               lastMessage.mediaType != .image,
               lastMessage.toolCalls?.isEmpty != false
            {
                conversationManager.conversations[index].messages.removeLast()
            }
            if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversationManager.saveImmediately(conversationManager.conversations[index])
            }
            if let multiModelCallbackQueue, let requestOwnerID {
                multiModelCallbackQueue.enqueue {
                    guard activeAIRequestOwnerID == requestOwnerID
                        || activeAIRequestOwnerID == nil
                    else {
                        return
                    }
                    if let multiModelResponseGroupID {
                        finalizeMultiModelTextResponses(
                            conversationId: conversation.id,
                            responseGroupId: multiModelResponseGroupID
                        )
                    }
                    if activeAIRequestOwnerID == requestOwnerID {
                        activeAIRequestOwnerID = nil
                    }
                    isGenerating = false
                    if activeMultiModelCallbackQueue === multiModelCallbackQueue {
                        activeMultiModelCallbackQueue = nil
                    }
                    if activeMultiModelResponseGroupID == multiModelResponseGroupID {
                        activeMultiModelResponseGroupID = nil
                    }
                }
            } else {
                if let multiModelResponseGroupID {
                    finalizeMultiModelTextResponses(
                        conversationId: conversation.id,
                        responseGroupId: multiModelResponseGroupID
                    )
                }
                activeMultiModelResponseGroupID = nil
                isGenerating = false
            }
            currentToolName = nil
            toolCallDepth = 0
            toolChainTimeoutTask?.cancel()
            toolChainTimeoutTask = nil
        }

        private func executeQueuedToolCalls(
            _ toolCalls: [MacQueuedToolCall],
            batchState: MacToolCallBatchState,
            requestStageID: UUID,
            conversationId: UUID,
            model: String,
            temperature: Double,
            tools: [[String: Any]]?
        ) {
            let toolsWrapper = UncheckedSendableWrapper(tools)
            let toolTask = Task { @MainActor in
                defer {
                    batchState.finishProcessing()
                    if activeToolCallBatchState === batchState {
                        activeToolCallBatchState = nil
                    }
                }
                var completedToolCalls: [MacCompletedToolCall] = []
                completedToolCalls.reserveCapacity(toolCalls.count)
                do {
                    for toolCall in toolCalls {
                        try Task.checkCancellation()
                        guard activeToolRequestStageID == requestStageID else {
                            throw CancellationError()
                        }

                        currentToolName = toolCall.name
                        logChat(
                            "⚙️ Executing tool: \(toolCall.name)",
                            level: .info,
                            metadata: ["toolName": toolCall.name]
                        )

                        let result: String
                        let citations: [CitationReference]?
                        if aiService.isBuiltInTool(toolCall.name) {
                            (result, citations) = await aiService.executeBuiltInToolWithCitations(
                                name: toolCall.name,
                                arguments: toolCall.arguments,
                                conversationId: conversationId
                            )
                        } else {
                            result = try await MCPServerManager.shared.executeTool(
                                name: toolCall.name,
                                arguments: toolCall.arguments
                            )
                            citations = nil
                        }
                        try Task.checkCancellation()
                        guard activeToolRequestStageID == requestStageID else {
                            throw CancellationError()
                        }
                        let completedToolCall = MacCompletedToolCall(
                            toolCall: toolCall,
                            result: result,
                            citations: citations
                        )
                        guard persistToolResult(
                            completedToolCall,
                            conversationId: conversationId
                        ) else {
                            throw CancellationError()
                        }
                        completedToolCalls.append(completedToolCall)

                        try Task.checkCancellation()
                        guard activeToolRequestStageID == requestStageID else {
                            throw CancellationError()
                        }
                    }

                    guard let updatedConversation = conversationManager.conversations.first(where: {
                        $0.id == conversationId
                    }) else {
                        activeToolRequestStageID = nil
                        activeAIRequestOwnerID = nil
                        isGenerating = false
                        currentToolName = nil
                        toolCallDepth = 0
                        toolChainTimeoutTask?.cancel()
                        toolChainTimeoutTask = nil
                        return
                    }

                    let citations = completedToolCalls.flatMap { $0.citations ?? [] }
                    let continuationAssistantMessage = ToolCallHandler.createContinuationMessage(
                        model: model,
                        citations: citations.isEmpty ? nil : citations
                    )
                    conversationManager.addMessage(
                        to: updatedConversation,
                        message: continuationAssistantMessage
                    )

                    guard let conversationWithAssistant = conversationManager.conversations.first(where: {
                        $0.id == conversationId
                    }) else { return }

                    currentToolName = "Analyzing tool results"
                    let continuationMessages = ToolCallHandler.buildContinuationMessages(
                        conversationMessages: conversationWithAssistant.messages,
                        completedToolCalls: completedToolCalls,
                        systemPrompt: buildFullSystemPrompt(for: conversationWithAssistant)
                    )
                    currentToolName = nil

                    guard !Task.isCancelled,
                          activeToolRequestStageID == requestStageID
                    else { return }
                    sendMessageWithToolSupport(
                        messages: continuationMessages,
                        model: model,
                        temperature: temperature,
                        tools: toolsWrapper.value,
                        isInitialRequest: false
                    )
                } catch is CancellationError {
                    persistUnfinishedToolResults(
                        toolCalls,
                        excluding: Set(completedToolCalls.map(\.toolCall.id)),
                        result: "Tool call cancelled before completion.",
                        conversationId: conversationId
                    )
                    if activeToolRequestStageID == requestStageID {
                        activeToolRequestStageID = nil
                        activeAIRequestOwnerID = nil
                        isGenerating = false
                        currentToolName = nil
                        toolCallDepth = 0
                        toolChainTimeoutTask?.cancel()
                        toolChainTimeoutTask = nil
                    }
                    return
                } catch {
                    persistUnfinishedToolResults(
                        toolCalls,
                        excluding: Set(completedToolCalls.map(\.toolCall.id)),
                        result: "Tool execution failed: \(error.localizedDescription)",
                        conversationId: conversationId
                    )
                    guard activeToolRequestStageID == requestStageID else { return }
                    activeToolRequestStageID = nil
                    activeAIRequestOwnerID = nil
                    isGenerating = false
                    currentToolName = nil
                    toolCallDepth = 0
                    toolChainTimeoutTask?.cancel()
                    toolChainTimeoutTask = nil
                    errorMessage = "Tool execution failed: \(error.localizedDescription)"
                    logChat(
                        "❌ Tool execution failed: \(error.localizedDescription)",
                        level: .error,
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
            activeToolExecutionTask = toolTask
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
