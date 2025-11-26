//
//  ConversationManager.swift
//  ayna
//
//  Created on 11/2/25.
//

import CloudKit
import Combine
import CoreSpotlight
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ConversationManager: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationId: UUID?

    static let newConversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let store: EncryptedConversationStore
    private let persistenceCoordinator: ConversationPersistenceCoordinator
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
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
            // iCloud sync disabled for free developer account
            // await syncWithCloud()
        }
    }

    // MARK: - Persistence

    func save(_ conversation: Conversation) {
        // Cancel any existing local task (for backwards compatibility)
        saveTasks[conversation.id]?.cancel()
        saveTasks.removeValue(forKey: conversation.id)

        // Delegate to the actor for thread-safe, debounced persistence
        Task {
            if !isLoaded {
                _ = await loadingTask?.value
            }

            await persistenceCoordinator.enqueueSave(conversation)
            indexConversation(conversation)
        }
    }

    func saveImmediately(_ conversation: Conversation) {
        saveTasks[conversation.id]?.cancel()
        saveTasks.removeValue(forKey: conversation.id)

        Task {
            if !isLoaded {
                _ = await loadingTask?.value
            }

            do {
                try await persistenceCoordinator.saveImmediately(conversation)
                indexConversation(conversation)
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
                // iCloud sync disabled for free developer account
                /*
                 Task.detached {
                     try? await CloudKitService.shared.delete(conversationId: conversationId)
                 }
                 */
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
            indexAllConversations()
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
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
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
        saveTasks[conversation.id]?.cancel()
        saveTasks.removeValue(forKey: conversation.id)
        Task {
            try? await store.delete(conversation.id)
            // iCloud sync disabled for free developer account
            /*
             Task.detached {
                 try? await CloudKitService.shared.delete(conversationId: conversation.id)
             }
             */
            deindexConversation(id: conversation.id)
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

    // MARK: - Search and Filter

    nonisolated func searchConversationsAsync(query: String, conversations: [Conversation]) async
        -> [Conversation]
    {
        guard !query.isEmpty else { return conversations }

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

    private func syncWithCloud() async {
        // iCloud sync disabled for free developer account
        /*
         guard let tokenData = AppPreferences.storage.data(forKey: "cloudKitChangeToken"),
               let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData) else {
             // Initial sync
             await performCloudFetch(since: nil)
             return
         }
         await performCloudFetch(since: token)
         */
    }

    private func performCloudFetch(since _: CKServerChangeToken?) async {
        // iCloud sync disabled for free developer account
        /*
         do {
             let changes = try await CloudKitService.shared.fetchChanges(since: token)
             let (changed, deleted, newToken) = (changes.changed, changes.deleted, changes.newToken)

             // Apply deletions
             for recordID in deleted {
                 if let uuid = UUID(uuidString: recordID.recordName) {
                     try? await store.delete(uuid)
                     // Also remove from memory
                     if let index = conversations.firstIndex(where: { $0.id == uuid }) {
                         conversations.remove(at: index)
                     }
                 }
             }

             // Apply changes
             for record in changed {
                 if let asset = record["encryptedData"] as? CKAsset, let fileURL = asset.fileURL {
                     // Copy file to store
                     if let uuid = UUID(uuidString: record.recordID.recordName) {
                         let destURL = store.fileURL(for: uuid)
                         try? FileManager.default.removeItem(at: destURL)
                         try? FileManager.default.copyItem(at: fileURL, to: destURL)
                     }
                 }
             }

             // Save new token
             if let newToken = newToken {
                 let data = try NSKeyedArchiver.archivedData(withRootObject: newToken, requiringSecureCoding: true)
                 AppPreferences.storage.set(data, forKey: "cloudKitChangeToken")
             }

             // Reload conversations to reflect changes
             await loadConversations()

         } catch {
             logManager("Cloud sync failed", level: .error, metadata: ["error": error.localizedDescription])
         }
         */
    }
}

// Helper class for title generation
private class TitleAccumulator: @unchecked Sendable {
    var title = ""
}
