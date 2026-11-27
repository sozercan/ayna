import Foundation
#if !os(watchOS)
    import CoreSpotlight
    import UniformTypeIdentifiers
#endif

extension ConversationManager {
    #if !os(watchOS)
        nonisolated static func createSearchableItem(for conversation: Conversation)
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

            let allContent = conversation.messages.map(\.content).joined(separator: "\n")
            attributeSet.textContent = allContent
            attributeSet.contentModificationDate = conversation.updatedAt

            return CSSearchableItem(
                uniqueIdentifier: conversation.id.uuidString,
                domainIdentifier: "com.sertacozercan.ayna.conversation",
                attributeSet: attributeSet
            )
        }

        func indexConversation(_ conversation: Conversation) {
            guard spotlightIndexingEnabled else { return }
            let conversationId = conversation.id
            let generation = spotlightIndexGeneration

            indexingDebounceTasks[conversationId]?.cancel()
            indexingDebounceTasks[conversationId] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: indexingDebounceDuration)
                } catch {
                    return
                }

                indexingDebounceTasks.removeValue(forKey: conversationId)
                guard spotlightIndexGeneration == generation,
                      let latestConversation = getConversationIndex(for: conversationId)
                          .map({ conversations[$0] })
                else {
                    return
                }

                enqueueSpotlightIndexing(latestConversation, generation: generation)
            }
        }

        private func enqueueSpotlightIndexing(
            _ conversation: Conversation,
            generation: UInt64
        ) {
            spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                guard let self,
                      await MainActor.run(body: { self.spotlightIndexGeneration == generation })
                else {
                    return
                }

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

        private func indexConversationImmediately(_ conversation: Conversation) {
            guard spotlightIndexingEnabled else { return }
            indexingDebounceTasks[conversation.id]?.cancel()
            indexingDebounceTasks.removeValue(forKey: conversation.id)
            enqueueSpotlightIndexing(conversation, generation: spotlightIndexGeneration)
        }

        func indexAllConversations(includingMetadataOnly: Bool = false) {
            guard spotlightIndexingEnabled else { return }
            let metadataOnlyIds = metadataOnlyConversationIds
            let conversationsToIndex = if includingMetadataOnly {
                conversations
            } else {
                conversations.filter { !metadataOnlyIds.contains($0.id) }
            }
            let shouldResetIndex = includingMetadataOnly || metadataOnlyIds.isEmpty
            let generation = spotlightIndexGeneration
            let indexOperation = spotlightBatchIndexOperation

            spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                guard let self,
                      await MainActor.run(body: { self.spotlightIndexGeneration == generation })
                else {
                    return
                }

                do {
                    try await indexOperation(conversationsToIndex, shouldResetIndex)

                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .info,
                        message: "✅ Spotlight batch indexing complete",
                        metadata: ["count": "\(conversationsToIndex.count)"]
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

        func deindexConversation(
            id: UUID,
            deletionReconciliationVersion: UInt64
        ) {
            guard spotlightIndexingEnabled else { return }
            let deleteOperation = spotlightDeleteOperation
            indexingDebounceTasks[id]?.cancel()
            indexingDebounceTasks.removeValue(forKey: id)

            spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                guard let self else { return }
                let deletionIsStillCurrent = await MainActor.run {
                    let latestDeletionVersion = self.latestManagerDeletionVersionById[id] ?? 0
                    let latestRecreationVersion = self.latestManagerRecreationVersionById[id] ?? 0
                    return latestDeletionVersion == deletionReconciliationVersion
                        && deletionReconciliationVersion > latestRecreationVersion
                }
                guard deletionIsStillCurrent else {
                    return
                }

                do {
                    try await deleteOperation(id)
                } catch {
                    DiagnosticsLogger.log(
                        .conversationManager,
                        level: .error,
                        message: "❌ Spotlight deletion error",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }

        func invalidateSpotlightIndexing() {
            spotlightIndexGeneration &+= 1
            for task in indexingDebounceTasks.values {
                task.cancel()
            }
            indexingDebounceTasks.removeAll()
        }

        func scheduleSpotlightIndexCleanupAfterCommittedClear()
            -> (task: Task<Void, Never>, result: CleanupResultBox)
        {
            invalidateSpotlightIndexing()
            let generation = spotlightIndexGeneration
            let cleanupOperation = spotlightCleanupOperation
            let result = CleanupResultBox()

            let task = spotlightOperationQueue.enqueue(priority: .utility) { [weak self] in
                do {
                    try await cleanupOperation()
                } catch {
                    result.markFailed()
                    await MainActor.run { [weak self] in
                        guard let self, spotlightIndexGeneration == generation else { return }
                        recordPersistenceError(
                            "Conversations were cleared, but Spotlight cleanup failed. \(error.localizedDescription)"
                        )
                        logManager(
                            "Failed to clear Spotlight conversation index",
                            level: .error,
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }
            return (task, result)
        }
    #endif

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

    func searchConversationsAsync(query: String, conversations: [Conversation]) async
        -> [Conversation]
    {
        guard !query.isEmpty else { return conversations }
        let metadataSearchTextById = metadataSearchTextById
        let metadataOnlyConversationIds = metadataOnlyConversationIds

        return await verifiedSearchResults(
            conversations: conversations,
            query: query,
            metadataSearchTextById: metadataSearchTextById,
            metadataOnlyConversationIds: metadataOnlyConversationIds
        )
    }

    func verifiedSearchResults(
        conversations: [Conversation],
        query: String,
        metadataSearchTextById: [UUID: String],
        metadataOnlyConversationIds: Set<UUID>
    ) async -> [Conversation] {
        var matchingIds: Set<UUID> = []
        var fullTextCandidateIds: Set<UUID> = []

        for conversation in conversations {
            if Self.conversationMatchesCurrentSearchText(
                conversation,
                query: query,
                metadataSearchTextById: metadataSearchTextById
            ) {
                matchingIds.insert(conversation.id)
                continue
            }

            let isMetadataOnly = metadataOnlyConversationIds.contains(conversation.id)
                || conversation.metadataPreview != nil
            if isMetadataOnly {
                fullTextCandidateIds.insert(conversation.id)
            }
        }

        guard let encryptedStore else {
            return conversations.filter { matchingIds.contains($0.id) }
        }

        do {
            let fullTextMatches = try await encryptedStore.conversationIdsMatchingSearch(
                query: query,
                candidateIds: fullTextCandidateIds
            )
            matchingIds.formUnion(fullTextMatches)
        } catch is CancellationError {
            return []
        } catch {
            logManager(
                "Full-text conversation search failed",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
        }

        return conversations.filter { matchingIds.contains($0.id) }
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
