import Foundation

extension ConversationManager {
    private struct MetadataLoadSnapshot {
        let persistenceSequenceAtLoadStart: UInt64
        let persistingAtLoadStart: Set<UUID>
        let reconciliationVersionAtLoadStart: UInt64
        let deletingAtLoadStart: Set<UUID>
    }

    func loadConversations(
        allowingActiveClearGeneration allowedClearGeneration: UInt64? = nil,
        preservingUnsavedChanges: Bool = false
    ) async {
        let spotlightIndexWasCleared = await completePendingPrivacyCleanupIfNeeded()
        cancelAllFullConversationLoads()
        cancelSearchIndexWarmup()
        #if !os(watchOS)
            invalidateSpotlightIndexing()
        #endif
        conversationLoadGeneration &+= 1
        let loadGeneration = conversationLoadGeneration
        func loadIsCurrent() -> Bool {
            loadGeneration == conversationLoadGeneration
                && (clearConversationsTask == nil
                    || allowedClearGeneration == clearConversationsGeneration)
        }
        let persistenceSequenceAtLoadStart = nextPersistenceSequence
        let persistenceStateAtLoadStart = persistenceCoordinator.reconciliationState()
        guard loadIsCurrent() else {
            return
        }
        let snapshot = MetadataLoadSnapshot(
            persistenceSequenceAtLoadStart: persistenceSequenceAtLoadStart,
            persistingAtLoadStart: persistenceStateAtLoadStart.dirtyIds
                .union(persistenceTasksById.keys),
            reconciliationVersionAtLoadStart: nextReconciliationMutationVersion,
            deletingAtLoadStart: persistenceStateAtLoadStart.deletingIds
                .union(managerDeletionTasks.keys)
        )

        isConversationStateAuthoritative = false
        if !usesMetadataLoading {
            await consumeCoordinatorLoad(persistenceCoordinator.load())
            return
        }

        do {
            let metadataFromDisk = try await conversationMetadataLoader()
            guard loadIsCurrent() else {
                return
            }
            applyLoadedMetadata(
                metadataFromDisk,
                snapshot: snapshot,
                preservingUnsavedChanges: preservingUnsavedChanges,
                spotlightIndexWasCleared: spotlightIndexWasCleared
            )
        } catch {
            guard loadIsCurrent() else { return }
            handleMetadataLoadFailure(
                error,
                preservingUnsavedChanges: preservingUnsavedChanges
            )
        }
    }

    private func applyLoadedMetadata(
        _ metadataFromDisk: [ConversationMetadata],
        snapshot: MetadataLoadSnapshot,
        preservingUnsavedChanges: Bool,
        spotlightIndexWasCleared: Bool
    ) {
        let usableModels = AIService.shared.usableModels
        let availableModelSet = Set(usableModels)
        let selectedModel = AIService.shared.selectedModel
        let defaultModel = availableModelSet.contains(selectedModel)
            ? selectedModel
            : usableModels.first ?? selectedModel

        let persistenceState = persistenceCoordinator.reconciliationState()
        cancelAllFullConversationLoads()
        let dirtyIds = persistenceState.dirtyIds.union(persistenceTasksById.keys)
        let persistedDuringLoadIds = Set(persistenceSequenceById.compactMap { id, sequence in
            sequence > snapshot.persistenceSequenceAtLoadStart ? id : nil
        })
        let protectedPersistenceIds = dirtyIds
            .union(snapshot.persistingAtLoadStart)
            .union(persistedDuringLoadIds)
            .union(preservingUnsavedChanges ? unsavedStoredConversationIds(in: metadataFromDisk) : [])
        let deletingIds = persistenceState.deletingIds
            .union(managerDeletionTasks.keys)
            .union(snapshot.deletingAtLoadStart)
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
            let latestDeletionVersion = latestManagerDeletionVersionById[metadata.id] ?? 0
            let latestRecreationVersion = latestManagerRecreationVersionById[metadata.id] ?? 0
            let recreationBecameCurrentAfterLoad = latestRecreationVersion > snapshot.reconciliationVersionAtLoadStart
                && latestRecreationVersion > latestDeletionVersion
            let authorizedRecreationIsPending = latestRecreationVersion > latestDeletionVersion
                && protectedPersistenceIds.contains(metadata.id)
            if recreationBecameCurrentAfterLoad || authorizedRecreationIsPending,
               let memoryConversation = memoryById[metadata.id]
            {
                metadataIds.insert(metadata.id)
                reconciled.append(memoryConversation)
                if isMetadataBackedSnapshot(memoryConversation) {
                    nextMetadataOnlyIds.insert(metadata.id)
                }
                continue
            }

            let deletionBecameCurrentAfterLoad = latestDeletionVersion > snapshot.reconciliationVersionAtLoadStart
                && latestDeletionVersion > latestRecreationVersion
            guard !deletingIds.contains(metadata.id),
                  !deletionBecameCurrentAfterLoad
            else {
                continue
            }
            metadataIds.insert(metadata.id)

            if protectedPersistenceIds.contains(metadata.id),
               let memoryConversation = memoryById[metadata.id]
            {
                reconciled.append(memoryConversation)
                if isMetadataBackedSnapshot(memoryConversation) {
                    nextMetadataOnlyIds.insert(metadata.id)
                }
                continue
            }

            var placeholder = placeholderConversation(from: metadata)
            _ = repairUnavailableModels(
                in: &placeholder,
                availableModels: availableModelSet,
                defaultModel: defaultModel
            )
            reconciled.append(placeholder)
            nextMetadataOnlyIds.insert(metadata.id)
        }

