// swiftformat:options --ifdef no-indent
#if os(macOS)

import AppKit
import OSLog
import SwiftUI

extension MacChatView {
    enum ExportFormat {
        case markdown
        case pdf
    }

    func consumePendingSendIfNeeded() {
        guard !isGenerating,
              sendPreparationTask == nil,
              conversationManager.hasPendingSend(for: conversation.id)
        else { return }

        let messages = currentConversation.messages
        guard let lastMessage = messages.last,
              lastMessage.role == .user,
              !messages.contains(where: { $0.role == .assistant })
        else {
            _ = conversationManager.consumePendingSend(for: conversation.id)
            return
        }

        guard conversationManager.consumePendingSend(for: conversation.id) else { return }
        logChat("📤 Auto-sending message from Work with Apps", level: .info)
        sendPendingUserMessage()
    }

    func checkAndProcessPendingPrompt() {
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

        conversationManager.conversations[index].pendingAutoSendPrompt = nil
        conversationManager.saveImmediately(conversationManager.conversations[index])
        pendingAutoSendClaim = MacPendingAutoSendClaim(
            conversationID: conversationManager.conversations[index].id,
            prompt: prompt
        )

        messageText = prompt
        beginSendMessage()
    }

    func sendPendingUserMessage() {
        guard currentConversation.messages.contains(where: { $0.role == .user }) else {
            return
        }

        isGenerating = true

        var messagesToSend = currentConversation.getEffectiveHistory()
        if let systemPrompt = buildFullSystemPrompt(for: currentConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        let assistantMessage = Message(role: .assistant, content: "", model: currentConversation.model)
        conversationManager.addMessage(to: conversation, message: assistantMessage)

        let tools = aiService.getAllAvailableTools()

        sendMessageWithToolSupport(
            messages: messagesToSend,
            model: currentConversation.model,
            temperature: currentConversation.temperature,
            tools: tools,
            isInitialRequest: true,
            assistantMessageID: assistantMessage.id
        )
    }

    func exportConversation(format: ExportFormat) async {
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
        Task { @MainActor in
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
            }
        }
    }

    func resolveModelForSending(selection: String) -> String? {
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func ensureConversationModelMatchesSelection(
        _ model: String,
        expectedSelection: String
    ) {
        guard selectedModel == expectedSelection else { return }
        if currentConversation.model != model {
            conversationManager.updateModel(for: conversation, model: model)
        }
        if selectedModel != model {
            selectedModel = model
        }
    }

    func syncSelectedModelWithConversation() {
        guard
            let currentConv = conversationManager.conversations.first(where: { $0.id == conversation.id })
        else {
            return
        }

        let latest = currentConv.model
        if latest != selectedModel {
            selectedModel = latest
        }

        if currentConv.multiModelEnabled, !currentConv.activeModels.isEmpty {
            let activeSet = Set(currentConv.activeModels)
            if selectedModels != activeSet {
                selectedModels = activeSet
            }
        } else if selectedModels.isEmpty {
            if !latest.isEmpty {
                selectedModels = [latest]
            } else if let firstAvailable = aiService.usableModels.first {
                selectedModels = [firstAvailable]
                selectedModel = firstAvailable
                conversationManager.updateModel(for: conversation, model: firstAvailable)
            }
        }
    }

    func updateConversationMultiModelState() {
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            var updatedConversation = conversationManager.conversations[index]
            updatedConversation.activeModels = Array(selectedModels)
            updatedConversation.multiModelEnabled = selectedModels.count > 1
            conversationManager.updateConversation(updatedConversation)
        }
    }

