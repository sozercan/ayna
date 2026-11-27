// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

extension MacChatView {
    struct SendPreparation {
        let promptText: String
        let files: [URL]
        let pastedImages: [PastedImage]
        let appContent: AppContent?
        let selectedModel: String
        let selectedModels: Set<String>
        let activeModel: String?
        let prebuiltUserMessage: Message?
        let consumesComposer: Bool

        init(
            promptText: String,
            files: [URL],
            pastedImages: [PastedImage],
            appContent: AppContent?,
            selectedModel: String,
            selectedModels: Set<String>,
            activeModel: String?,
            prebuiltUserMessage: Message? = nil,
            consumesComposer: Bool = true
        ) {
            self.promptText = promptText
            self.files = files
            self.pastedImages = pastedImages
            self.appContent = appContent
            self.selectedModel = selectedModel
            self.selectedModels = selectedModels
            self.activeModel = activeModel
            self.prebuiltUserMessage = prebuiltUserMessage
            self.consumesComposer = consumesComposer
        }
    }

    struct FailedSendPayload {
        let promptText: String
        let userMessage: Message
        let selectedModel: String
        let selectedModels: Set<String>
        let activeModel: String
    }

    private struct PreparedSendContext {
        let activeModel: String
        let userMessage: Message
        let loadedConversation: Conversation
    }

    func beginSendMessage() {
        if isGenerating || sendPreparationTask != nil {
            logChat("🛑 Stop button clicked, cancelling...", level: .info)
            cancelOwnedGenerationForLifecycle()
            logChat("✅ isGenerating set to FALSE after stop", level: .info)
            isComposerFocused = true
            return
        }

        guard !isImportingPastedImages,
              pendingFileDropCount == 0,
              ChatDraftContent.isSendable(
                  text: messageText,
                  fileURLs: attachedFiles,
                  inMemoryImageCount: pastedImages.count
              )
        else {
            isComposerFocused = true
            return
        }

        let preparation = SendPreparation(
            promptText: messageText,
            files: attachedFiles,
            pastedImages: pastedImages,
            appContent: attachedAppContent,
            selectedModel: selectedModel,
            selectedModels: selectedModels,
            activeModel: resolveModelForSending(selection: selectedModel)
        )
        pasteImportSessionID = UUID()
        scheduleSend(preparation)
    }

    func scheduleSend(
        _ preparation: SendPreparation
    ) {
        let preparationID = UUID()
        sendPreparationID = preparationID
        isGenerating = true
        let task = Task { @MainActor in
            guard !Task.isCancelled, sendPreparationID == preparationID else { return }
            await sendMessage(preparationID: preparationID, preparation: preparation)
        }
        sendPreparationTask = task
    }

