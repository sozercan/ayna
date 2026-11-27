import Foundation

extension ConversationManager {
    func createNewConversation(title: String = "New Conversation") {
        let defaultModel = AIService.shared.selectedModel
        let conversation = Conversation(title: title, model: defaultModel)
        conversations.insert(conversation, at: 0)
        updateCacheForInsertion(at: 0)
        save(conversation)
    }

    func insertConversationFromSync(
        _ conversation: Conversation,
        allowsRecreation: Bool = false
    ) {
        invalidateTitleRequest(for: conversation.id)
        if allowsRecreation {
            latestManagerRecreationVersionById[conversation.id] = nextReconciliationVersion()
        }
        conversations.insert(conversation, at: 0)
        updateCacheForInsertion(at: 0)
        save(conversation, allowsRecreation: allowsRecreation)
    }

    @discardableResult
    func startConversation(
        model: String? = nil,
        prompt: String? = nil,
        systemPrompt: String? = nil
    ) -> Conversation {
        let effectiveModel = model ?? AIService.shared.selectedModel

        let availableModels = AIService.shared.customModels
        let validatedModel = availableModels.contains(effectiveModel)
            ? effectiveModel
            : AIService.shared.selectedModel

        var conversation = Conversation(
            title: "New Conversation",
            model: validatedModel
        )

        if let systemPrompt, !systemPrompt.isEmpty {
            conversation.systemPromptMode = .custom(systemPrompt)
        }

        if let prompt, !prompt.isEmpty {
            conversation.pendingAutoSendPrompt = prompt
        }

        conversations.insert(conversation, at: 0)
        updateCacheForInsertion(at: 0)
        selectedConversationId = conversation.id
        save(conversation)

        logManager(
            "🔗 Started conversation via deep link",
            level: .info,
            metadata: [
                "conversationId": conversation.id.uuidString,
                "model": validatedModel,
                "hasPrompt": "\(prompt != nil)",
                "hasSystemPrompt": "\(systemPrompt != nil)",
            ]
        )

        return conversation
    }

    @discardableResult
    func deleteConversation(_ conversation: Conversation) -> Task<ConversationDeleteResult, Never>? {
        guard let index = getConversationIndex(for: conversation.id) else { return nil }

        let current = conversations[index]
        let id = current.id
        let wasSelected = selectedConversationId == id
        let wasMetadataOnly = metadataOnlyConversationIds.contains(id)
        let rollbackSearchText = metadataSearchTextById[id]
        let attachmentPaths = ownedAttachmentPaths(of: current)
        let rollbackSnapshot = resolvingInterruptedImageGeneration(in: current)
        let deletionReconciliationVersion = nextReconciliationVersion()
        latestManagerDeletionVersionById[id] = deletionReconciliationVersion

        invalidateTitleRequest(for: id)
        invalidatePendingPersistence(for: id)
        cancelFullConversationLoad(id)

        let receipt = persistenceCoordinator.delete(rollbackSnapshot)
        beginDestructivePersistenceOperation(receipt.repairToken)

        conversations.remove(at: index)
        pendingSendConversationIds.removeAll { $0 == id }
        metadataOnlyConversationIds.remove(id)
        metadataSearchTextById.removeValue(forKey: id)
        updateCacheForRemoval(id: id, at: index)
        conversationSummaryRemoveOperation(id)
        if wasSelected {
            selectedConversationId = nil
        }
        let rollbackSelectionRevision = selectionRevision

        return Task { @MainActor [weak self] in
            let result = await receipt.value
            guard let self else { return .superseded }

            switch result {
            case .deleted:
                self.finishDestructivePersistenceOperation()
                self.durableDiskBaseline.removeValue(forKey: id)
                self.metadataAttachmentPathsById.removeValue(forKey: id)
                self.attachmentDeleteOperation(attachmentPaths)
                #if !os(watchOS)
                    self.deindexConversation(
                        id: id,
                        deletionReconciliationVersion: deletionReconciliationVersion
                    )
                #endif
            case let .failed(restored, error):
                self.retainDestructiveBarrierUntilRepairSettles(receipt.repairToken)
                if self.latestManagerDeletionVersionById[id] == deletionReconciliationVersion {
                    self.latestManagerDeletionVersionById.removeValue(forKey: id)
                }
                guard let restored else {
                    self.logManager(
                        "Failed to delete conversation without a rollback snapshot",
                        level: .error,
                        metadata: ["id": id.uuidString, "error": error]
                    )
                    return result
                }
                if self.getConversationIndex(for: id) == nil {
                    let insertionIndex = min(index, self.conversations.count)
                    self.conversations.insert(restored, at: insertionIndex)
                    self.updateCacheForInsertion(at: insertionIndex)
                    if wasMetadataOnly {
                        self.metadataOnlyConversationIds.insert(id)
                    }
                    if let rollbackSearchText {
                        self.metadataSearchTextById[id] = rollbackSearchText
                    }
                    self.conversationSummaryUpdateOperation(restored)
                    var restoredSelection = false
                    if wasSelected, self.selectionRevision == rollbackSelectionRevision {
                        self.selectedConversationId = id
                        restoredSelection = true
                    }
                    #if !os(watchOS)
                        self.indexConversation(restored)
                    #endif
                    if restoredSelection {
                        NotificationCenter.default.post(
                            name: .conversationDeleteRolledBack,
                            object: nil,
                            userInfo: ["conversationId": id]
                        )
                    }
                }
                self.logManager(
                    "Failed to delete conversation; restored it in the UI",
                    level: .error,
                    metadata: ["id": id.uuidString, "error": error]
                )
            case .superseded:
                self.retainDestructiveBarrierUntilRepairSettles(receipt.repairToken)
            }
            return result
        }
    }

