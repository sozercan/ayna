#if os(macOS)
//
    //  MacNewChatView.swift
    //  ayna
//
    //  New chat view for macOS - handles initial conversation creation and message sending.
//
    import Combine
    import OSLog
    import SwiftUI

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
        @State private var activeToolRequestStageID: UUID?
        @State private var activeAIRequestOwnerID: UUID?
        @State private var activeToolExecutionTask: Task<Void, Never>?
        @State private var activeToolCallBatchState: MacToolCallBatchState?
        @State private var activeToolCallbackQueue: OrderedMainActorEventQueue?
        @State private var cancellingToolRequestStageID: UUID?
        @State private var activeMultiModelCallbackQueue: OrderedMainActorEventQueue?
        @State private var activeMultiModelResponseGroupID: UUID?
        @State private var activeImageGenerationID: UUID?
        @State private var imageRequestTracker = ImageRequestTracker()
        @State private var showModelSelector = false
        @State private var selectedModels: Set<String> = []
        @State private var isToolSectionExpanded = false

        @State var errorMessage: String?
        @State var errorRecoverySuggestion: String?
        @State var shouldOfferOpenSettings = false

        // App content attachment (Attach from App)
        @State private var showAppContentPicker = false
        @State private var attachedAppContent: AppContent?

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

        /// Get visible messages (filtering out system and tool messages)
        private var visibleMessages: [Message] {
            guard let conversation = currentConversation else { return [] }
            return conversation.messages.filter { message in
                if message.role == .system {
                    return false
                }

                if message.role == .tool {
                    if message.toolCalls?.first?.toolName == "web_search" {
                        return false
                    }
                    return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

                if message.role == .assistant && message.content.isEmpty && message.imageData == nil {
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
                    return message.id == conversation.messages.last?.id && isGenerating
                }
                return !message.content.isEmpty || message.imageData != nil || message.mediaType == .image
            }
        }

        /// Converts visible messages into displayable items, grouping multi-model responses together
        private var displayableItems: [DisplayableItem] {
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

            return items
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
                                                onSwitchModel: nil,
                                                onEdit: message.role == .user && currentConversation != nil
                                                    ? { newContent in
                                                        if let conversation = currentConversation {
                                                            let edited = conversationManager.editMessage(
                                                                in: conversation,
                                                                messageId: message.id,
                                                                newContent: newContent
                                                            )
                                                            if edited {
                                                                sendMessageForConversation(conversation, model: conversation.model)
                                                            }
                                                        }
                                                    } : nil
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

                        if let toolName = currentToolName {
                            ToolExecutionIndicator(toolName: toolName)
                        }

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
            .onReceive(NotificationCenter.default.publisher(
                for: .conversationHistoryClearStarted,
                object: conversationManager
            )) { _ in
                cancelActiveGeneration()
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
                textEditorIdentifier: TestIdentifiers.NewChatComposer.textEditor,
                sendButtonIdentifier: TestIdentifiers.NewChatComposer.sendButton,
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

        // MARK: - Helper Methods

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
                conversationManager.saveImmediately(conversationManager.conversations[ci])
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

        private func finalizeMultiModelTextResponses(
            conversationId: UUID,
            responseGroupId: UUID
        ) {
            guard let conversationIndex = conversationManager.conversations.firstIndex(where: {
                $0.id == conversationId
            }),
                let groupIndex = conversationManager.conversations[conversationIndex]
                .responseGroups.firstIndex(where: { $0.id == responseGroupId })
            else {
                return
            }

            var didUpdateStatus = false
            for responseIndex in conversationManager.conversations[conversationIndex]
                .responseGroups[groupIndex].responses.indices
                where conversationManager.conversations[conversationIndex]
                .responseGroups[groupIndex].responses[responseIndex].status == .streaming
            {
                conversationManager.conversations[conversationIndex]
                    .responseGroups[groupIndex].responses[responseIndex].status = .failed
                didUpdateStatus = true
            }
            if didUpdateStatus {
                conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            }
        }

        private func isImageRequestCurrent(
            messageId: UUID,
            conversationId: UUID,
            attachmentGeneration: AttachmentStorageGeneration
        ) -> Bool {
            guard imageRequestTracker.isActive(messageId),
                  AttachmentStorage.shared.isCurrentGeneration(attachmentGeneration),
                  let conversation = conversationManager.conversations.first(where: { $0.id == conversationId })
            else {
                return false
            }
            return conversation.messages.contains { $0.id == messageId }
        }

        private func finalizeInvalidatedImageRequest(
            _ messageId: UUID,
            conversationId: UUID
        ) {
            guard imageRequestTracker.finish(messageId) else { return }
            if let conversationIndex = conversationManager.conversations.firstIndex(where: {
                $0.id == conversationId
            }) {
                if let messageIndex = conversationManager.conversations[conversationIndex].messages.firstIndex(where: {
                    $0.id == messageId
                }) {
                    conversationManager.conversations[conversationIndex].messages[messageIndex].content =
                        "Image generation cancelled because conversation history changed"
                    conversationManager.conversations[conversationIndex].messages[messageIndex].mediaType = nil
                    conversationManager.conversations[conversationIndex].messages[messageIndex].imageData = nil
                    conversationManager.conversations[conversationIndex].messages[messageIndex].imagePath = nil
                }
                for groupIndex in conversationManager.conversations[conversationIndex].responseGroups.indices {
                    for responseIndex in conversationManager.conversations[conversationIndex]
                        .responseGroups[groupIndex].responses.indices
                        where conversationManager.conversations[conversationIndex]
                        .responseGroups[groupIndex].responses[responseIndex].id == messageId
                    {
                        conversationManager.conversations[conversationIndex]
                            .responseGroups[groupIndex].responses[responseIndex].status = .failed
                    }
                }
                conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            }
        }

        @discardableResult
        func saveImageAndUpdateMessage(
            imageData: Data,
            conversation: Conversation,
            messageId: UUID,
            attachmentGeneration: AttachmentStorageGeneration
        ) async -> Bool {
            guard isImageRequestCurrent(
                messageId: messageId,
                conversationId: conversation.id,
                attachmentGeneration: attachmentGeneration
            ) else {
                finalizeInvalidatedImageRequest(messageId, conversationId: conversation.id)
                return false
            }

            // Save image to disk off MainActor to avoid blocking the UI.
            let imagePath = await Task.detached(priority: .userInitiated) {
                try? AttachmentStorage.shared.save(
                    data: imageData,
                    extension: "png",
                    generation: attachmentGeneration
                )
            }.value

            guard isImageRequestCurrent(
                messageId: messageId,
                conversationId: conversation.id,
                attachmentGeneration: attachmentGeneration
            ) else {
                if let imagePath {
                    AttachmentStorage.shared.delete(path: imagePath)
                }
                finalizeInvalidatedImageRequest(messageId, conversationId: conversation.id)
                return false
            }

            guard imageRequestTracker.finish(messageId) else {
                if let imagePath {
                    AttachmentStorage.shared.delete(path: imagePath)
                }
                return false
            }

            if imagePath == nil {
                logNewChat("❌ Failed to save generated image to disk", level: .error)
            }

            conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                message.content = ""
                if let path = imagePath {
                    message.imagePath = path; message.imageData = nil
                } else {
                    message.imageData = imageData; message.imagePath = nil
                }
            }
            return true
        }

        // MARK: - Send Message

        private func sendMessage() async {
            dismissError()
            if isGenerating {
                // Stop generation immediately
                logNewChat("🛑 Stop button clicked in NewChatView, cancelling...", level: .info)
                cancelActiveGeneration()
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

            // Build user message using ChatMessageBuilder
            let userMessage = await ChatMessageBuilder.createUserMessage(
                text: textToSend,
                appContent: attachedAppContent,
                fileURLs: filesToSend,
                saveToStorage: false
            )

            if attachedAppContent != nil {
                logNewChat(
                    "📎 Including app content in message",
                    level: .info,
                    metadata: [
                        "appName": attachedAppContent?.appName ?? "",
                        "contentType": attachedAppContent?.contentType.displayName ?? "",
                        "contentLength": "\(attachedAppContent?.content.count ?? 0)"
                    ]
                )
            }

            conversationManager.addMessage(to: conversation, message: userMessage)

            // Process memory commands (e.g., "remember that I prefer dark mode")
            if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: userMessage.content) {
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
            let multiModelConversationID = currentConversationId
            activeToolRequestStageID = nil
            cancellingToolRequestStageID = nil
            activeToolCallbackQueue = nil
            if multiModelCallbackQueue == nil {
                activeAIRequestOwnerID = nil
            }
            activeToolExecutionTask?.cancel()
            activeToolExecutionTask = nil
            if let conversationId = currentConversationId {
                finalizePendingToolCalls(
                    result: "Tool call cancelled before completion.",
                    conversationId: conversationId
                )
            } else {
                activeToolCallBatchState = nil
            }
            if multiModelCallbackQueue == nil,
               let conversationId = currentConversationId,
               let conversationIndex = conversationManager.conversations.firstIndex(where: {
                   $0.id == conversationId
               }),
               let lastMessage = conversationManager.conversations[conversationIndex].messages.last,
               lastMessage.role == .assistant,
               lastMessage.content.isEmpty,
               lastMessage.mediaType != .image,
               lastMessage.toolCalls?.isEmpty != false
            {
                conversationManager.conversations[conversationIndex].messages.removeLast()
                conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            }
            cancelActiveImageRequests()
            if let requestOwnerID {
                AIService.shared.cancelCurrentRequest(ifOwnedBy: requestOwnerID)
            }
            if let multiModelCallbackQueue, let requestOwnerID {
                multiModelCallbackQueue.enqueue {
                    guard activeAIRequestOwnerID == requestOwnerID
                        || activeAIRequestOwnerID == nil
                    else {
                        return
                    }
                    if let multiModelConversationID, let multiModelResponseGroupID {
                        finalizeMultiModelTextResponses(
                            conversationId: multiModelConversationID,
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
                if let multiModelConversationID, let multiModelResponseGroupID {
                    finalizeMultiModelTextResponses(
                        conversationId: multiModelConversationID,
                        responseGroupId: multiModelResponseGroupID
                    )
                }
                activeMultiModelResponseGroupID = nil
                isGenerating = false
            }
            currentToolName = nil
            toolCallDepth = 0
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
            let generationID = UUID()
            activeImageGenerationID = generationID
            let attachmentGeneration = AttachmentStorage.shared.currentGeneration()
            let placeholderMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                mediaType: .image
            )
            conversationManager.addMessage(to: conversation, message: placeholderMessage)
            imageRequestTracker.begin(messageId)

            let handle = aiService.generateImage(
                prompt: prompt,
                model: model,
                onComplete: { imageData in
                    Task { @MainActor in
                        guard activeImageGenerationID == generationID,
                              imageRequestTracker.isActive(messageId)
                        else { return }
                        let didSaveImage = await saveImageAndUpdateMessage(
                            imageData: imageData,
                            conversation: conversation,
                            messageId: messageId,
                            attachmentGeneration: attachmentGeneration
                        )
                        guard activeImageGenerationID == generationID else { return }
                        activeImageGenerationID = nil
                        isGenerating = false
                        if didSaveImage {
                            selectedConversationId = conversation.id
                        }
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        guard imageRequestTracker.finish(messageId),
                              activeImageGenerationID == generationID
                        else { return }
                        activeImageGenerationID = nil
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
            if let handle {
                imageRequestTracker.register(handle, for: messageId)
            }
        }

        /// Generates images from multiple models in parallel for comparison
        private func generateMultiModelImages(prompt: String, models: [String], conversation: Conversation) {
            // Create a response group for the multi-model comparison
            let responseGroupId = UUID()
            let generationID = UUID()
            activeImageGenerationID = generationID
            let attachmentGeneration = AttachmentStorage.shared.currentGeneration()
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
                userMessageId: conversation.messages.last(where: { $0.role == .user })?.id ?? UUID(),
                responses: responseEntries
            )

            // Add response group to conversation
            if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversationManager.conversations[index].responseGroups.append(responseGroup)
            }

            let messageIdsByModel = messageIds

            // Track completion state with actor-isolated counter
            let counter = MainActorCompletionCounter(total: models.count)

            // Generate images in parallel
            for model in models {
                guard let messageId = messageIdsByModel[model] else { continue }
                imageRequestTracker.begin(messageId)

                let handle = aiService.generateImage(
                    prompt: prompt,
                    model: model,
                    onComplete: { imageData in
                        Task { @MainActor in
                            guard activeImageGenerationID == generationID,
                                  imageRequestTracker.isActive(messageId)
                            else { return }
                            let didSaveImage = await saveImageAndUpdateMessage(
                                imageData: imageData,
                                conversation: conversation,
                                messageId: messageId,
                                attachmentGeneration: attachmentGeneration
                            )
                            guard activeImageGenerationID == generationID else { return }
                            if didSaveImage {
                                updateResponseGroupStatus(
                                    conversationId: conversation.id,
                                    responseGroupId: responseGroupId,
                                    messageId: messageId,
                                    status: .completed
                                )
                            }
                            counter.increment()
                            if counter.isComplete {
                                activeImageGenerationID = nil
                                isGenerating = false
                                if didSaveImage {
                                    selectedConversationId = conversation.id
                                }
                            }
                        }
                    },
                    onError: { error in
                        Task { @MainActor in
                            guard imageRequestTracker.finish(messageId),
                                  activeImageGenerationID == generationID
                            else { return }
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
                                activeImageGenerationID = nil
                                isGenerating = false
                                selectedConversationId = conversation.id
                            }
                        }
                    }
                )
                if let handle {
                    imageRequestTracker.register(handle, for: messageId)
                }
            }
        }

        private func cancelActiveImageRequests() {
            activeImageGenerationID = nil
            let cancelledMessageIds = imageRequestTracker.cancelAll()
            guard !cancelledMessageIds.isEmpty,
                  let conversationId = currentConversationId,
                  let conversationIndex = conversationManager.conversations.firstIndex(where: {
                      $0.id == conversationId
                  })
            else { return }

            for messageIndex in conversationManager.conversations[conversationIndex].messages.indices
                where cancelledMessageIds.contains(
                    conversationManager.conversations[conversationIndex].messages[messageIndex].id
                )
            {
                conversationManager.conversations[conversationIndex].messages[messageIndex].content =
                    "Image generation cancelled"
                conversationManager.conversations[conversationIndex].messages[messageIndex].mediaType = nil
                conversationManager.conversations[conversationIndex].messages[messageIndex].imageData = nil
                conversationManager.conversations[conversationIndex].messages[messageIndex].imagePath = nil
            }
            for groupIndex in conversationManager.conversations[conversationIndex].responseGroups.indices {
                for responseIndex in conversationManager.conversations[conversationIndex]
                    .responseGroups[groupIndex].responses.indices
                    where cancelledMessageIds.contains(
                        conversationManager.conversations[conversationIndex]
                            .responseGroups[groupIndex].responses[responseIndex].id
                    )
                {
                    conversationManager.conversations[conversationIndex]
                        .responseGroups[groupIndex].responses[responseIndex].status = .failed
                }
            }
            conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
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
            activeMultiModelResponseGroupID = responseGroupId
            var responseGroup = ResponseGroup(id: responseGroupId, userMessageId: userMessageId)

            // Create placeholder messages for each model
            let messageIds = Dictionary(uniqueKeysWithValues: models.map { ($0, UUID()) })
            for model in models {
                guard let messageId = messageIds[model] else { continue }
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

            let messageIdsByModel = messageIds

            // Prepare messages for API
            var messagesToSend = updatedConversation.getEffectiveHistory()
            if let systemPrompt = conversationManager.effectiveSystemPrompt(for: updatedConversation) {
                let systemMessage = Message(role: .system, content: systemPrompt)
                messagesToSend.insert(systemMessage, at: 0)
            }
            let requestOwnerID = UUID()
            activeAIRequestOwnerID = requestOwnerID
            let callbackQueue = OrderedMainActorEventQueue()
            activeMultiModelCallbackQueue = callbackQueue

            // Send to all models in parallel
            aiService.sendToMultipleModels(
                messages: messagesToSend,
                models: models,
                temperature: temperature,
                requestOwnerID: requestOwnerID,
                onChunk: { model, chunk in
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID,
                              let messageId = messageIdsByModel[model],
                              let convIndex = conversationManager.conversations.firstIndex(where: {
                                  $0.id == conversationId
                              }),
                              let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: {
                                  $0.id == messageId
                              })
                        else { return }

                        conversationManager.conversations[convIndex].messages[msgIndex].content += chunk
                        // Persist during streaming so content isn't lost on quit
                        conversationManager.save(conversationManager.conversations[convIndex])
                    }
                },
                onModelComplete: { model in
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID,
                              let messageId = messageIdsByModel[model]
                        else { return }

                        updateResponseGroupViaGroup(conversationId: conversationId, responseGroupId: responseGroupId, messageId: messageId, status: .completed)
                        logNewChat("✅ Model completed in multi-model", level: .info, metadata: ["model": model])
                    }
                },
                onAllComplete: {
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID else { return }
                        activeAIRequestOwnerID = nil
                        if activeMultiModelCallbackQueue === callbackQueue {
                            activeMultiModelCallbackQueue = nil
                        }
                        if activeMultiModelResponseGroupID == responseGroupId {
                            activeMultiModelResponseGroupID = nil
                        }
                        isGenerating = false
                        logNewChat("🏁 All models completed", level: .info)

                        // Save the conversation immediately on completion
                        if let convIndex = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversationId
                        }) {
                            conversationManager.saveImmediately(conversationManager.conversations[convIndex])
                        }

                        // Switch to chat view
                        selectedConversationId = conversationId
                    }
                },
                onError: { model, error in
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID
                            || activeAIRequestOwnerID == nil
                        else { return }
                        let isCancellation = error is CancellationError
                            || (error as NSError).code == NSURLErrorCancelled
                        guard let messageId = messageIdsByModel[model] else { return }

                        updateResponseGroupViaGroup(
                            conversationId: conversationId,
                            responseGroupId: responseGroupId,
                            messageId: messageId,
                            status: .failed
                        )
                        if isCancellation {
                            if let convIndex = conversationManager.conversations.firstIndex(where: {
                                $0.id == conversationId
                            }) {
                                conversationManager.saveImmediately(conversationManager.conversations[convIndex])
                            }
                            return
                        }

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
            let requestStageID = UUID()
            activeToolRequestStageID = requestStageID
            cancellingToolRequestStageID = nil
            activeAIRequestOwnerID = requestStageID
            let callbackQueue = OrderedMainActorEventQueue()
            activeToolCallbackQueue = callbackQueue
            let toolCallBatchState = MacToolCallBatchState()
            activeToolCallBatchState = toolCallBatchState
            let toolsWrapper = UncheckedSendableWrapper(tools)

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

                        // Persist during streaming so content isn't lost on quit
                        conversationManager.save(conversationManager.conversations[index])

                        if currentToolName != nil {
                            currentToolName = nil
                        }
                    }
                },
                onComplete: {
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
                        guard cancellingToolRequestStageID != requestStageID else { return }
                        // Save immediately on completion
                        if let index = conversationManager.conversations
                            .firstIndex(where: { $0.id == conversationId })
                        {
                            conversationManager.saveImmediately(conversationManager.conversations[index])
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
                                errorMessage = "Too many tool calls"
                                errorRecoverySuggestion = "Try again, or disable tools in Settings"
                                shouldOfferOpenSettings = true
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
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
                        let isCancellation = error is CancellationError
                            || (error as NSError).code == NSURLErrorCancelled
                        finalizePendingToolCalls(
                            result: isCancellation
                                ? "Tool call cancelled before completion."
                                : "Tool execution failed: \(error.localizedDescription)",
                            conversationId: conversationId
                        )
                        activeToolRequestStageID = nil
                        activeAIRequestOwnerID = nil
                        isGenerating = false
                        currentToolName = nil
                        toolCallDepth = 0
                        if isCancellation {
                            if let index = conversationManager.conversations.firstIndex(where: {
                                $0.id == conversationId
                            }) {
                                conversationManager.saveImmediately(conversationManager.conversations[index])
                            }
                            return
                        }
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
                    let argumentsWrapper = UncheckedSendableWrapper(arguments)
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
                        let arguments = argumentsWrapper.value
                        guard conversationManager.conversations.contains(where: { $0.id == conversationId }) else {
                            logNewChat(
                                "⚠️ Tool call requested but conversation \(conversationId) no longer exists",
                                level: .error
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

                        logNewChat(
                            "🔧 Queued tool call: \(toolName)",
                            level: .info,
                            metadata: ["toolName": toolName]
                        )

                        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }),
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
                },
                onReasoning: { reasoning in
                    callbackQueue.enqueue {
                        guard activeToolRequestStageID == requestStageID else { return }
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
                        logNewChat(
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
                        currentToolName = nil
                        isGenerating = false
                        selectedConversationId = conversationId
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
                        systemPrompt: nil
                    )
                    currentToolName = nil

                    guard !Task.isCancelled,
                          activeToolRequestStageID == requestStageID
                    else { return }
                    sendMessageWithToolSupport(
                        conversation: conversationWithAssistant,
                        messages: continuationMessages,
                        model: model,
                        temperature: temperature,
                        tools: toolsWrapper.value
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
                    logNewChat(
                        "❌ Tool execution failed: \(error.localizedDescription)",
                        level: .error,
                        metadata: ["error": error.localizedDescription]
                    )
                    presentError(error)
                }
            }
            activeToolExecutionTask = toolTask
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
#endif
