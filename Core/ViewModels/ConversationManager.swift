//
//  ConversationManager.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
#if !os(watchOS)
    import CoreSpotlight
#endif
import Foundation
import OSLog
import SwiftUI
#if !os(watchOS)
    import UniformTypeIdentifiers
#endif

@MainActor
final class ConversationManager: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationId: UUID?

    static let newConversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let store: EncryptedConversationStore
    private let persistenceCoordinator: ConversationPersistenceCoordinator
    var loadingTask: Task<Void, Never>?
    private var isLoaded = false
    private let saveDebounceDuration: Duration

    private func logManager(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.conversationManager, level: level, message: message, metadata: metadata)
    }

    init(
        store: EncryptedConversationStore = .shared,
        saveDebounceDuration: Duration = .milliseconds(200)
    ) {
        self.store = store
        self.saveDebounceDuration = saveDebounceDuration
        persistenceCoordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: saveDebounceDuration
        )
        loadingTask = Task {
            await loadConversations()
        }

        // Listen for save failures to reload data from disk
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSaveFailure(_:)),
            name: .conversationSaveFailed,
            object: nil
        )
    }

    @objc private func handleSaveFailure(_ notification: Notification) {
        guard let conversationId = notification.userInfo?["conversationId"] as? UUID else { return }

        logManager(
            "🔄 Reloading conversations after save failure",
            level: .info,
            metadata: ["failedId": conversationId.uuidString]
        )

        // Reload all conversations from disk to restore consistent state
        Task {
            await loadConversations()
        }
    }

    // MARK: - Persistence

    func save(_ conversation: Conversation) {
        // Delegate to the actor for thread-safe, debounced persistence
        Task {
            if !isLoaded {
                _ = await loadingTask?.value
            }

            await persistenceCoordinator.enqueueSave(conversation)
            #if !os(watchOS)
                indexConversation(conversation)
            #endif
        }
    }

    @discardableResult
    func saveImmediately(_ conversation: Conversation) -> Task<Void, Never> {
        Task {
            if !isLoaded {
                _ = await loadingTask?.value
            }

            do {
                try await persistenceCoordinator.saveImmediately(conversation)
                #if !os(watchOS)
                    indexConversation(conversation)
                #endif
            } catch {
                logManager(
                    "❌ Failed to save conversation",
                    level: .error,
                    metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
                )
            }
        }
    }

    func delete(_ conversationId: UUID) {
        Task {
            do {
                try await persistenceCoordinator.delete(conversationId)
                await loadConversations()
                if selectedConversationId == conversationId {
                    selectedConversationId = nil
                }
            } catch {
                logManager(
                    "❌ Failed to delete conversation",
                    level: .error,
                    metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
                )
            }
        }
    }

    private func loadConversations() async {
        do {
            var decoded = try await store.loadConversations()

            // Validate and fix models that no longer exist
            let availableModels = OpenAIService.shared.customModels
            let defaultModel = OpenAIService.shared.selectedModel

            for index in decoded.indices where !availableModels.contains(decoded[index].model) {
                // Model no longer exists, update to default
                decoded[index].model = defaultModel
                let conversationToSave = decoded[index]
                Task {
                    try? await store.save(conversationToSave)
                }
            }

            // Merge with any conversations created while loading
            let existingIds = Set(conversations.map(\.id))
            let newFromDisk = decoded.filter { !existingIds.contains($0.id) }
            conversations.append(contentsOf: newFromDisk)

            // Sort by updated date descending to ensure correct order
            conversations.sort { $0.updatedAt > $1.updatedAt }

            isLoaded = true

            logManager(
                "✅ Loaded \(conversations.count) conversations",
                level: .info,
                metadata: ["count": "\(conversations.count)"]
            )

            // Index all conversations for Spotlight
            #if !os(watchOS)
                indexAllConversations()
            #endif
        } catch {
            logManager(
                "❌ Failed to load conversations",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            logManager("⚠️ Clearing corrupted conversation data", level: .default)
            try? store.clear()
            conversations = []
            isLoaded = true
        }
    }

    /// Public method to reload conversations from storage.
    /// Used for pull-to-refresh on iOS.
    func reloadConversations() async {
        logManager("🔄 Reloading conversations from storage", level: .info)
        await loadConversations()
    }

    func clearAllConversations() {
        conversations.removeAll()
        Task {
            // Cancel all pending saves in the coordinator
            await persistenceCoordinator.cancelAllPendingSaves()

            do {
                try store.clear()
                logManager("🧹 Cleared encrypted conversation store", level: .info)
            } catch {
                logManager(
                    "⚠️ Failed to clear conversation store",
                    level: .error,
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    func createNewConversation(title: String = "New Conversation") {
        let defaultModel = OpenAIService.shared.selectedModel
        let conversation = Conversation(title: title, model: defaultModel)
        conversations.insert(conversation, at: 0)
        save(conversation)
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        Task {
            try? await store.delete(conversation.id)
            #if !os(watchOS)
                deindexConversation(id: conversation.id)
            #endif
        }
    }

    func updateConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
            save(conversation)
        }
    }

    func renameConversation(_ conversation: Conversation, newTitle: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].title = newTitle
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func addMessage(to conversation: Conversation, message: Message) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].addMessage(message)

            // Auto-generate title from first user message
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
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].updateLastMessage(content)
            save(conversations[index])
        }
    }

    func updateMessage(in conversation: Conversation, messageId: UUID, update: (inout Message) -> Void) {
        if let convIndex = conversations.firstIndex(where: { $0.id == conversation.id }),
           let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        {
            var message = conversations[convIndex].messages[msgIndex]
            update(&message)
            conversations[convIndex].messages[msgIndex] = message
            conversations[convIndex].updatedAt = Date()
            save(conversations[convIndex])
        }
    }

    // MARK: - Safe ID-Based Access

    /// Safely get a conversation by ID. Returns nil if not found.
    func conversation(byId id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// Safely update a message by IDs. Returns true if update succeeded.
    @discardableResult
    func updateMessage(
        conversationId: UUID,
        messageId: UUID,
        update: (inout Message) -> Void
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationId }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        var message = conversations[convIndex].messages[msgIndex]
        update(&message)
        conversations[convIndex].messages[msgIndex] = message
        conversations[convIndex].updatedAt = Date()
        return true
    }

    /// Safely append content to a message. Returns true if update succeeded.
    @discardableResult
    func appendToMessage(
        conversationId: UUID,
        messageId: UUID,
        chunk: String
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationId }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        conversations[convIndex].messages[msgIndex].content += chunk
        return true
    }

    /// Safely remove a message by IDs. Returns true if removal succeeded.
    @discardableResult
    func removeMessage(
        conversationId: UUID,
        messageId: UUID
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationId }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId })
        else {
            return false
        }
        conversations[convIndex].messages.remove(at: msgIndex)
        conversations[convIndex].updatedAt = Date()
        return true
    }

    /// Safely update a response group status by IDs. Returns true if update succeeded.
    @discardableResult
    func updateResponseGroupStatus(
        conversationId: UUID,
        responseGroupId: UUID,
        messageId: UUID,
        status: ResponseGroupStatus
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.id == conversationId }),
              var group = conversations[convIndex].getResponseGroup(responseGroupId)
        else {
            return false
        }
        group.updateStatus(for: messageId, status: status)
        conversations[convIndex].updateResponseGroup(group)
        return true
    }

    func clearMessages(in conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].messages.removeAll()
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func updateModel(for conversation: Conversation, model: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].model = model
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func updateSystemPromptMode(for conversation: Conversation, mode: SystemPromptMode) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].systemPromptMode = mode
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    // MARK: - Multi-Model Support

    /// Toggles multi-model mode for a conversation
    func setMultiModelEnabled(for conversation: Conversation, enabled: Bool) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].multiModelEnabled = enabled
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Sets the active models for multi-model parallel queries
    func setActiveModels(for conversation: Conversation, models: [String]) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].activeModels = models
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Adds a response group to track parallel responses
    func addResponseGroup(to conversation: Conversation, group: ResponseGroup) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].addResponseGroup(group)
            save(conversations[index])
        }
    }

    /// Updates a response group (e.g., when streaming completes)
    func updateResponseGroup(in conversation: Conversation, group: ResponseGroup) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].updateResponseGroup(group)
            save(conversations[index])
        }
    }

    /// Selects a response from a response group, enabling deferred tool execution
    func selectResponse(in conversation: Conversation, groupId: UUID, messageId: UUID) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].selectResponse(in: groupId, messageId: messageId)
            conversations[index].updatedAt = Date()
            save(conversations[index])

            logManager(
                "✅ Selected response in multi-model group",
                level: .info,
                metadata: [
                    "conversationId": conversation.id.uuidString,
                    "groupId": groupId.uuidString,
                    "selectedMessageId": messageId.uuidString
                ]
            )
        }
    }

    /// Gets the effective message history for API requests, filtering out unselected responses
    func getEffectiveHistory(for conversation: Conversation) -> [Message] {
        conversation.getEffectiveHistory()
    }

    /// Checks if a message is part of a response group
    func isPartOfResponseGroup(message: Message, in conversation: Conversation) -> Bool {
        guard let groupId = message.responseGroupId else { return false }
        return conversation.getResponseGroup(groupId) != nil
    }

    /// Gets all responses in a response group
    func getResponsesInGroup(groupId: UUID, in conversation: Conversation) -> [Message] {
        conversation.messages.filter { $0.responseGroupId == groupId }
    }

    /// Checks if a response group has a selection
    func hasSelection(groupId: UUID, in conversation: Conversation) -> Bool {
        conversation.getResponseGroup(groupId)?.hasSelection ?? false
    }

    /// Resolves the effective system prompt for a conversation based on its mode.
    /// - Returns: The system prompt string, or nil if no prompt should be used.
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

    private func generateTitle(for conversation: Conversation) {
        guard let firstMessage = conversation.messages.first(where: { $0.role == .user }) else {
            return
        }

        let content = firstMessage.content

        // Use AI to generate a concise title using the same model as the conversation
        let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(content.prefix(200))\". Only respond with the title, nothing else."

        let titleMessage = Message(role: .user, content: titlePrompt)

        let accumulator = TitleAccumulator()

        OpenAIService.shared.sendMessage(
            messages: [titleMessage],
            model: conversation.model,
            stream: false,
            onChunk: { chunk in
                accumulator.title += chunk
            },
            onComplete: { [weak self] in
                Task { @MainActor in
                    // Use the AI-generated title, trimmed and cleaned
                    let cleanTitle = accumulator.title
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "\n", with: " ")

                    if !cleanTitle.isEmpty {
                        self?.renameConversation(conversation, newTitle: cleanTitle)
                    } else {
                        // Fallback to simple title if empty
                        let fallbackTitle = String(content.prefix(50))
                        self?.renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    // Fallback to simple title if AI fails
                    self?.logManager(
                        "⚠️ Failed to generate AI title",
                        level: .error,
                        metadata: ["error": error.localizedDescription, "conversationId": conversation.id.uuidString]
                    )
                    let fallbackTitle = String(content.prefix(50))
                    self?.renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                }
            },
            onReasoning: nil
        )
    }

    // MARK: - Spotlight Indexing

    #if !os(watchOS)
        private nonisolated static func createSearchableItem(for conversation: Conversation)
            -> CSSearchableItem
        {
            let attributeSet = CSSearchableItemAttributeSet(contentType: .aynaConversation)
            attributeSet.title = conversation.title
            attributeSet.displayName = conversation.title
            attributeSet.contentDescription = conversation.messages.last?.content
            attributeSet.creator = "Ayna"
            attributeSet.kind = "Conversation"
            attributeSet.containerTitle = "Ayna Conversations"
            attributeSet.authorNames = ["Ayna"]
            attributeSet.metadataModificationDate = Date()

            var keywords = ["Ayna", "Chat", "Conversation"]
            keywords.append(contentsOf: conversation.title.components(separatedBy: .whitespacesAndNewlines))
            attributeSet.keywords = keywords

            // Index full content
            let allContent = conversation.messages.map(\.content).joined(separator: "\n")
            attributeSet.textContent = allContent
            attributeSet.contentModificationDate = conversation.updatedAt

            return CSSearchableItem(
                uniqueIdentifier: conversation.id.uuidString,
                domainIdentifier: "com.sertacozercan.ayna.conversation",
                attributeSet: attributeSet
            )
        }

        private func indexConversation(_ conversation: Conversation) {
            Task.detached(priority: .utility) {
                let item = ConversationManager.createSearchableItem(for: conversation)

                do {
                    try await CSSearchableIndex.default().indexSearchableItems([item])
                } catch {
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .error,
                        message: "❌ Spotlight indexing error",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }

        private func indexAllConversations() {
            let conversationsToIndex = conversations

            Task.detached(priority: .utility) {
                do {
                    // Clear existing index first to ensure clean state
                    try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [
                        "co.ayna.conversations", "com.sertacozercan.ayna.conversation",
                    ])

                    // Proceed with indexing
                    let items = conversationsToIndex.map { ConversationManager.createSearchableItem(for: $0) }
                    try await CSSearchableIndex.default().indexSearchableItems(items)

                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .info,
                        message: "✅ Spotlight batch indexing complete",
                        metadata: ["count": "\(items.count)"]
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .error,
                        message: "❌ Spotlight batch indexing error",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }

        private func deindexConversation(id: UUID) {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id.uuidString]) { error in
                if let error {
                    Task { @MainActor in
                        self.logManager(
                            "❌ Spotlight deletion error",
                            level: .error,
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }
        }
    #endif

    // MARK: - Search and Filter

    nonisolated func searchConversationsAsync(query: String, conversations: [Conversation]) async
        -> [Conversation]
    {
        guard !query.isEmpty else { return conversations }

        #if os(watchOS)
            // watchOS doesn't have CoreSpotlight, use manual search
            return conversations.filter { conversation in
                conversation.title.localizedCaseInsensitiveContains(query)
                    || conversation.messages.contains { message in
                        message.content.localizedCaseInsensitiveContains(query)
                    }
            }
        #else
            // Use Core Spotlight for high-performance search
            let escapedQuery = query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let queryString = "textContent == \"*\(escapedQuery)*\"c"

            return await withCheckedContinuation { continuation in
                let searchQuery = CSSearchQuery(queryString: queryString, attributes: [])
                var foundIds: [String] = []

                searchQuery.foundItemsHandler = { items in
                    foundIds.append(contentsOf: items.map(\.uniqueIdentifier))
                }

                searchQuery.completionHandler = { error in
                    if let error {
                        DiagnosticsLogger.log(.conversationManager, level: .error, message: "Spotlight search failed: \(error.localizedDescription)")
                        // Fallback to manual search if Spotlight fails
                        let manualResults = conversations.filter { conversation in
                            conversation.title.localizedCaseInsensitiveContains(query)
                                || conversation.messages.contains { message in
                                    message.content.localizedCaseInsensitiveContains(query)
                                }
                        }
                        continuation.resume(returning: manualResults)
                        return
                    }

                    let ids = Set(foundIds.compactMap { UUID(uuidString: $0) })
                    // Filter the provided conversations list to ensure we only return what's currently loaded/valid
                    let results = conversations.filter { ids.contains($0.id) }
                    continuation.resume(returning: results)
                }

                searchQuery.start()
            }
        #endif
    }

    func searchConversations(query: String) -> [Conversation] {
        guard !query.isEmpty else { return conversations }

        return conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query) ||
                conversation.messages.contains { message in
                    message.content.localizedCaseInsensitiveContains(query)
                }
        }
    }

}

// Helper class for title generation
private class TitleAccumulator: @unchecked Sendable {
    var title = ""
}