    func toggleModelSelection(_ model: String) {
        let multiModelEnabled = AppPreferences.multiModelSelectionEnabled

        if !multiModelEnabled {
            selectedModels = [model]
            selectedModel = model
            conversationManager.updateModel(for: conversation, model: model)
            updateConversationMultiModelState()
            return
        }

        if selectedModels.contains(model) {
            selectedModels.remove(model)
            if selectedModels.count == 1, let remaining = selectedModels.first {
                selectedModel = remaining
                conversationManager.updateModel(for: conversation, model: remaining)
            }
        } else {
            let modelCapability = aiService.getModelCapability(model)
            if let selectedType = selectedCapabilityType, modelCapability != selectedType {
                selectedModels.removeAll()
            }
            if selectedModels.count < 4 {
                selectedModels.insert(model)
                if selectedModels.count == 1 {
                    selectedModel = model
                    conversationManager.updateModel(for: conversation, model: model)
                }
            }
        }
        updateConversationMultiModelState()
    }

    func attachFile() {
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

    func removeFile(_ fileURL: URL) {
        attachedFiles.removeAll { $0 == fileURL }
    }

    func autoSelectResponseIfNeeded() {
        guard let selection = ChatTranscriptPlan.autoSelectionCandidate(in: currentConversation) else { return }

        logChat(
            "🤖 Auto-selecting response before sending new message",
            metadata: ["messageId": selection.messageId.uuidString]
        )
        conversationManager.selectResponse(
            in: currentConversation,
            groupId: selection.groupId,
            messageId: selection.messageId
        )
    }

    func retryFailedMessage() {
        guard !isGenerating, sendPreparationTask == nil,
              let payload = failedSendPayload
        else {
            return
        }

        logChat(
            "🔄 Retrying failed message",
            level: .info,
            metadata: ["messageLength": "\(payload.promptText.count)"]
        )

        errorMessage = nil
        errorRecoverySuggestion = nil

        scheduleSend(
            SendPreparation(
                promptText: payload.promptText,
                files: [],
                pastedImages: [],
                appContent: nil,
                selectedModel: payload.selectedModel,
                selectedModels: payload.selectedModels,
                activeModel: payload.activeModel,
                prebuiltUserMessage: payload.userMessage,
                consumesComposer: false
            )
        )
    }

    func dismissError() {
        failedMessage = nil
        failedSendPayload = nil
        errorMessage = nil
        errorRecoverySuggestion = nil
    }

    func clearFailedSendState() {
        failedMessage = nil
        failedSendPayload = nil
    }

    func retainFailedSendState(
        errorMessage: String,
        recoverySuggestion: String? = nil
    ) {
        failedMessage = failedSendPayload?.promptText
        self.errorMessage = errorMessage
        errorRecoverySuggestion = recoverySuggestion
    }

    func cancelOwnedGenerationForLifecycle() {
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        sendPreparationID = nil
        restorePendingAutoSendClaimIfNeeded()
        toolChainCoordinator.cancelCurrentOperation {
            finalizePersistedTextGeneration()
        }
        imageGenerationCoordinator.cancelCurrentOperation()
        clearToolChainTimeout()
        activeAssistantMessageID = nil
        activeMultiModelResponseGroupID = nil
        isGenerating = false
        currentToolName = nil
        toolCallDepth = 0
    }

    func finalizePersistedTextGeneration() {
        batchUpdateTask?.cancel()
        batchUpdateTask = nil
        let pendingText = pendingChunks.joined()
        pendingChunks.removeAll()

        let assistantMessageID = activeAssistantMessageID
        let responseGroupID = activeMultiModelResponseGroupID
        let flushedReasoning = multiModelReasoningBuffer.finishAll()
        guard assistantMessageID != nil || responseGroupID != nil || !pendingText.isEmpty || flushedReasoning,
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

    func abortOwnedTextGeneration(
        operationID: ToolChainCoordinator.OperationID,
        conversationID: UUID
    ) {
        guard toolChainCoordinator.owns(operationID, conversationID: conversationID) else { return }
        finalizePersistedTextGeneration()
        clearToolChainTimeout()
        toolChainCoordinator.cancelCurrentOperation()
        activeAssistantMessageID = nil
        activeMultiModelResponseGroupID = nil
        isGenerating = false
        currentToolName = nil
        toolCallDepth = 0
    }
}
#endif