    func updateConversation(_ conversation: Conversation) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index] = conversation
            save(conversation)
        }
    }

    func renameConversation(_ conversation: Conversation, newTitle: String) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].title = newTitle
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func addMessage(to conversation: Conversation, message: Message) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].addMessage(message)

            let autoGenerateTitle = AppPreferences.storage.object(forKey: "autoGenerateTitle") as? Bool ?? true
            let userMessageCount = conversations[index].messages.count(where: { $0.role == .user })
            let currentTitle = conversations[index].title

            if autoGenerateTitle,
               userMessageCount == 1,
               currentTitle == "New Conversation",
               message.role == .user
            {
                generateTitle(for: conversations[index])
            }

            save(conversations[index])
        }
    }

    func updateLastMessage(in conversation: Conversation, content: String) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].updateLastMessage(content)
            save(conversations[index])
        }
    }

    @discardableResult
    func updateMessage(
        in conversation: Conversation,
        messageId: UUID,
        update: (inout Message) -> Void
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversation.id),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        modifyConversation(at: convIndex) { conversation in
            update(&conversation.messages[msgIndex])
            conversation.updatedAt = Date()
        }
        save(conversations[convIndex])
        return true
    }

    func conversation(byId id: UUID) -> Conversation? {
        if metadataOnlyConversationIds.contains(id) {
            scheduleFullConversationLoadIfNeeded(id)
        }

        if let index = getConversationIndex(for: id) {
            return conversations[index]
        }
        return nil
    }

    @discardableResult
    func updateMessage(
        conversationId: UUID,
        messageId: UUID,
        update: (inout Message) -> Void
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        modifyConversation(at: convIndex) { conversation in
            update(&conversation.messages[msgIndex])
            conversation.updatedAt = Date()
        }
        return true
    }

    @discardableResult
    func appendToMessage(
        conversationId: UUID,
        messageId: UUID,
        chunk: String
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        modifyConversation(at: convIndex) { conversation in
            conversation.messages[msgIndex].content += chunk
            conversation.updatedAt = Date()
        }
        return true
    }

    @discardableResult
    func removeMessage(
        conversationId: UUID,
        messageId: UUID
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        conversations[convIndex].messages.remove(at: msgIndex)
        conversations[convIndex].updatedAt = Date()
        return true
    }

    @discardableResult
    func updateResponseGroupStatus(
        conversationId: UUID,
        responseGroupId: UUID,
        messageId: UUID,
        status: ResponseGroupStatus
    ) -> Bool {
        guard let convIndex = getConversationIndex(for: conversationId),
              var group = conversations[convIndex].getResponseGroup(responseGroupId)
        else {
            return false
        }
        group.updateStatus(for: messageId, status: status)
        conversations[convIndex].updateResponseGroup(group)
        return true
    }

    func clearMessages(in conversation: Conversation) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].messages.removeAll()
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    @discardableResult
    func editMessage(in conversation: Conversation, messageId: UUID, newContent: String) -> Bool {
        guard let convIndex = getConversationIndex(for: conversation.id),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId }),
              conversations[convIndex].messages[msgIndex].role == .user
        else {
            logManager(
                "⚠️ Cannot edit message - not found or not a user message",
                level: .default,
                metadata: ["messageId": messageId.uuidString]
            )
            return false
        }

        guard conversations[convIndex].messages[msgIndex].content != newContent else {
            return true
        }

        let nextIndex = conversations[convIndex].messages.index(after: msgIndex)
        if nextIndex < conversations[convIndex].messages.endIndex {
            conversations[convIndex].messages.removeSubrange(nextIndex...)
        }

        conversations[convIndex].messages[msgIndex].content = newContent
        conversations[convIndex].messages[msgIndex].isEdited = true
        conversations[convIndex].messages[msgIndex].editedAt = Date()
        conversations[convIndex].updatedAt = Date()
        save(conversations[convIndex])

        logManager(
            "✏️ Message edited",
            level: .info,
            metadata: [
                "conversationId": conversation.id.uuidString,
                "messageId": messageId.uuidString,
            ]
        )

        return true
    }

    func updateModel(for conversation: Conversation, model: String) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].model = model
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func updateSystemPromptMode(for conversation: Conversation, mode: SystemPromptMode) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].systemPromptMode = mode
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func setMultiModelEnabled(for conversation: Conversation, enabled: Bool) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].multiModelEnabled = enabled
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func setActiveModels(for conversation: Conversation, models: [String]) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].activeModels = models
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func beginMultiModelResponse(
        to conversation: Conversation,
        messages: [Message],
        responseGroup: ResponseGroup
    ) -> Conversation? {
        guard let index = getConversationIndex(for: conversation.id) else { return nil }

        conversations[index].removeFailedResponseGroups(for: responseGroup.userMessageId)
        conversations[index].messages.append(contentsOf: messages)
        conversations[index].addResponseGroup(responseGroup)
        save(conversations[index])
        return conversations[index]
    }

    func updateResponseGroup(in conversation: Conversation, group: ResponseGroup) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].updateResponseGroup(group)
            save(conversations[index])
        }
    }

    func selectResponse(in conversation: Conversation, groupId: UUID, messageId: UUID) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].selectResponse(in: groupId, messageId: messageId)
            conversations[index].updatedAt = Date()
            save(conversations[index])

            logManager(
                "✅ Selected response in multi-model group",
                level: .info,
                metadata: [
                    "conversationId": conversation.id.uuidString,
                    "groupId": groupId.uuidString,
                    "selectedMessageId": messageId.uuidString,
                ]
            )
        }
    }

    func getEffectiveHistory(for conversation: Conversation) -> [Message] {
        conversation.getEffectiveHistory()
    }

    func isPartOfResponseGroup(message: Message, in conversation: Conversation) -> Bool {
        guard let groupId = message.responseGroupId else { return false }
        return conversation.getResponseGroup(groupId) != nil
    }

    func getResponsesInGroup(groupId: UUID, in conversation: Conversation) -> [Message] {
        conversation.messages.filter { $0.responseGroupId == groupId }
    }

    func hasSelection(groupId: UUID, in conversation: Conversation) -> Bool {
        conversation.getResponseGroup(groupId)?.hasSelection ?? false
    }

    func effectiveSystemPrompt(for conversation: Conversation) -> String? {
        switch conversation.systemPromptMode {
        case .inheritGlobal:
            let global = AppPreferences.globalSystemPrompt
            return global.isEmpty ? nil : global
        case let .custom(prompt):
            return prompt.isEmpty ? nil : prompt
        case .disabled:
            return nil
        }
    }

    func queuePendingSend(for conversationId: UUID) {
        guard !pendingSendConversationIds.contains(conversationId) else { return }
        pendingSendConversationIds.append(conversationId)
    }

    @discardableResult
    func consumePendingSend(for conversationId: UUID) -> Bool {
        guard let index = pendingSendConversationIds.firstIndex(of: conversationId) else {
            return false
        }
        pendingSendConversationIds.remove(at: index)
        return true
    }

    func hasPendingSend(for conversationId: UUID) -> Bool {
        pendingSendConversationIds.contains(conversationId)
    }

    #if os(macOS)
        @discardableResult
        func createConversationWithContext(
            appName: String,
            windowTitle: String?,
            contentType: String,
            content: String,
            userMessage: String
        ) -> Conversation {
            let defaultModel = AIService.shared.selectedModel

            var systemContent = """
            You have been given context from the user's \(appName) application.
            """

            if let windowTitle, !windowTitle.isEmpty {
                systemContent += "\n\nWindow: \(windowTitle)"
            }

            systemContent += "\nContent Type: \(contentType)"
            systemContent += "\n\n---\n\(content)\n---"
            systemContent += "\n\nAnswer the user's question based on this context."

            var conversation = Conversation(title: "New Conversation", model: defaultModel)
            conversation.systemPromptMode = .custom(systemContent)

            let message = Message(role: .user, content: userMessage)
            conversation.addMessage(message)

            conversations.insert(conversation, at: 0)
            updateCacheForInsertion(at: 0)
            save(conversation)

            selectedConversationId = conversation.id
            queuePendingSend(for: conversation.id)

            logManager(
                "✅ Created conversation with app context",
                level: .info,
                metadata: [
                    "appName": appName,
                    "contentType": contentType,
                    "contentLength": "\(content.count)",
                ]
            )

            return conversation
        }
    #endif
}