    func restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: Bool = true) {
        guard let claim = pendingAutoSendClaim else { return }
        claim.restore(in: conversationManager)
        if clearVisibleDraft {
            pendingAutoSendClaim = nil
            if messageText == claim.prompt {
                messageText = ""
            }
        }
    }

    private func consumePendingAutoSendClaim(
        afterCommitting prompt: String,
        to conversationID: UUID
    ) {
        guard let claim = pendingAutoSendClaim else { return }
        claim.consume(
            committedPrompt: prompt,
            conversationID: conversationID,
            in: conversationManager
        )
        pendingAutoSendClaim = nil
    }

    private func discardStoredAttachments(in message: Message) {
        for attachment in message.attachments ?? [] {
            if let localPath = attachment.localPath {
                AttachmentStorage.shared.delete(path: localPath)
            }
        }
    }

    private func discardStoredAttachments(
        in message: Message,
        ifOwnedByPreparation ownsStoredAttachments: Bool
    ) {
        guard ownsStoredAttachments else { return }
        discardStoredAttachments(in: message)
    }

    private func makeUserMessage(
        for preparation: SendPreparation
    ) async -> (message: Message, ownsStoredAttachments: Bool) {
        if let prebuiltUserMessage = preparation.prebuiltUserMessage {
            return (prebuiltUserMessage, false)
        }

        let message = await ChatMessageBuilder.createUserMessage(
            text: preparation.promptText,
            appContent: preparation.appContent,
            fileURLs: preparation.files,
            pastedImages: preparation.pastedImages,
            saveToStorage: true
        )
        return (message, true)
    }

    private func consumeComposer(for preparation: SendPreparation) {
        guard preparation.consumesComposer else { return }

        if messageText == preparation.promptText {
            messageText = ""
        }
        attachedFiles.removeAll { preparation.files.contains($0) }
        let pastedImageIDs = Set(preparation.pastedImages.map(\.id))
        pastedImages.removeAll { pastedImageIDs.contains($0.id) }
        if AppContent.hasSamePayload(attachedAppContent, preparation.appContent) {
            attachedAppContent = nil
        }
    }

    private func attachmentSupportError(
        files: [URL],
        pastedImages: [PastedImage],
        hasPrebuiltAttachments: Bool,
        selectedModels: Set<String>,
        activeModel: String
    ) -> String? {
        guard !files.isEmpty || !pastedImages.isEmpty || hasPrebuiltAttachments else { return nil }
        let models = selectedModels.isEmpty ? [activeModel] : Array(selectedModels)
        return aiService.attachmentSupportError(for: models)
    }

    private func isPreparationActive(_ preparationID: UUID) -> Bool {
        sendPreparationID == preparationID && !Task.isCancelled
    }

    private func sendMessage(
        preparationID: UUID,
        preparation: SendPreparation
    ) async {
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

        guard let context = await prepareAndValidateSend(
            preparationID: preparationID,
            preparation: preparation
        ) else {
            return
        }

        commitPreparedUserMessage(context: context, preparation: preparation)

        guard let updatedConversation = conversationManager.conversations.first(where: {
            $0.id == conversation.id
        }) else {
            return
        }

        handedOff = await dispatchPreparedSend(
            context: context,
            preparationID: preparationID,
            preparation: preparation,
            updatedConversation: updatedConversation
        )
    }

    private func prepareAndValidateSend(
        preparationID: UUID,
        preparation: SendPreparation
    ) async -> PreparedSendContext? {
        guard isPreparationActive(preparationID) else { return nil }

        guard await ConversationSendPreflight.loadConversationHistory(
            conversationId: conversation.id,
            manager: conversationManager
        ) != nil else {
            guard isPreparationActive(preparationID) else { return nil }
            logChat(
                "❌ Failed to load conversation before sending",
                level: .error,
                metadata: ["conversationId": conversation.id.uuidString]
            )
            errorMessage = "Unable to load this conversation's history. Try again."
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return nil
        }
        guard isPreparationActive(preparationID) else { return nil }

        autoSelectResponseIfNeeded()

        guard let activeModel = validateModelAndAttachments(for: preparation) else {
            return nil
        }

        ensureConversationModelMatchesSelection(
            activeModel,
            expectedSelection: preparation.selectedModel
        )
        logChat(
            "🎯 Sending message with model \(activeModel)",
            level: .info,
            metadata: ["model": activeModel]
        )

        return await buildAndValidateUserMessage(
            preparationID: preparationID,
            preparation: preparation,
            activeModel: activeModel
        )
    }

    private func validateModelAndAttachments(for preparation: SendPreparation) -> String? {
        guard let activeModel = preparation.activeModel else {
            logChat("❌ Cannot send message: no model selected", level: .error)
            errorMessage = "Select a model in Settings → Model."
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return nil
        }

        if let supportError = attachmentSupportError(
            files: preparation.files,
            pastedImages: preparation.pastedImages,
            hasPrebuiltAttachments: preparation.prebuiltUserMessage?.attachments?.isEmpty == false,
            selectedModels: preparation.selectedModels,
            activeModel: activeModel
        ) {
            errorMessage = supportError
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return nil
        }

        return activeModel
    }

    private func buildAndValidateUserMessage(
        preparationID: UUID,
        preparation: SendPreparation,
        activeModel: String
    ) async -> PreparedSendContext? {
        let userMessageBuild = await makeUserMessage(for: preparation)
        let userMessage = userMessageBuild.message
        let ownsStoredAttachments = userMessageBuild.ownsStoredAttachments
        guard isPreparationActive(preparationID) else {
            discardStoredAttachments(in: userMessage, ifOwnedByPreparation: ownsStoredAttachments)
            return nil
        }

        guard validateBuiltUserMessage(
            userMessage,
            preparation: preparation,
            activeModel: activeModel,
            ownsStoredAttachments: ownsStoredAttachments
        ) else {
            return nil
        }

        guard let loadedConversation = await ConversationSendPreflight.loadConversationHistory(
            conversationId: conversation.id,
            manager: conversationManager
        ) else {
            discardStoredAttachments(in: userMessage, ifOwnedByPreparation: ownsStoredAttachments)
            guard isPreparationActive(preparationID) else { return nil }
            logChat(
                "❌ Conversation changed while preparing attachments",
                level: .error,
                metadata: ["conversationId": conversation.id.uuidString]
            )
            errorMessage = "Unable to load this conversation's history. Try again."
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return nil
        }
        guard isPreparationActive(preparationID) else {
            discardStoredAttachments(in: userMessage, ifOwnedByPreparation: ownsStoredAttachments)
            return nil
        }

        let requestModels = preparation.selectedModels.isEmpty
            ? [activeModel]
            : Array(preparation.selectedModels)
        let requestMessages = ChatDraftContent.messagesByIncludingUserMessageIfNeeded(
            userMessage,
            in: loadedConversation.messages
        )
        let validationFailure = await ConversationSendPreflight.attachmentFailure(
            models: requestModels,
            messages: requestMessages,
            aiService: aiService,
            loadAttachmentData: { path in
                await AttachmentStorage.shared.loadData(path: path)
            }
        )
        guard isPreparationActive(preparationID) else {
            discardStoredAttachments(in: userMessage, ifOwnedByPreparation: ownsStoredAttachments)
            return nil
        }
        if let validationFailure {
            discardStoredAttachments(in: userMessage, ifOwnedByPreparation: ownsStoredAttachments)
            errorMessage = validationFailure.message
            errorRecoverySuggestion = validationFailure.recoverySuggestion
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return nil
        }

        return PreparedSendContext(
            activeModel: activeModel,
            userMessage: userMessage,
            loadedConversation: loadedConversation
        )
    }

    private func validateBuiltUserMessage(
        _ userMessage: Message,
        preparation: SendPreparation,
        activeModel: String,
        ownsStoredAttachments: Bool
    ) -> Bool {
        if preparation.prebuiltUserMessage == nil,
           let failure = ConversationSendPreflight.unreadableAttachmentFailure(
               models: preparation.selectedModels.isEmpty ? [activeModel] : Array(preparation.selectedModels),
               selectedAttachmentCount: preparation.files.count + preparation.pastedImages.count,
               builtAttachmentCount: userMessage.attachments?.count ?? 0,
               aiService: aiService
           )
        {
            discardStoredAttachments(in: userMessage, ifOwnedByPreparation: ownsStoredAttachments)
            errorMessage = failure.message
            errorRecoverySuggestion = failure.recoverySuggestion
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return false
        }

        guard ChatDraftContent.isSendable(
            text: userMessage.content,
            attachments: userMessage.attachments ?? []
        ) else {
            discardStoredAttachments(in: userMessage, ifOwnedByPreparation: ownsStoredAttachments)
            errorMessage = "Unable to load a supported image attachment."
            errorRecoverySuggestion = "Choose a JPEG, PNG, GIF, or WebP image and try again."
            restorePendingAutoSendClaimIfNeeded(clearVisibleDraft: false)
            return false
        }

        return true
    }

    private func commitPreparedUserMessage(
        context: PreparedSendContext,
        preparation: SendPreparation
    ) {
        let userMessage = context.userMessage
        let reusesCommittedUserMessage = context.loadedConversation.messages.contains {
            $0.id == userMessage.id
        }

        if let appContent = preparation.appContent {
            logChat(
                "📎 Including app content in message",
                level: .info,
                metadata: [
                    "appName": appContent.appName,
                    "contentType": appContent.contentType.displayName,
                    "contentLength": "\(appContent.content.count)"
                ]
            )
        }

        logChat(
            reusesCommittedUserMessage
                ? "🔄 Reusing committed user message"
                : "📨 Creating message with \(userMessage.attachments?.count ?? 0) attachments",
            level: .info,
            metadata: ["attachmentCount": "\(userMessage.attachments?.count ?? 0)"]
        )
        if !reusesCommittedUserMessage {
            conversationManager.addMessage(to: conversation, message: userMessage)
            consumePendingAutoSendClaim(
                afterCommitting: preparation.promptText,
                to: conversation.id
            )

            if let memoryResponse = MemoryContextProvider.shared.processMemoryCommand(in: userMessage.content) {
                logChat("💾 Memory command processed: \(memoryResponse)", level: .info)
            }

            consumeComposer(for: preparation)
        }
        isComposerFocused = true
        errorMessage = nil
        errorRecoverySuggestion = nil
        failedMessage = preparation.promptText
        failedSendPayload = FailedSendPayload(
            promptText: preparation.promptText,
            userMessage: userMessage,
            selectedModel: preparation.selectedModel,
            selectedModels: preparation.selectedModels,
            activeModel: context.activeModel
        )
        logChat("🔄 isGenerating set to TRUE", level: .info)
    }

    private func dispatchPreparedSend(
        context: PreparedSendContext,
        preparationID: UUID,
        preparation: SendPreparation,
        updatedConversation: Conversation
    ) async -> Bool {
        let activeModel = context.activeModel
        let selectedModelsToSend = preparation.selectedModels
        let modelCapability = aiService.getModelCapability(activeModel)

        if modelCapability == .imageGeneration {
            if selectedModelsToSend.count >= 2 {
                generateMultiModelImages(prompt: preparation.promptText, models: Array(selectedModelsToSend))
            } else {
                generateImage(prompt: preparation.promptText, model: activeModel)
            }
            return true
        }

        if selectedModelsToSend.count >= 2 {
            sendMultiModelMessage(
                userMessageId: context.userMessage.id,
                models: Array(selectedModelsToSend),
                temperature: updatedConversation.temperature
            )
            return true
        }

        return await dispatchSingleModelTextSend(
            activeModel: activeModel,
            preparationID: preparationID
        )
    }

    private func dispatchSingleModelTextSend(
        activeModel: String,
        preparationID: UUID
    ) async -> Bool {
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

        if mcpManager.serverConfigs.contains(where: \.enabled) {
            await mcpManager.waitForPendingDiscovery()
            guard isPreparationActive(preparationID) else { return false }
        }

        guard let latestConversation = conversationManager.conversations.first(where: {
            $0.id == conversation.id
        }) else {
            return false
        }

        var messagesToSend = latestConversation.getEffectiveHistory()
        if let systemPrompt = buildFullSystemPrompt(for: latestConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        let assistantMessage = Message(role: .assistant, content: "", model: activeModel)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        let tools = aiService.getAllAvailableTools()
        logAvailableTools(tools)

        toolCallDepth = 0
        autoSelectResponseIfNeeded()

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: activeModel,
            temperature: latestConversation.temperature,
            tools: tools,
            isInitialRequest: true,
            assistantMessageID: assistantMessage.id
        )
        return true
    }

    private func logAvailableTools(_ tools: [[String: Any]]?) {
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
    }
}
#endif
