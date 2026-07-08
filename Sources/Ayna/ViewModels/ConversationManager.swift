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
    @Published var selectedConversationId: UUID? {
        didSet {
            guard selectedConversationId != oldValue, let selectedConversationId else { return }
            scheduleFullConversationLoadIfNeeded(selectedConversationId)
        }
    }

    static let newConversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let store: EncryptedConversationStore
    private let persistenceCoordinator: ConversationPersistenceCoordinator
    var loadingTask: Task<Void, Never>?
    private var isLoaded = false
    private let saveDebounceDuration: Duration

    // Performance: O(1) conversation index lookup cache
    private var conversationIndexCache: [UUID: Int] = [:]

    // Conversations represented by lightweight metadata only until selected/opened.
    private var metadataOnlyConversationIds: Set<UUID> = []
    private var metadataSearchTextById: [UUID: String] = [:]
    private var fullConversationLoadTasks: [UUID: Task<Void, Never>] = [:]

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
        let isMetadataBackedSnapshot = isMetadataBackedSnapshot(conversation)

        // Delegate to the actor for thread-safe, debounced persistence
        Task {
            if !isLoaded {
                _ = await loadingTask?.value
            }

            guard let conversationToSave = await conversationPreparedForPersistence(
                conversation,
                isMetadataBackedSnapshot: isMetadataBackedSnapshot
            ) else {
                return
            }

            await persistenceCoordinator.enqueueSave(conversationToSave)
            #if !os(watchOS)
                indexConversation(conversationToSave)
            #endif
        }
    }

    @discardableResult
    func saveImmediately(_ conversation: Conversation) -> Task<Void, Never> {
        let isMetadataBackedSnapshot = isMetadataBackedSnapshot(conversation)

        return Task {
            if !isLoaded {
                _ = await loadingTask?.value
            }

            guard let conversationToSave = await conversationPreparedForPersistence(
                conversation,
                isMetadataBackedSnapshot: isMetadataBackedSnapshot
            ) else {
                return
            }

            do {
                try await persistenceCoordinator.saveImmediately(conversationToSave)
                #if !os(watchOS)
                    indexConversation(conversationToSave)
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

    /// Flushes all pending debounced saves immediately.
    /// Call on app termination to prevent data loss.
    func flushPendingSaves() async {
        await persistenceCoordinator.flushPendingSaves()
    }

    private func isMetadataBackedSnapshot(_ conversation: Conversation) -> Bool {
        metadataOnlyConversationIds.contains(conversation.id) || conversation.metadataPreview != nil
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
            let metadataFromDisk = try await store.loadConversationMetadata()

            // Validate and fix models that no longer exist for the in-memory list.
            let availableModels = AIService.shared.customModels
            let defaultModel = AIService.shared.selectedModel

            let dirtyIds = await persistenceCoordinator.pendingConversationIds()
            let memoryById = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, new in
                DiagnosticsLogger.log(.conversationManager, level: .default, message: "Duplicate conversation ID in memory", metadata: ["id": "\(new.id)"])
                return new
            })

            var reconciled: [Conversation] = []
            reconciled.reserveCapacity(max(memoryById.count, metadataFromDisk.count))
            var nextMetadataOnlyIds: Set<UUID> = []
            var metadataIds: Set<UUID> = []
            metadataIds.reserveCapacity(metadataFromDisk.count)

            for metadata in metadataFromDisk {
                metadataIds.insert(metadata.id)

                if dirtyIds.contains(metadata.id), let memoryConversation = memoryById[metadata.id] {
                    reconciled.append(memoryConversation)
                    continue
                }

                var placeholder = placeholderConversation(from: metadata)
                if !availableModels.contains(placeholder.model) {
                    placeholder.model = defaultModel
                }
                reconciled.append(placeholder)
                nextMetadataOnlyIds.insert(metadata.id)
            }

            // Add any dirty in-memory conversations not present on disk yet (e.g., newly created)
            for dirtyId in dirtyIds {
                if !metadataIds.contains(dirtyId), let memoryConversation = memoryById[dirtyId] {
                    reconciled.append(memoryConversation)
                }
            }

            // Sort by updated date descending to ensure correct order
            reconciled.sort { $0.updatedAt > $1.updatedAt }

            conversations = reconciled
            metadataOnlyConversationIds = nextMetadataOnlyIds
            metadataSearchTextById = Dictionary(
                uniqueKeysWithValues: metadataFromDisk.map { ($0.id, $0.searchableText) }
            )

            // If selected conversation no longer exists, clear selection
            if let selectedId = selectedConversationId,
               !conversations.contains(where: { $0.id == selectedId })
            {
                selectedConversationId = nil
            } else if let selectedId = selectedConversationId {
                scheduleFullConversationLoadIfNeeded(selectedId)
            }

            // Rebuild the index cache after loading and sorting
            rebuildIndexCache()

            isLoaded = true

            logManager(
                "✅ Loaded \(conversations.count) conversation metadata records",
                level: .info,
                metadata: ["count": "\(conversations.count)"]
            )

            // Index loaded full conversations for Spotlight; avoid replacing a rich existing
            // index with title-only metadata placeholders.
            #if !os(watchOS)
                indexAllConversations()
            #endif
        } catch {
            logManager(
                "❌ Failed to load conversations",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            if conversations.isEmpty {
                conversations = []
                metadataOnlyConversationIds.removeAll()
                metadataSearchTextById.removeAll()
                conversationIndexCache.removeAll()
            }
            isLoaded = true
        }
    }

    private func placeholderConversation(from metadata: ConversationMetadata) -> Conversation {
        Conversation(
            id: metadata.id,
            title: metadata.title,
            messages: [],
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            model: metadata.model,
            systemPromptMode: metadata.systemPromptMode,
            temperature: metadata.temperature,
            multiModelEnabled: metadata.multiModelEnabled,
            activeModels: metadata.activeModels,
            responseGroups: [],
            metadataPreview: metadata.lastMessagePreview.isEmpty ? nil : metadata.lastMessagePreview
        )
    }

    private func conversationPreparedForPersistence(
        _ proposedConversation: Conversation,
        isMetadataBackedSnapshot: Bool
    ) async -> Conversation? {
        guard isMetadataBackedSnapshot else {
            return proposedConversation
        }

        do {
            guard let loadedConversation = try await store.loadConversation(id: proposedConversation.id) else {
                logManager(
                    "⚠️ Skipping save for metadata-only conversation missing full store record",
                    level: .error,
                    metadata: ["id": proposedConversation.id.uuidString]
                )
                return nil
            }

            guard let index = getConversationIndex(for: proposedConversation.id) else {
                logManager(
                    "⚠️ Skipping metadata-only save for conversation no longer in memory",
                    level: .info,
                    metadata: ["id": proposedConversation.id.uuidString]
                )
                return nil
            }

            let latestConversation = conversations[index]
            guard metadataOnlyConversationIds.contains(proposedConversation.id)
                || latestConversation.metadataPreview != nil
            else {
                return latestConversation
            }

            let proposedIsAtLeastAsRecent = proposedConversation.updatedAt >= latestConversation.updatedAt
            let metadataSource = proposedIsAtLeastAsRecent ? proposedConversation : latestConversation
            let mergedConversation = mergeMetadataBackedChanges(
                from: metadataSource,
                into: loadedConversation
            )

            conversations[index] = mergedConversation
            metadataOnlyConversationIds.remove(proposedConversation.id)
            metadataSearchTextById.removeValue(forKey: proposedConversation.id)

            return mergedConversation
        } catch {
            logManager(
                "❌ Failed to load metadata-only conversation before save",
                level: .error,
                metadata: ["id": proposedConversation.id.uuidString, "error": error.localizedDescription]
            )
            return nil
        }
    }

    private func mergeMetadataBackedChanges(
        from proposedConversation: Conversation,
        into loadedConversation: Conversation
    ) -> Conversation {
        var mergedConversation = loadedConversation
        let proposedIsAtLeastAsRecent = proposedConversation.updatedAt >= loadedConversation.updatedAt

        if proposedIsAtLeastAsRecent {
            mergedConversation.title = proposedConversation.title
            mergedConversation.createdAt = proposedConversation.createdAt
            mergedConversation.model = proposedConversation.model
            mergedConversation.systemPromptMode = proposedConversation.systemPromptMode
            mergedConversation.temperature = proposedConversation.temperature
            mergedConversation.multiModelEnabled = proposedConversation.multiModelEnabled
            mergedConversation.activeModels = proposedConversation.activeModels
            mergedConversation.pendingAutoSendPrompt = proposedConversation.pendingAutoSendPrompt

            var existingMessageIds = Set(mergedConversation.messages.map(\.id))
            for message in proposedConversation.messages where !existingMessageIds.contains(message.id) {
                mergedConversation.messages.append(message)
                existingMessageIds.insert(message.id)
            }

            var existingResponseGroupIds = Set(mergedConversation.responseGroups.map(\.id))
            for responseGroup in proposedConversation.responseGroups where !existingResponseGroupIds.contains(responseGroup.id) {
                mergedConversation.responseGroups.append(responseGroup)
                existingResponseGroupIds.insert(responseGroup.id)
            }

            if proposedConversation.updatedAt > mergedConversation.updatedAt {
                mergedConversation.updatedAt = proposedConversation.updatedAt
            }
        }

        mergedConversation.metadataPreview = nil
        return mergedConversation
    }

    private func scheduleFullConversationLoadIfNeeded(_ conversationId: UUID) {
        guard metadataOnlyConversationIds.contains(conversationId),
              fullConversationLoadTasks[conversationId] == nil
        else {
            return
        }

        fullConversationLoadTasks[conversationId] = Task { [weak self] in
            await self?.ensureConversationLoaded(conversationId)
        }
    }

    func isMetadataOnlyConversation(_ conversationId: UUID) -> Bool {
        metadataOnlyConversationIds.contains(conversationId)
    }

    /// Loads a metadata-backed conversation's full message history if needed.
    @discardableResult
    func ensureConversationLoaded(_ conversationId: UUID) async -> Conversation? {
        defer {
            fullConversationLoadTasks.removeValue(forKey: conversationId)
        }

        guard metadataOnlyConversationIds.contains(conversationId) else {
            return conversation(byId: conversationId)
        }

        do {
            guard var loadedConversation = try await store.loadConversation(id: conversationId) else {
                return nil
            }

            let availableModels = AIService.shared.customModels
            if !availableModels.contains(loadedConversation.model) {
                loadedConversation.model = AIService.shared.selectedModel
                try? await store.save(loadedConversation)
            }

            let dirtyIds = await persistenceCoordinator.pendingConversationIds()
            guard !dirtyIds.contains(conversationId) else {
                return conversation(byId: conversationId)
            }

            if let index = getConversationIndex(for: conversationId) {
                let currentConversation = conversations[index]
                guard metadataOnlyConversationIds.contains(conversationId) else {
                    return currentConversation
                }

                let mergedConversation = mergeMetadataBackedChanges(
                    from: currentConversation,
                    into: loadedConversation
                )
                conversations[index] = mergedConversation
                metadataOnlyConversationIds.remove(conversationId)
                metadataSearchTextById.removeValue(forKey: conversationId)
                #if !os(watchOS)
                    indexConversation(mergedConversation)
                #endif
                return mergedConversation
            }

            return loadedConversation
        } catch {
            logManager(
                "❌ Failed to lazy-load conversation",
                level: .error,
                metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
            )
            return nil
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
        metadataOnlyConversationIds.removeAll()
        metadataSearchTextById.removeAll()
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

    func insertConversationFromSync(_ conversation: Conversation) {
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
            metadataOnlyConversationIds.remove(id)
            metadataSearchTextById.removeValue(forKey: id)
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
        if metadataOnlyConversationIds.contains(id) {
            scheduleFullConversationLoadIfNeeded(id)
        }

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

    /// Edits the content of a user message and marks it as edited.
    /// - Parameters:
    ///   - conversation: The conversation containing the message.
    ///   - messageId: The ID of the message to edit.
    ///   - newContent: The new content for the message.
    /// - Returns: True if the edit was successful, false if the message wasn't found or isn't editable.
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

        // Don't edit if content hasn't changed
        guard conversations[convIndex].messages[msgIndex].content != newContent else {
            return true
        }

        // Remove all messages after the edited message to avoid stale responses
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
                "messageId": messageId.uuidString
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
            updateCacheForInsertion(at: 0)
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
            tracksCurrentRequest: false,
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
            let metadataOnlyIds = metadataOnlyConversationIds
            let conversationsToIndex = conversations.filter { !metadataOnlyIds.contains($0.id) }
            let shouldResetIndex = metadataOnlyIds.isEmpty

            Task.detached(priority: .utility) {
                do {
                    if shouldResetIndex {
                        // Clear existing index only when every visible conversation is fully loaded.
                        // Metadata-only startup must not replace a rich existing index with title-only items.
                        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [
                            "co.ayna.conversations", "com.sertacozercan.ayna.conversation",
                        ])
                    }

                    guard !conversationsToIndex.isEmpty else {
                        return
                    }

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

    nonisolated static func conversationMatchesCurrentSearchText(
        _ conversation: Conversation,
        query: String,
        metadataSearchTextById: [UUID: String]
    ) -> Bool {
        conversation.title.localizedCaseInsensitiveContains(query)
            || (metadataSearchTextById[conversation.id]?.localizedCaseInsensitiveContains(query) ?? false)
            || conversation.messages.contains { message in
                message.content.localizedCaseInsensitiveContains(query)
            }
    }

    nonisolated static func metadataOnlySpotlightHitNeedsHydration(
        _ conversation: Conversation,
        query: String,
        metadataSearchTextById: [UUID: String],
        metadataOnlyConversationIds: Set<UUID>,
        spotlightIds: Set<UUID>
    ) -> Bool {
        let isMetadataOnly = metadataOnlyConversationIds.contains(conversation.id)
            || conversation.metadataPreview != nil
        guard isMetadataOnly, spotlightIds.contains(conversation.id) else {
            return false
        }

        return !conversationMatchesCurrentSearchText(
            conversation,
            query: query,
            metadataSearchTextById: metadataSearchTextById
        )
    }

    func searchConversationsAsync(query: String, conversations: [Conversation]) async
        -> [Conversation]
    {
        guard !query.isEmpty else { return conversations }
        let metadataSearchTextById = metadataSearchTextById
        let metadataOnlyConversationIds = metadataOnlyConversationIds

        #if os(watchOS)
            // watchOS doesn't have CoreSpotlight, use manual search
            return conversations.filter { conversation in
                Self.conversationMatchesCurrentSearchText(
                    conversation,
                    query: query,
                    metadataSearchTextById: metadataSearchTextById
                )
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

                searchQuery.completionHandler = { [weak self] error in
                    if let error {
                        DiagnosticsLogger.log(.conversationManager, level: .error, message: "Spotlight search failed: \(error.localizedDescription)")
                        // Fallback to manual search if Spotlight fails
                        let manualResults = conversations.filter { conversation in
                            Self.conversationMatchesCurrentSearchText(
                                conversation,
                                query: query,
                                metadataSearchTextById: metadataSearchTextById
                            )
                        }
                        continuation.resume(returning: manualResults)
                        return
                    }

                    let ids = Set(foundIds.compactMap { UUID(uuidString: $0) })
                    Task { @MainActor [weak self] in
                        guard let self else {
                            continuation.resume(returning: [])
                            return
                        }
                        let results = await self.verifiedSearchResults(
                            conversations: conversations,
                            query: query,
                            metadataSearchTextById: metadataSearchTextById,
                            metadataOnlyConversationIds: metadataOnlyConversationIds,
                            spotlightIds: ids
                        )
                        continuation.resume(returning: results)
                    }
                }

                searchQuery.start()
            }
        #endif
    }

    private func verifiedSearchResults(
        conversations: [Conversation],
        query: String,
        metadataSearchTextById: [UUID: String],
        metadataOnlyConversationIds: Set<UUID>,
        spotlightIds: Set<UUID>
    ) async -> [Conversation] {
        var results: [Conversation] = []
        results.reserveCapacity(conversations.count)

        for conversation in conversations {
            if Self.conversationMatchesCurrentSearchText(
                conversation,
                query: query,
                metadataSearchTextById: metadataSearchTextById
            ) {
                results.append(conversation)
                continue
            }

            guard spotlightIds.contains(conversation.id) else { continue }
            let isMetadataOnly = metadataOnlyConversationIds.contains(conversation.id)
                || conversation.metadataPreview != nil
            guard isMetadataOnly else {
                results.append(conversation)
                continue
            }

            guard let loadedConversation = await ensureConversationLoaded(conversation.id),
                  Self.conversationMatchesCurrentSearchText(
                      loadedConversation,
                      query: query,
                      metadataSearchTextById: [:]
                  )
            else {
                continue
            }
            results.append(loadedConversation)
        }

        return results
    }

    func searchConversations(query: String) -> [Conversation] {
        guard !query.isEmpty else { return conversations }

        return conversations.filter { conversation in
            Self.conversationMatchesCurrentSearchText(
                conversation,
                query: query,
                metadataSearchTextById: metadataSearchTextById
            )
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
