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
    @EnvironmentObject var projectManager: ProjectManager
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

    /// Get the current conversation being created
    private var currentConversation: Conversation? {
        guard let id = currentConversationId else { return nil }
        return conversationManager.conversations.first(where: { $0.id == id })
    }

    private var selectedProject: Project? {
        guard let selectedProjectId = projectManager.selectedProjectId else { return nil }
        return projectManager.project(byId: selectedProjectId)
    }

    private var preferredProjectModel: String? {
        guard let defaultModel = selectedProject?.defaultModel?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !defaultModel.isEmpty,
            aiService.usableModels.contains(defaultModel)
        else {
            return nil
        }

        return defaultModel
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
        .onChange(of: currentConversation?.model ?? "") { _, _ in
            syncSelectedModelState()
        }
        .onChange(of: projectManager.selectedProjectId) { _, _ in
            guard currentConversation == nil else { return }
            syncSelectedModelState()
        }
        .onChange(of: projectManager.projects) { _, _ in
            guard currentConversation == nil else { return }
            syncSelectedModelState()
        }
        .onChange(of: aiService.selectedModel) { _, newValue in
            // Only follow global selection if we don't have a conversation yet
            guard currentConversation == nil else { return }
            guard preferredProjectModel == nil else { return }
            selectedModel = newValue
            selectedModels = [newValue]
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
        } else if let preferredProjectModel {
            selectedModel = preferredProjectModel
            selectedModels = [preferredProjectModel]
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
        // Save image to disk off MainActor to avoid blocking the UI
        Task {
            let imagePath = await Task.detached(priority: .userInitiated) {
                try? AttachmentStorage.shared.save(data: imageData, extension: "png")
            }.value

            if imagePath == nil {
                logNewChat("❌ Failed to save generated image to disk", level: .error)
            }

            conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                message.content = ""
                if let path = imagePath { message.imagePath = path; message.imageData = nil } else {
                    message.imageData = imageData; message.imagePath = nil
                }
            }
        }
    }

    // MARK: - Send Message

    private func sendMessage() async {
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
            let targetProject = projectManager.selectedProjectId.flatMap { projectManager.project(byId: $0) }
            let newConversation = conversationManager.createNewConversation(
                model: targetProject?.defaultModel,
                projectId: targetProject?.id
            )
            conversation = newConversation
            currentConversationId = newConversation.id
            logNewChat(
                "🆕 Created new conversation: \(newConversation.id)",
                level: .info,
                metadata: [
                    "conversationId": newConversation.id.uuidString,
                    "projectId": targetProject?.id.uuidString ?? "none"
                ]
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

        var currentMessages = updatedConversation.messages

        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            currentMessages.insert(systemMessage, at: 0)
        }

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
            userMessageId: conversation.messages.last(where: { $0.role == .user })?.id ?? UUID(),
            responses: responseEntries
        )

        // Add response group to conversation
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversationManager.conversations[index].responseGroups.append(responseGroup)
        }

        // Track completion state with actor-isolated counter
        let counter = MainActorCompletionCounter(total: models.count)

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
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
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
                    // Persist during streaming so content isn't lost on quit
                    conversationManager.save(conversationManager.conversations[convIndex])
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
        let toolsWrapper = UncheckedSendableWrapper(tools)

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

                    // Persist during streaming so content isn't lost on quit
                    conversationManager.save(conversationManager.conversations[index])

                    if currentToolName != nil {
                        currentToolName = nil
                    }
                }
            },
            onComplete: {
                Task { @MainActor in
                    // Save immediately on completion
                    if let index = conversationManager.conversations
                        .firstIndex(where: { $0.id == conversationId })
                    {
                        conversationManager.saveImmediately(conversationManager.conversations[index])
                    }

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
                let argumentsWrapper = UncheckedSendableWrapper(arguments)
                let toolNameCopy = toolName
                Task { @MainActor in
                    // Set currentToolName first thing to prevent race condition with onComplete
                    currentToolName = toolNameCopy
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
                            let isWebSearch = ToolCallHandler.isWebSearchTool(toolName)

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

                                guard let updatedConversation = conversationManager.conversations
                                    .first(where: { $0.id == conversationId })
                                else {
                                    currentToolName = nil
                                    isGenerating = false
                                    selectedConversationId = conversationId
                                    return
                                }

                                // For web_search, attach citations to the new assistant message
                                let newAssistantMessage = ToolCallHandler.createContinuationMessage(
                                    model: model,
                                    citations: isWebSearch ? citations : nil
                                )
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

                                // Build messages for API using ToolCallHandler
                                let messagesForAPI = ToolCallHandler.buildContinuationMessages(
                                    conversationMessages: convWithAssistant.messages,
                                    toolCallId: toolCallId,
                                    toolName: toolName,
                                    arguments: argumentsWrapper.value,
                                    result: result,
                                    isWebSearch: isWebSearch,
                                    systemPrompt: nil // MacNewChatView doesn't add system prompts here
                                )

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

    private func buildFullSystemPrompt(for conversation: Conversation) -> String? {
        var components: [String] = []

        if let userPrompt = conversationManager.effectiveSystemPrompt(for: conversation), !userPrompt.isEmpty {
            components.append(userPrompt)
        }

        if let agenticContext = aiService.getAgenticSystemPromptContext() {
            components.append(agenticContext)
        }

        return components.isEmpty ? nil : components.joined(separator: "\n\n")
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