        let recreatedAfterLoadIds = Set(latestManagerRecreationVersionById.compactMap { id, version in
            let deletionVersion = latestManagerDeletionVersionById[id] ?? 0
            return version > snapshot.reconciliationVersionAtLoadStart && version > deletionVersion ? id : nil
        })
        for protectedId in protectedPersistenceIds.union(recreatedAfterLoadIds) {
            if !metadataIds.contains(protectedId), let memoryConversation = memoryById[protectedId] {
                reconciled.append(memoryConversation)
                if isMetadataBackedSnapshot(memoryConversation) {
                    nextMetadataOnlyIds.insert(protectedId)
                }
            }
        }

        reconciled.sort { $0.updatedAt > $1.updatedAt }
        finalizeLoadedMetadata(
            reconciled: reconciled,
            nextMetadataOnlyIds: nextMetadataOnlyIds,
            metadataFromDisk: metadataFromDisk,
            spotlightIndexWasCleared: spotlightIndexWasCleared
        )
    }

    private func finalizeLoadedMetadata(
        reconciled: [Conversation],
        nextMetadataOnlyIds: Set<UUID>,
        metadataFromDisk: [ConversationMetadata],
        spotlightIndexWasCleared: Bool
    ) {
        let searchIndexWarmupIds = Set(
            reconciled.lazy
                .filter { nextMetadataOnlyIds.contains($0.id) }
                .prefix(Self.searchIndexWarmupLimit)
                .map(\.id)
        )

        conversations = reconciled
        metadataOnlyConversationIds = nextMetadataOnlyIds
        rebuildDurableDiskBaseline(from: metadataFromDisk, keeping: reconciled)
        metadataSearchTextById = metadataFromDisk.reduce(into: [:]) { searchTextById, metadata in
            guard nextMetadataOnlyIds.contains(metadata.id) else { return }
            searchTextById[metadata.id] = metadata.searchableText
        }
        metadataAttachmentPathsById = metadataFromDisk.reduce(into: [:]) { pathsById, metadata in
            guard let paths = metadata.attachmentPaths, !paths.isEmpty else { return }
            pathsById[metadata.id] = paths
        }

        if let selectedId = selectedConversationId,
           selectedId != Self.newConversationId,
           !conversations.contains(where: { $0.id == selectedId })
        {
            selectedConversationId = nil
        } else if let selectedId = selectedConversationId {
            scheduleFullConversationLoadIfNeeded(selectedId)
        }

        rebuildIndexCache()

        isLoaded = true
        isConversationStateAuthoritative = true
        loadRetryTask?.cancel()
        loadRetryTask = nil
        loadRetryAttempt = 0
        if searchIndexWarmupEnabled {
            scheduleSearchIndexWarmup(for: searchIndexWarmupIds)
        }

        logManager(
            "✅ Loaded \(conversations.count) conversation metadata records",
            level: .info,
            metadata: ["count": "\(conversations.count)"]
        )

        #if !os(watchOS)
            indexAllConversations(includingMetadataOnly: spotlightIndexWasCleared)
        #endif
    }

    private func handleMetadataLoadFailure(
        _ error: Error,
        preservingUnsavedChanges: Bool
    ) {
        isConversationStateAuthoritative = false
        if let encryptedStoreError = error as? EncryptedStoreError {
            if encryptedStoreError.clearNeedsRecovery {
                persistenceErrorMessage = "Conversation storage needs recovery. Restart Ayna before making more changes."
            } else if encryptedStoreError.clearWasCommitted {
                persistenceErrorMessage = "Encrypted conversation backup cleanup is incomplete. Restart Ayna to retry secure cleanup."
            }
        }
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
        scheduleLoadRetry(preservingUnsavedChanges: preservingUnsavedChanges)
    }

    private func consumeCoordinatorLoad(
        _ receipt: PersistenceReceipt<ConversationLoadResult>
    ) async {
        switch await receipt.value {
        case let .loaded(loaded):
            loadRetryTask?.cancel()
            loadRetryTask = nil
            loadRetryAttempt = 0
            applyCoordinatorLoad(loaded)
            isLoaded = true
            isConversationStateAuthoritative = true
        case let .failed(error):
            isLoaded = true
            isConversationStateAuthoritative = false
            logManager(
                "❌ Failed to load conversations",
                level: .error,
                metadata: ["error": error]
            )
            scheduleLoadRetry()
        case .superseded:
            isLoaded = true
            isConversationStateAuthoritative = false
            scheduleLoadRetry()
        }
    }

    private func applyCoordinatorLoad(_ loaded: [Conversation]) {
        var repaired = loaded
        let usableModels = AIService.shared.usableModels
        let availableModelSet = Set(usableModels)
        let selectedModel = AIService.shared.selectedModel
        let defaultModel = availableModelSet.contains(selectedModel)
            ? selectedModel
            : usableModels.first ?? selectedModel
        var repairedIds: [UUID] = []

        for index in repaired.indices {
            guard repairUnavailableModels(
                in: &repaired[index],
                availableModels: availableModelSet,
                defaultModel: defaultModel
            ) else { continue }
            repairedIds.append(repaired[index].id)
        }
        repaired.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        cancelAllFullConversationLoads()
        cancelSearchIndexWarmup()
        conversations = repaired
        metadataOnlyConversationIds.removeAll()
        metadataSearchTextById.removeAll()
        if let selectedId = selectedConversationId,
           !conversations.contains(where: { $0.id == selectedId })
        {
            selectedConversationId = nil
        }
        rebuildIndexCache()

        for id in repairedIds {
            guard let conversation = conversation(byId: id) else { continue }
            persistenceCoordinator.apply(conversation, mode: .immediate)
        }

        logManager(
            "✅ Loaded \(conversations.count) conversations",
            level: .info,
            metadata: ["count": "\(conversations.count)"]
        )
        #if !os(watchOS)
            indexAllConversations(includingMetadataOnly: false)
        #endif
    }

    private func scheduleLoadRetry(preservingUnsavedChanges: Bool = false) {
        guard !isConversationStateAuthoritative, loadRetryTask == nil else { return }
        let scale = 1 << min(loadRetryAttempt, 5)
        let delay = loadRetryBaseDelay * scale
        loadRetryAttempt += 1
        loadRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.loadRetryTask = nil
            await self.loadConversations(preservingUnsavedChanges: preservingUnsavedChanges)
        }
    }

    private func repairUnavailableModels(
        in conversation: inout Conversation,
        availableModels: Set<String>,
        defaultModel: String
    ) -> Bool {
        var didRepair = false

        if !availableModels.contains(conversation.model) {
            conversation.model = defaultModel
            didRepair = true
        }

        let supportedActiveModels = conversation.activeModels.filter {
            availableModels.contains($0)
        }
        if supportedActiveModels != conversation.activeModels {
            conversation.activeModels = supportedActiveModels
            didRepair = true
        }
        if conversation.multiModelEnabled, supportedActiveModels.count < 2 {
            conversation.multiModelEnabled = false
            didRepair = true
        }

        return didRepair
    }

    private func scheduleSearchIndexWarmup(for conversationIds: Set<UUID>) {
        cancelSearchIndexWarmup()

        guard let encryptedStore else { return }

        let version = searchIndexWarmupVersion
        let delay = searchIndexWarmupDelay
        searchIndexWarmupTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                try await encryptedStore.warmConversationSearchIndex(candidateIds: conversationIds)
            } catch is CancellationError {
            } catch {
                self?.logManager(
                    "Conversation search-index warmup failed",
                    level: .error,
                    metadata: ["error": error.localizedDescription]
                )
            }

            self?.finishSearchIndexWarmup(version: version)
        }
    }

    func cancelSearchIndexWarmup() {
        searchIndexWarmupVersion &+= 1
        searchIndexWarmupTask?.cancel()
        searchIndexWarmupTask = nil
    }

    private func finishSearchIndexWarmup(version: UInt64) {
        guard searchIndexWarmupVersion == version else { return }
        searchIndexWarmupTask = nil
    }

    private func rebuildDurableDiskBaseline(
        from metadataFromDisk: [ConversationMetadata],
        keeping reconciled: [Conversation]
    ) {
        let previousBaseline = durableDiskBaseline
        durableDiskBaseline = metadataFromDisk.reduce(into: [:]) { baseline, metadata in
            if let previous = previousBaseline[metadata.id], !previous.isMetadataOnly,
               previous.conversation.updatedAt >= metadata.updatedAt
            {
                baseline[metadata.id] = previous
            } else {
                baseline[metadata.id] = (placeholderConversation(from: metadata), true)
            }
        }
        for conversation in reconciled where durableDiskBaseline[conversation.id] == nil {
            durableDiskBaseline[conversation.id] = previousBaseline[conversation.id]
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

    func conversationPreparedForPersistence(
        _ proposedConversation: Conversation,
        isMetadataBackedSnapshot: Bool,
        persistenceSequence: UInt64
    ) async -> Conversation? {
        guard !Task.isCancelled,
              persistenceSequenceById[proposedConversation.id] == persistenceSequence
        else {
            return nil
        }
        guard isMetadataBackedSnapshot else {
            return proposedConversation
        }

        do {
            guard let loadedConversation = try await conversationLoader(proposedConversation.id) else {
                logManager(
                    "⚠️ Skipping save for metadata-only conversation missing full store record",
                    level: .error,
                    metadata: ["id": proposedConversation.id.uuidString]
                )
                return nil
            }
            guard !Task.isCancelled,
                  persistenceSequenceById[proposedConversation.id] == persistenceSequence
            else {
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
                guard proposedConversation.updatedAt > latestConversation.updatedAt else {
                    return latestConversation
                }
                return mergeMetadataBackedChanges(
                    from: proposedConversation,
                    into: latestConversation
                )
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
        } catch is CancellationError {
            return nil
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

    func scheduleFullConversationLoadIfNeeded(_ conversationId: UUID) {
        guard metadataOnlyConversationIds.contains(conversationId),
              fullConversationLoadTasks[conversationId] == nil
        else {
            return
        }

        _ = startFullConversationLoad(conversationId)
    }

    func cancelFullConversationLoad(_ conversationId: UUID) {
        fullConversationLoadTaskVersions.removeValue(forKey: conversationId)
        fullConversationLoadTasks.removeValue(forKey: conversationId)?.cancel()
    }

    func cancelAllFullConversationLoads() {
        for task in fullConversationLoadTasks.values {
            task.cancel()
        }
        fullConversationLoadTasks.removeAll()
        fullConversationLoadTaskVersions.removeAll()
    }

    private func startFullConversationLoad(_ conversationId: UUID) -> Task<Conversation?, Never> {
        nextFullConversationLoadTaskVersion &+= 1
        let version = nextFullConversationLoadTaskVersion
        let task = Task<Conversation?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadFullConversation(conversationId, version: version)
        }
        fullConversationLoadTasks[conversationId] = task
        fullConversationLoadTaskVersions[conversationId] = version
        return task
    }

    func isMetadataOnlyConversation(_ conversationId: UUID) -> Bool {
        metadataOnlyConversationIds.contains(conversationId)
    }

    func recentConversationsWithHistory(limit: Int) async -> [Conversation] {
        _ = await loadingTask?.value
        let recentIds = conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(\.id)
        var result: [Conversation] = []
        for id in recentIds {
            if let conversation = await ensureConversationLoaded(id), !conversation.messages.isEmpty {
                result.append(conversation)
            }
        }
        return result
    }

    @discardableResult
    func ensureConversationLoaded(_ conversationId: UUID) async -> Conversation? {
        if let existingTask = fullConversationLoadTasks[conversationId] {
            return await existingTask.value
        }

        guard metadataOnlyConversationIds.contains(conversationId) else {
            return conversationSnapshot(byId: conversationId)
        }

        return await startFullConversationLoad(conversationId).value
    }

    func loadFullHistoryBeforeEdit(_ conversationId: UUID) async -> Bool {
        guard metadataOnlyConversationIds.contains(conversationId) else { return true }
        _ = await ensureConversationLoaded(conversationId)
        return conversationSnapshot(byId: conversationId) != nil
            && !metadataOnlyConversationIds.contains(conversationId)
    }

    private func loadFullConversation(
        _ conversationId: UUID,
        version: UInt64
    ) async -> Conversation? {
        defer {
            finishFullConversationLoad(conversationId, version: version)
        }

        guard metadataOnlyConversationIds.contains(conversationId) else {
            return conversationSnapshot(byId: conversationId)
        }

        do {
            guard var loadedConversation = try await conversationLoader(conversationId) else {
                return nil
            }
            if !Task.isCancelled, durableDiskBaseline[conversationId] != nil {
                durableDiskBaseline[conversationId] = (loadedConversation, false)
            }
            guard !Task.isCancelled,
                  metadataOnlyConversationIds.contains(conversationId),
                  conversationSnapshot(byId: conversationId) != nil
            else {
                return conversationSnapshot(byId: conversationId)
            }

            let usableModels = AIService.shared.usableModels
            let availableModelSet = Set(usableModels)
            let selectedModel = AIService.shared.selectedModel
            let defaultModel = availableModelSet.contains(selectedModel)
                ? selectedModel
                : usableModels.first ?? selectedModel
            let storageConversationWasRepaired = repairUnavailableModels(
                in: &loadedConversation,
                availableModels: availableModelSet,
                defaultModel: defaultModel
            )

            let dirtyIds = persistenceCoordinator.pendingConversationIds()
            guard !dirtyIds.contains(conversationId) else {
                return conversationSnapshot(byId: conversationId)
            }

            guard !Task.isCancelled,
                  metadataOnlyConversationIds.contains(conversationId),
                  let index = getConversationIndex(for: conversationId)
            else {
                return conversationSnapshot(byId: conversationId)
            }

            let currentConversation = conversations[index]
            var mergedConversation = mergeMetadataBackedChanges(
                from: currentConversation,
                into: loadedConversation
            )
            let mergedConversationWasRepaired = repairUnavailableModels(
                in: &mergedConversation,
                availableModels: availableModelSet,
                defaultModel: defaultModel
            )
            conversations[index] = mergedConversation
            metadataOnlyConversationIds.remove(conversationId)
            metadataSearchTextById.removeValue(forKey: conversationId)
            #if !os(watchOS)
                indexConversation(mergedConversation)
            #endif
            if storageConversationWasRepaired || mergedConversationWasRepaired,
               !persistenceCoordinator.pendingConversationIds().contains(mergedConversation.id),
               !suppressedPersistenceIds.contains(mergedConversation.id)
            {
                persistenceCoordinator.apply(mergedConversation, mode: .coalesced)
            }
            return conversationSnapshot(byId: conversationId)
        } catch is CancellationError {
            return nil
        } catch {
            logManager(
                "❌ Failed to lazy-load conversation",
                level: .error,
                metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
            )
            return nil
        }
    }

    private func finishFullConversationLoad(_ conversationId: UUID, version: UInt64) {
        guard fullConversationLoadTaskVersions[conversationId] == version else { return }
        fullConversationLoadTasks.removeValue(forKey: conversationId)
        fullConversationLoadTaskVersions.removeValue(forKey: conversationId)
    }

    func reloadConversations() async {
        logManager("🔄 Reloading conversations from storage", level: .info)
        loadRetryTask?.cancel()
        loadRetryTask = nil
        while let clearTask = clearConversationsTask {
            await clearTask.value
        }
        await loadConversations(preservingUnsavedChanges: true)
    }

    func isGenerating(_ conversationId: UUID) -> Bool {
        generatingConversationIds.contains(conversationId)
    }

    func setGenerating(_ isGenerating: Bool, for conversationId: UUID) {
        if isGenerating {
            generatingConversationIds.insert(conversationId)
        } else {
            generatingConversationIds.remove(conversationId)
        }
    }

    private func unsavedStoredConversationIds(in metadataFromDisk: [ConversationMetadata]) -> Set<UUID> {
        let storedIds = Set(metadataFromDisk.map(\.id))
        return Set(conversations.lazy.filter { conversation in
            guard storedIds.contains(conversation.id) else { return false }
            if self.generatingConversationIds.contains(conversation.id) { return true }
            return !self.metadataOnlyConversationIds.contains(conversation.id)
                && self.durableDiskBaseline[conversation.id]?.conversation != conversation
        }.map(\.id))
    }
}
