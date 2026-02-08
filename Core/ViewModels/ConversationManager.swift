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

    // Performance: O(1) conversation index lookup cache
    private var conversationIndexCache: [UUID: Int] = [:]

    // Performance: Spotlight indexing debounce (3 seconds per conversation)
    private var indexingDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private let indexingDebounceDuration: Duration = .seconds(3)

    private func logManager(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.conversationManager, level: level, message: message, metadata: metadata)
    }

    // MARK: - Index Cache Management

    /// Rebuilds the entire conversation index cache. Call after bulk operations.
    private func rebuildIndexCache() {
        conversationIndexCache.removeAll(keepingCapacity: true)
        for (index, conversation) in conversations.enumerated() {
            conversationIndexCache[conversation.id] = index
        }
    }

    /// Gets the index for a conversation ID using O(1) cache lookup.
    /// Falls back to O(n) search if not in cache.
    private func getConversationIndex(for id: UUID) -> Int? {
        if let cachedIndex = conversationIndexCache[id] {
            // Verify cache is still valid
            if cachedIndex < conversations.count, conversations[cachedIndex].id == id {
                return cachedIndex
            }
            // Cache is stale, rebuild
            rebuildIndexCache()
            return conversationIndexCache[id]
        }

        // Not in cache, do linear search and cache result
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversationIndexCache[id] = index
            return index
        }

        return nil
    }

    /// Updates the cache when a conversation is inserted at a specific index.
    private func updateCacheForInsertion(at index: Int) {
        // Update all indices >= insertion point
        for idx in index ..< conversations.count {
            conversationIndexCache[conversations[idx].id] = idx
        }
    }

    /// Updates the cache when a conversation is removed.
    private func updateCacheForRemoval(id: UUID, at index: Int) {
        conversationIndexCache.removeValue(forKey: id)
        // Update all indices > removal point
        for idx in index ..< conversations.count {
            conversationIndexCache[conversations[idx].id] = idx
        }
    }

    init(
        store: EncryptedConversationStore? = nil,
        saveDebounceDuration: Duration = .milliseconds(200)
    ) {
        let effectiveStore = store ?? .shared
        self.store = effectiveStore
        self.saveDebounceDuration = saveDebounceDuration
        persistenceCoordinator = ConversationPersistenceCoordinator(
            store: effectiveStore,
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
                MemoryContextProvider.shared.removeConversationSummary(for: conversationId)
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
            var decodedFromDisk = try await store.loadConversations()

            // Validate and fix models that no longer exist
            let availableModels = AIService.shared.customModels
            let defaultModel = AIService.shared.selectedModel

            for index in decodedFromDisk.indices where !availableModels.contains(decodedFromDisk[index].model) {
                // Model no longer exists, update to default
                decodedFromDisk[index].model = defaultModel
                let conversationToSave = decodedFromDisk[index]
                Task {
                    try? await store.save(conversationToSave)
                }
            }

            // Dirty-wins reconciliation:
            // - Disk is the authoritative snapshot for non-dirty conversations
            // - In-memory wins for conversations that have pending saves queued
            let dirtyIds = await persistenceCoordinator.pendingConversationIds()
            let memoryById = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
            let diskById = Dictionary(uniqueKeysWithValues: decodedFromDisk.map { ($0.id, $0) })

            var reconciled: [Conversation] = []
            reconciled.reserveCapacity(max(memoryById.count, diskById.count))

            // Start from disk snapshot
            for diskConversation in decodedFromDisk {
                if dirtyIds.contains(diskConversation.id), let memoryConversation = memoryById[diskConversation.id] {
                    reconciled.append(memoryConversation)
                } else {
                    reconciled.append(diskConversation)
                }
            }

            // Add any dirty in-memory conversations not present on disk yet (e.g., newly created)
            for dirtyId in dirtyIds {
                if diskById[dirtyId] == nil, let memoryConversation = memoryById[dirtyId] {
                    reconciled.append(memoryConversation)
                }
            }

            // Sort by updated date descending to ensure correct order
            reconciled.sort { $0.updatedAt > $1.updatedAt }

            conversations = reconciled

            // If selected conversation no longer exists, clear selection
            if let selectedId = selectedConversationId,
               !conversations.contains(where: { $0.id == selectedId })
            {
                selectedConversationId = nil
            }

            // Rebuild the index cache after loading and sorting
            rebuildIndexCache()

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
            do {
                try store.clear()
            } catch {
                logManager(
                    "❌ Failed to clear corrupted store",
                    level: .error,
                    metadata: ["error": error.localizedDescription]
                )
            }
            conversations = []
            conversationIndexCache.removeAll()
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
        conversationIndexCache.removeAll()
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
        let defaultModel = AIService.shared.selectedModel
        let conversation = Conversation(title: title, model: defaultModel)
        conversations.insert(conversation, at: 0)
        updateCacheForInsertion(at: 0)
        save(conversation)
    }

    /// Start a new conversation with optional model, prompt, and system prompt.
    /// Used by deep links to create a conversation and optionally auto-send a message.
    /// - Parameters:
    ///   - model: The model to use. If nil, uses the currently selected model.
    ///   - prompt: An initial prompt to auto-send. If nil, no message is sent automatically.
    ///   - systemPrompt: A custom system prompt for this conversation. If nil, inherits global.
    /// - Returns: The created conversation.
    @discardableResult
    func startConversation(
        model: String? = nil,
        prompt: String? = nil,
        systemPrompt: String? = nil
    ) -> Conversation {
        let effectiveModel = model ?? AIService.shared.selectedModel

        // Validate model exists
        let availableModels = AIService.shared.customModels
        let validatedModel = availableModels.contains(effectiveModel)
            ? effectiveModel
            : AIService.shared.selectedModel

        var conversation = Conversation(
            title: "New Conversation",
            model: validatedModel
        )

        // Set system prompt mode
        if let systemPrompt, !systemPrompt.isEmpty {
            conversation.systemPromptMode = .custom(systemPrompt)
        }

        // Set pending auto-send prompt (will be picked up by the chat view)
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
                "hasSystemPrompt": "\(systemPrompt != nil)"
            ]
        )

        return conversation
    }

    func deleteConversation(_ conversation: Conversation) {
        if let index = getConversationIndex(for: conversation.id) {
            let id = conversation.id
            conversations.remove(at: index)
            updateCacheForRemoval(id: id, at: index)
            MemoryContextProvider.shared.removeConversationSummary(for: id)
            Task {
                try? await store.delete(id)
                #if !os(watchOS)
                    deindexConversation(id: id)
                #endif
            }
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
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].updateLastMessage(content)
            save(conversations[index])
        }
    }

    func updateMessage(in conversation: Conversation, messageId: UUID, update: (inout Message) -> Void) {
        if let convIndex = getConversationIndex(for: conversation.id),
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
        if let index = getConversationIndex(for: id) {
            return conversations[index]
        }
        return nil
    }

    /// Safely update a message by IDs. Returns true if update succeeded.
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
        guard let convIndex = getConversationIndex(for: conversationId),
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
        guard let convIndex = getConversationIndex(for: conversationId),
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

    // MARK: - Multi-Model Support

    /// Toggles multi-model mode for a conversation
    func setMultiModelEnabled(for conversation: Conversation, enabled: Bool) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].multiModelEnabled = enabled
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Sets the active models for multi-model parallel queries
    func setActiveModels(for conversation: Conversation, models: [String]) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].activeModels = models
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Adds multiple messages and a response group atomically.
    /// This ensures the UI updates once with all data ready, preventing visual glitches
    /// where multi-model responses appear as separate messages briefly.
    func addMultiModelResponse(
        to conversation: Conversation,
        messages: [Message],
        responseGroup: ResponseGroup
    ) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            // Add all messages
            for message in messages {
                conversations[index].messages.append(message)
            }
            // Add the response group
            conversations[index].addResponseGroup(responseGroup)
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    /// Adds a response group to track parallel responses
    func addResponseGroup(to conversation: Conversation, group: ResponseGroup) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].addResponseGroup(group)
            save(conversations[index])
        }
    }

    /// Updates a response group (e.g., when streaming completes)
    func updateResponseGroup(in conversation: Conversation, group: ResponseGroup) {
        if let index = getConversationIndex(for: conversation.id) {
            conversations[index].updateResponseGroup(group)
            save(conversations[index])
        }
    }

    /// Selects a response from a response group, enabling deferred tool execution
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

    // MARK: - Attach from App Context

    #if os(macOS)
        /// Creates a new conversation with app context from "Attach from App" feature.
        /// - Parameters:
        ///   - appName: The name of the source application
        ///   - windowTitle: The window title (optional)
        ///   - contentType: The type of content extracted
        ///   - content: The extracted content
        ///   - userMessage: The user's question about the content
        /// - Returns: The created conversation
        @discardableResult
        func createConversationWithContext(
            appName: String,
            windowTitle: String?,
            contentType: String,
            content: String,
            userMessage: String
        ) -> Conversation {
            let defaultModel = AIService.shared.selectedModel

            // Build the system message with context
            var systemContent = """
            You have been given context from the user's \(appName) application.
            """

            if let windowTitle, !windowTitle.isEmpty {
                systemContent += "\n\nWindow: \(windowTitle)"
            }

            systemContent += "\nContent Type: \(contentType)"
            systemContent += "\n\n---\n\(content)\n---"
            systemContent += "\n\nAnswer the user's question based on this context."

            // Create conversation with custom system prompt
            var conversation = Conversation(title: "New Conversation", model: defaultModel)
            conversation.systemPromptMode = .custom(systemContent)

            // Add the user message
            let message = Message(role: .user, content: userMessage)
            conversation.addMessage(message)

            // Insert and save
            conversations.insert(conversation, at: 0)
            save(conversation)

            // Select the new conversation
            selectedConversationId = conversation.id

            logManager(
                "✅ Created conversation with app context",
                level: .info,
                metadata: [
                    "appName": appName,
                    "contentType": contentType,
                    "contentLength": "\(content.count)"
                ]
            )

            // Post notification to trigger AI response in the view
            // Delay slightly to allow SwiftUI to instantiate the new MacChatView
            let conversationId = conversation.id
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                NotificationCenter.default.post(
                    name: .sendPendingMessage,
                    object: nil,
                    userInfo: ["conversationId": conversationId]
                )
            }

            return conversation
        }
    #endif

    private func generateTitle(for conversation: Conversation) {
        guard let firstMessage = conversation.messages.first(where: { $0.role == .user }) else {
            return
        }

        // Skip AI title generation for image generation models - use fallback instead
        let modelCapability = AIService.shared.getModelCapability(conversation.model)
        if modelCapability == .imageGeneration {
            // Use simple fallback title for image generation conversations
            let content = firstMessage.content
            let fallbackTitle = String(content.prefix(50))
            renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
            return
        }

        let content = firstMessage.content

        // Use AI to generate a concise title using the same model as the conversation
        let titlePrompt = "Generate a very short title (3-5 words maximum) for a conversation that starts with: \"\(content.prefix(200))\". Only respond with the title, nothing else."

        let titleMessage = Message(role: .user, content: titlePrompt)

        let accumulator = TitleAccumulator()

        AIService.shared.sendMessage(
            messages: [titleMessage],
            model: conversation.model,
            stream: false,
            onChunk: { chunk in
                Task { await accumulator.append(chunk) }
            },
            onComplete: { [weak self] in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    // Use the AI-generated title, trimmed and cleaned
                    let accumulatedTitle = await accumulator.getTitle()
                    let cleanTitle = accumulatedTitle
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "\n", with: " ")

                    if !cleanTitle.isEmpty {
                        self.renameConversation(conversation, newTitle: cleanTitle)
                    } else {
                        // Fallback to simple title if empty
                        let fallbackTitle = String(content.prefix(50))
                        self.renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
                    }
                }
            },
            onError: { [weak self] error in
                let selfRef = self
                Task { @MainActor in
                    guard let self = selfRef else { return }
                    // Fallback to simple title if AI fails
                    self.logManager(
                        "⚠️ Failed to generate AI title",
                        level: .error,
                        metadata: ["error": error.localizedDescription, "conversationId": conversation.id.uuidString]
                    )
                    let fallbackTitle = String(content.prefix(50))
                    self.renameConversation(conversation, newTitle: fallbackTitle + (content.count > 50 ? "..." : ""))
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

        /// Index a conversation with debouncing to avoid excessive Spotlight updates during streaming.
        /// Uses a 3-second debounce per conversation to coalesce rapid updates.
        private func indexConversation(_ conversation: Conversation) {
            let conversationId = conversation.id

            // Cancel any existing debounce task for this conversation
            indexingDebounceTasks[conversationId]?.cancel()

            // Create new debounced indexing task
            indexingDebounceTasks[conversationId] = Task { @MainActor in
                // Wait for debounce duration
                do {
                    try await Task.sleep(for: indexingDebounceDuration)
                } catch {
                    // Task was cancelled, don't index
                    return
                }

                // Clean up the task reference
                indexingDebounceTasks.removeValue(forKey: conversationId)

                // Get the latest version of the conversation
                guard let latestConversation = getConversationIndex(for: conversationId)
                    .map({ conversations[$0] })
                else {
                    return
                }

                // Perform the actual indexing on a background thread
                let conversationCopy = latestConversation
                Task.detached(priority: .utility) {
                    let item = ConversationManager.createSearchableItem(for: conversationCopy)

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
        }

        /// Index a conversation immediately without debouncing.
        /// Used for final saves when streaming completes or conversation is deleted.
        private func indexConversationImmediately(_ conversation: Conversation) {
            // Cancel any pending debounced task
            indexingDebounceTasks[conversation.id]?.cancel()
            indexingDebounceTasks.removeValue(forKey: conversation.id)

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
            // Cancel any pending indexing task for this conversation
            indexingDebounceTasks[id]?.cancel()
            indexingDebounceTasks.removeValue(forKey: id)

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
                let searchQuery = CSSearchQuery(queryString: queryString, queryContext: nil)
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

/// Helper actor for thread-safe title generation
private actor TitleAccumulator {
    var title = ""

    func append(_ chunk: String) {
        title += chunk
    }

    func getTitle() -> String {
        title
    }
}
