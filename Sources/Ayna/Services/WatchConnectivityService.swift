// swiftlint:disable file_length
#if os(iOS) || os(watchOS)
    import Combine
    import Foundation
    import os
    import WatchConnectivity

    #if os(iOS)
        @MainActor
        // swiftlint:disable:next type_body_length
        final class WatchConnectivityService: NSObject, ObservableObject {
            static let shared = WatchConnectivityService()
            @Published private(set) var isWatchAppInstalled = false
            @Published private(set) var isReachable = false
            @Published private(set) var lastSyncDate: Date?

            private nonisolated let activationFence = WatchSessionActivationFence()
            private nonisolated let callbackIdentityFence = WatchSessionCallbackIdentityFence()
            private let mutationProcessingQueue = WatchMutationProcessingQueue()
            private let recentAcknowledgements = WatchRecentAcknowledgementTracker()
            private nonisolated let sessionEventQueue = WatchSessionEventQueue()
            private let legacyIngressDeferralQueue = WatchLegacyIngressDeferralQueue()
            private var session: WCSession?
            private var sessionDelegate: WatchSessionDelegateProxy?
            private var conversationManager: ConversationManager?
            private var cancellables = Set<AnyCancellable>()
            private var snapshotRevision: WatchSyncRevision = 0
            private var sourceID = UUID()
            private var activeWatchPeerID: UUID?
            private var activeWatchCapability = WatchPeerCapabilityState()
            private var acknowledgedWatchRevisions: [UUID: WatchSyncRevision] = [:]
            private var acknowledgedWatchRevisionsByPeer: [UUID: [UUID: WatchSyncRevision]] = [:]
            private var tombstoneRevisions: [UUID: WatchSyncRevision] = [:]
            private var modelRemovalTracker = WatchModelRemovalTracker()
            private struct PublishedApplicationContext {
                let values: [String: Any]
                let pageCycleMetadata: WatchSyncPageCycleMetadata?
                let modelMetadataPageIsLossless: Bool
                let modelRemovalTracker: WatchModelRemovalTracker
            }

            private struct ApplicationContextOptions {
                let modelLimit: Int?
                let modelMetadataCycleIsAuthoritative: Bool?
                let maximumDefaultSystemPromptCharacters: Int
                let modelRemovalPublication: WatchModelRemovalPublication
                let modelMetadataEpoch: UUID
            }

            private var knownConversationIDs: Set<UUID> = []
            private var legacyPlaceholderConversationIDs: Set<UUID> = []
            private var hasPersistedManifest = false
            private var pageCycleCoordinator = WatchPhonePageCycleCoordinator()

            override private init() {
                super.init()
                loadSyncMetadata()
                setupSession()
            }

            private func setupSession() {
                guard WCSession.isSupported() else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "WatchConnectivity not supported on this device"
                    )
                    return
                }

                activateSession(WCSession.default)

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 iOS WatchConnectivity session activating"
                )
            }

            private func activateSession(_ targetSession: WCSession) {
                let activation = activationFence.beginActivation()
                callbackIdentityFence.activate(
                    sessionID: ObjectIdentifier(targetSession),
                    activation: activation
                )
                let delegate = WatchSessionDelegateProxy(
                    owner: self,
                    activation: activation
                )
                session = targetSession
                sessionDelegate = delegate
                targetSession.delegate = delegate
                targetSession.activate()
            }

            func configure(with conversationManager: ConversationManager) {
                self.conversationManager = conversationManager
                cancellables = WatchConversationSyncObserver.observe(
                    conversationManager: conversationManager
                ) { [weak self] conversations in
                    self?.syncConversationsToWatch(conversations)
                }
            }

            func syncConversationsToWatch(_ conversations: [Conversation]) {
                let pageCycle: WatchSyncPageCycleRequest?
                if activeWatchCapability.supportsCurrentSchema {
                    let cycleID = UUID()
                    let cursor = pageCycleCoordinator.beginCycle(id: cycleID)
                    pageCycle = WatchSyncPageCycleRequest(cycleID: cycleID, cursor: cursor)
                } else {
                    pageCycleCoordinator.reset()
                    pageCycle = nil
                }
                publishConversationsToWatch(conversations, pageCycle: pageCycle)
            }

            private func publishConversationsToWatch(
                _ conversations: [Conversation],
                pageCycle: WatchSyncPageCycleRequest?
            ) {
                guard conversationManager?.isConversationStateAuthoritative == true else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .debug,
                        message: "Deferring Watch snapshot until phone conversation load succeeds"
                    )
                    return
                }
                let durableConversations = conversationManager?.durableConversationsForSync() ?? conversations
                guard WatchPhonePublicationBarrier.prepare(
                    pendingOperationCount: {
                        self.conversationManager?.pendingDestructivePersistenceOperations ?? 0
                    },
                    reconcile: { [weak self] in
                        self?.reconcilePhoneManifest(durableConversations)
                    }
                ) else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .debug,
                        message: "Deferring Watch snapshot until destructive persistence settles"
                    )
                    return
                }

                guard let session, session.isPaired, session.isWatchAppInstalled else {
                    return
                }

                do {
                    let nextRevision = incrementSnapshotRevision()
                    let state = PhoneWatchSyncState(
                        peerID: activeWatchPeerID,
                        conversations: durableConversations,
                        acknowledgedWatchRevisions: acknowledgedWatchRevisions,
                        tombstoneRevisions: tombstoneRevisions
                    )
                    let memoryFacts = try memoryFactsPayloadForSync()
                    guard let publication = try boundedApplicationContext(
                        state: state,
                        snapshotRevision: nextRevision,
                        memoryFacts: memoryFacts,
                        pageCycle: pageCycle
                    ) else {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Watch application context exceeds the safe byte budget"
                        )
                        return
                    }
                    let syncDate = Date()
                    var contextWithDate = publication.values
                    contextWithDate[WatchContextKeys.lastSyncDate] = syncDate.timeIntervalSince1970
                    try session.updateApplicationContext(contextWithDate)
                    modelRemovalTracker = publication.modelRemovalTracker
                    persistSyncMetadata()
                    if let metadata = publication.pageCycleMetadata {
                        pageCycleCoordinator.recordPublished(
                            metadata,
                            modelMetadataPageIsLossless: publication.modelMetadataPageIsLossless
                        )
                    }
                    lastSyncDate = syncDate
                    let snapshotData = publication.values[WatchContextKeys.syncSnapshot] as? Data ?? Data()
                    let publishedSnapshot = try? JSONDecoder().decode(WatchSyncSnapshot.self, from: snapshotData)

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱→⌚ Published revisioned Watch snapshot",
                        metadata: [
                            "revision": "\(nextRevision)",
                            "pageCycle": publication.pageCycleMetadata?.cycleID.uuidString ?? "none",
                            "pageIndex": "\(publication.pageCycleMetadata?.cursor.pageIndex ?? -1)",
                            "manifestCount": "\(publishedSnapshot?.authoritativeConversationIDs.count ?? 0)",
                            "bodyCount": "\(publishedSnapshot?.conversations.count ?? 0)",
                            "snapshotBytes": "\(snapshotData.count)",
                            "contextBytes": "\(WatchApplicationContextSizer.size(contextWithDate))"
                        ]
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to sync to Watch",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            private func memoryFactsPayloadForSync() throws -> WatchMemoryFactsPayload {
                let encoder = JSONEncoder()
                let emptyFacts = try encoder.encode([UserMemoryFact]())
                guard MemoryContextProvider.shared.isMemoryEnabled else {
                    return WatchMemoryFactsPayload(
                        data: emptyFacts,
                        preservesAcrossFallbacks: true
                    )
                }

                guard UserMemoryService.shared.hasAuthoritativeFacts else {
                    return WatchMemoryFactsPayload(
                        data: nil,
                        preservesAcrossFallbacks: false
                    )
                }

                let facts = UserMemoryService.shared.activeFacts()
                let encoded = try encoder.encode(facts)
                guard encoded.count < 15000 else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .default,
                        message: "⚠️ Memory facts exceed Watch sync headroom; omitting non-authoritative facts",
                        metadata: ["bytes": "\(encoded.count)", "factCount": "\(facts.count)"]
                    )
                    return WatchMemoryFactsPayload(
                        data: nil,
                        preservesAcrossFallbacks: false
                    )
                }
                return WatchMemoryFactsPayload(
                    data: encoded,
                    preservesAcrossFallbacks: facts.isEmpty
                )
            }

            private func boundedApplicationContext(
                state: PhoneWatchSyncState,
                snapshotRevision: WatchSyncRevision,
                memoryFacts: WatchMemoryFactsPayload,
                pageCycle: WatchSyncPageCycleRequest?
            ) throws -> PublishedApplicationContext? {
                let encoder = JSONEncoder()
                let attempts = WatchApplicationContextAttempt.fallbacks(memoryFacts: memoryFacts)
                var candidateRemovalTracker = modelRemovalTracker
                let modelRemovalPublication = candidateRemovalTracker.publication(
                    inventory: currentModelMetadataInventory()
                )

                for attempt in attempts {
                    var configuration = WatchSyncPayloadConfiguration.default
                    configuration.byteBudget = attempt.snapshotBytes
                    if let modelLimit = attempt.modelLimit {
                        configuration.maximumConversations = min(
                            configuration.maximumConversations,
                            modelLimit
                        )
                    }

                    let snapshotData: Data
                    let pageCycleMetadata: WatchSyncPageCycleMetadata?
                    if let pageCycle {
                        guard let payload = try? WatchSyncPayloadBuilder.buildPageCycle(
                            state: state,
                            sourceID: sourceID,
                            snapshotRevision: snapshotRevision,
                            cycleID: pageCycle.cycleID,
                            cursor: pageCycle.cursor,
                            prioritizedAcknowledgementIDs: recentAcknowledgements.ids,
                            configuration: configuration,
                            resolvedSystemPrompt: { [weak conversationManager] conversation in
                                conversationManager?.effectiveSystemPrompt(for: conversation)
                            }
                        ) else {
                            continue
                        }
                        snapshotData = payload.data
                        pageCycleMetadata = pageCycleCoordinator.metadataForPublication(
                            payload.metadata,
                            modelMetadataPageIsLossless: attempt.modelLimit == nil
                        )
                    } else {
                        guard let payload = try? WatchSyncPayloadBuilder.build(
                            state: state,
                            sourceID: sourceID,
                            snapshotRevision: snapshotRevision,
                            prioritizedAcknowledgementIDs: recentAcknowledgements.ids,
                            configuration: configuration,
                            resolvedSystemPrompt: { [weak conversationManager] conversation in
                                conversationManager?.effectiveSystemPrompt(for: conversation)
                            }
                        ) else {
                            continue
                        }
                        snapshotData = payload.data
                        pageCycleMetadata = nil
                    }

                    let pageCycleData = try pageCycleMetadata.map { try encoder.encode($0) }
                    let context = applicationContext(
                        snapshotData: snapshotData,
                        pageCycleData: pageCycleData,
                        factsData: attempt.facts,
                        authoritativeState: state,
                        options: ApplicationContextOptions(
                            modelLimit: attempt.modelLimit,
                            modelMetadataCycleIsAuthoritative: pageCycleMetadata?
                                .modelMetadataCycleIsAuthoritative,
                            maximumDefaultSystemPromptCharacters: attempt.maximumDefaultSystemPromptCharacters,
                            modelRemovalPublication: modelRemovalPublication,
                            modelMetadataEpoch: candidateRemovalTracker.epoch
                        )
                    )
                    if WatchApplicationContextSizer.isWithinSafeLimit(context) {
                        return PublishedApplicationContext(
                            values: context,
                            pageCycleMetadata: pageCycleMetadata,
                            modelMetadataPageIsLossless: attempt.modelLimit == nil,
                            modelRemovalTracker: candidateRemovalTracker
                        )
                    }
                }
                return nil
            }

            private func currentModelMetadataInventory() -> WatchModelMetadataInventory {
                let modelIDs = WatchModelSyncSelection.models(
                    selectedModel: AIService.shared.selectedModel,
                    availableModels: AIService.shared.usableModels + AIService.shared.customModels,
                    referencedModels: [],
                    limit: nil
                )
                let configured = Set(modelIDs)
                let providers = AIService.shared.modelProviders
                    .filter { configured.contains($0.key) }
                    .mapValues(\.rawValue)
                let endpoints = AIService.shared.modelEndpoints.filter {
                    configured.contains($0.key) && !$0.value.isEmpty
                }
                let endpointTypes = AIService.shared.modelEndpointTypes
                    .filter { configured.contains($0.key) }
                    .mapValues(\.rawValue)
                let gitHubOAuth = AIService.shared.modelUsesGitHubOAuth.filter {
                    configured.contains($0.key)
                }
                let apiKeys = AIService.shared.modelAPIKeys.filter {
                    configured.contains($0.key) && !$0.value.isEmpty
                }
                return WatchModelMetadataInventory(
                    modelIDs: modelIDs,
                    providerModelIDs: providers.keys.sorted(),
                    endpointModelIDs: endpoints.keys.sorted(),
                    endpointTypeModelIDs: endpointTypes.keys.sorted(),
                    gitHubOAuthModelIDs: gitHubOAuth.keys.sorted(),
                    apiKeyModelIDs: apiKeys.keys.sorted(),
                    valueDigests: WatchModelMetadataValueDigests.hashing(
                        providers: providers,
                        endpoints: endpoints,
                        endpointTypes: endpointTypes,
                        gitHubOAuth: gitHubOAuth,
                        apiKeys: apiKeys
                    )
                )
            }

            private func applicationContext(
                snapshotData: Data,
                pageCycleData: Data?,
                factsData: Data?,
                authoritativeState: PhoneWatchSyncState,
                options: ApplicationContextOptions
            ) -> [String: Any] {
                let selectedModel = AIService.shared.selectedModel
                let snapshot = try? JSONDecoder().decode(WatchSyncSnapshot.self, from: snapshotData)
                let modelPublication = if let snapshot {
                    WatchModelSyncSelection.publication(
                        selectedModel: selectedModel,
                        availableModels: AIService.shared.usableModels,
                        authoritativeState: authoritativeState,
                        snapshot: snapshot,
                        limit: options.modelLimit
                    )
                } else {
                    WatchModelSyncSelection.publication(
                        selectedModel: selectedModel,
                        availableModels: AIService.shared.usableModels,
                        referencedModels: [],
                        limit: options.modelLimit
                    )
                }
                let metadataModelSet = modelPublication.metadataModelIDs
                let modelMetadataComplete = options.modelMetadataCycleIsAuthoritative ?? snapshot.map {
                    WatchModelMetadataCompleteness.isCompletePublication(
                        snapshot: $0,
                        modelLimit: options.modelLimit
                    )
                } ?? false

                var context: [String: Any] = [
                    WatchContextKeys.syncSnapshot: snapshotData,
                    WatchContextKeys.selectedModel: selectedModel,
                    WatchContextKeys.availableModels: modelPublication.availableModels,
                    WatchContextKeys.customModels: AIService.shared.customModels.filter { metadataModelSet.contains($0) },
                    WatchContextKeys.defaultProvider: AIService.shared.provider.rawValue,
                    WatchContextKeys.modelProviders: modelPublication.metadataValues(
                        from: AIService.shared.modelProviders
                    )
                    .mapValues(\.rawValue),
                    WatchContextKeys.modelEndpoints: modelPublication.metadataValues(
                        from: AIService.shared.modelEndpoints
                    ),
                    WatchContextKeys.modelEndpointTypes: modelPublication.metadataValues(
                        from: AIService.shared.modelEndpointTypes
                    )
                    .mapValues(\.rawValue),
                    WatchContextKeys.modelUsesGitHubOAuth: modelPublication.metadataValues(
                        from: AIService.shared.modelUsesGitHubOAuth
                    ),
                    WatchContextKeys.modelAPIKeys: modelPublication.metadataValues(
                        from: AIService.shared.modelAPIKeys
                    ),
                    WatchContextKeys.removedModelDigests: options.modelRemovalPublication.removedModelDigests,
                    WatchContextKeys.removedModelProviderDigests: options.modelRemovalPublication.removedProviderDigests,
                    WatchContextKeys.removedModelEndpointDigests: options.modelRemovalPublication.removedEndpointDigests,
                    WatchContextKeys.removedModelEndpointTypeDigests: options.modelRemovalPublication.removedEndpointTypeDigests,
                    WatchContextKeys.removedModelGitHubOAuthDigests: options.modelRemovalPublication.removedGitHubOAuthDigests,
                    WatchContextKeys.removedModelAPIKeyDigests: options.modelRemovalPublication.removedAPIKeyDigests,
                    WatchContextKeys.modelMetadataEpoch: options.modelMetadataEpoch.uuidString,
                    WatchContextKeys.modelMetadataComplete: modelMetadataComplete,
                    WatchContextKeys.githubAccessToken: GitHubOAuthService.shared.getAccessToken() ?? "",
                    WatchContextKeys.tavilyAPIKey: TavilyService.shared.apiKey,
                    WatchContextKeys.tavilyEnabled: TavilyService.shared.isEnabled,
                    WatchContextKeys.webFetchEnabled: WebFetchService.shared.isEnabled,
                    WatchContextKeys.memoryEnabled: MemoryContextProvider.shared.isMemoryEnabled
                ]
                if let defaultSystemPrompt = WatchPayloadStringLimiter.losslessRepresentation(
                    AppPreferences.globalSystemPrompt,
                    maximumCharacters: options.maximumDefaultSystemPromptCharacters
                ) {
                    context[WatchContextKeys.defaultSystemPrompt] = defaultSystemPrompt
                }
                if let factsData {
                    context[WatchContextKeys.memoryFacts] = factsData
                }
                if let pageCycleData {
                    context[WatchContextKeys.syncPageCycle] = pageCycleData
                }
                if !activeWatchCapability.supportsCurrentSchema,
                   let snapshot,
                   let legacyConversations = try? JSONEncoder().encode(snapshot.conversations)
                {
                    context[WatchContextKeys.conversations] = legacyConversations
                }
                return context
            }

            private func handleMutation(
                _ mutation: WatchConversationMutation,
                schemaVersion: Any?
            ) async -> [String: Any]? {
                switch WatchMutationIngressValidator.validate(
                    schemaVersion: schemaVersion,
                    fields: mutation.fields
                ) {
                case .accepted:
                    break
                case let .rejected(rejection):
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Rejecting unsupported Watch mutation ingress",
                        metadata: [
                            "operationId": mutation.operationID.uuidString,
                            "conversationId": mutation.conversationID.uuidString,
                            "reason": String(describing: rejection)
                        ]
                    )
                    return WatchMutationReply.unsupported(for: mutation).message
                }

                let reply: WatchMutationReply? = await mutationProcessingQueue.enqueue { [weak self] in
                    guard let self else { return nil }
                    return await self.applyMutation(mutation)
                }
                return reply?.message
            }

            private func applyMutation(_ mutation: WatchConversationMutation) async -> WatchMutationReply? {
                guard let conversationManager else { return nil }

                activateWatchPeer(mutation.peerID)
                activeWatchCapability.apply(.receivedMutation)
                guard conversationManager.isConversationStateAuthoritative else {
                    return .retry(for: mutation)
                }
                guard conversationManager.pendingDestructivePersistenceOperations == 0 else {
                    return .retry(for: mutation)
                }

                let state = PhoneWatchSyncState(
                    peerID: activeWatchPeerID,
                    conversations: conversationManager.conversations,
                    acknowledgedWatchRevisions: acknowledgedWatchRevisions,
                    tombstoneRevisions: tombstoneRevisions
                )
                let reduction = PhoneWatchMutationReducer.reduce(
                    state,
                    mutation: mutation,
                    tombstoneRevision: mutation.fields.contains(.delete) ? nextSnapshotRevision() : nil
                )

                let persisted: Bool
                switch reduction.disposition {
                case .applied:
                    guard let reduced = reduction.state.conversations.first(where: { $0.id == mutation.conversationID }) else {
                        return nil
                    }
                    switch await conversationManager.persistProposedConversation(reduced).value {
                    case .saved:
                        conversationManager.commitPersistedConversation(reduced)
                        persisted = true
                    case .failed, .superseded:
                        persisted = false
                    }

                case .deleted:
                    let deletion = if let existing = conversationManager.conversations.first(where: {
                        $0.id == mutation.conversationID
                    }) {
                        conversationManager.persistProposedDeletion(existing)
                    } else {
                        conversationManager.persistProposedDeletion(conversationID: mutation.conversationID)
                    }
                    switch await deletion.value {
                    case .deleted:
                        conversationManager.commitPersistedDeletion(mutation.conversationID)
                        persisted = true
                    case .failed, .superseded:
                        persisted = false
                    }

                case .rejectedStale, .rejectedDeletedTombstone, .rejectedMissingCreate:
                    persisted = true
                }

                guard persisted else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Watch mutation persistence failed; retaining durable Watch outbox entry",
                        metadata: [
                            "conversationId": mutation.conversationID.uuidString,
                            "operationId": mutation.operationID.uuidString,
                            "revision": "\(mutation.revision)"
                        ]
                    )
                    return .retry(for: mutation)
                }

                legacyPlaceholderConversationIDs.remove(mutation.conversationID)
                WatchMutationMetadataMerger.merge(
                    reduction: reduction,
                    conversationID: mutation.conversationID,
                    acknowledgements: &acknowledgedWatchRevisions,
                    tombstones: &tombstoneRevisions
                )
                recentAcknowledgements.record(mutation.conversationID)
                reconcilePhoneManifest(conversationManager.conversations)

                let acknowledgedRevision = acknowledgedWatchRevisions[mutation.conversationID] ?? mutation.revision
                syncConversationsToWatch(conversationManager.conversations)

                return .acknowledged(mutation, revision: acknowledgedRevision)
            }

            private func processLegacyPayload(
                _ apply: @escaping @MainActor @Sendable (ConversationManager) async -> Void
            ) async {
                guard let conversationManager else { return }
                guard !WatchLegacyIngressRouting.shouldDefer(
                    isAuthoritative: conversationManager.isConversationStateAuthoritative,
                    pendingDestructiveOperationCount: conversationManager.pendingDestructivePersistenceOperations
                ) else {
                    legacyIngressDeferralQueue.retain(
                        untilReady: { [weak self] in
                            guard let conversationManager = self?.conversationManager else { return false }
                            return await conversationManager.waitUntilConversationStateIsAuthoritative()
                        },
                        operation: { [weak self] in
                            guard let self, let conversationManager = self.conversationManager else { return }
                            await self.performLegacyPayload(apply, with: conversationManager)
                        }
                    )
                    return
                }
                await performLegacyPayload(apply, with: conversationManager)
            }

            private func performLegacyPayload(
                _ apply: @escaping @MainActor @Sendable (ConversationManager) async -> Void,
                with conversationManager: ConversationManager
            ) async {
                await WatchLegacyPersistenceBarrier.perform(
                    pendingOperationCount: {
                        conversationManager.pendingDestructivePersistenceOperations
                    },
                    changes: conversationManager.$pendingDestructivePersistenceOperations,
                    reconcile: { [weak self] in
                        self?.reconcilePhoneManifest(conversationManager.conversations)
                    },
                    apply: {
                        await apply(conversationManager)
                    }
                )
            }

            private func persistLegacyConversation(
                _ conversation: Conversation,
                with conversationManager: ConversationManager
            ) async -> Bool {
                switch await conversationManager.persistProposedConversation(conversation).value {
                case .saved:
                    conversationManager.commitPersistedConversation(conversation)
                    return true
                case let .failed(error):
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Legacy Watch mutation persistence failed",
                        metadata: [
                            "conversationId": conversation.id.uuidString,
                            "error": error
                        ]
                    )
                    return false
                case .superseded:
                    return false
                }
            }

            private func handleLegacyMessage(
                from watchMessage: WatchMessage,
                conversationID: UUID,
                metadata: WatchLegacyMutationMetadata
            ) async {
                await processLegacyPayload { [weak self] conversationManager in
                    guard let self,
                          metadata.isFromActivePeer(self.activeWatchPeerID)
                    else {
                        return
                    }
                    guard !metadata.isCovered(
                        conversationID: conversationID,
                        activePeerID: self.activeWatchPeerID,
                        acknowledgements: self.acknowledgedWatchRevisions
                    ) else {
                        return
                    }
                    guard self.tombstoneRevisions[conversationID] == nil else {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .info,
                            message: "Ignoring legacy Watch message for deleted conversation",
                            metadata: ["conversationId": conversationID.uuidString]
                        )
                        return
                    }
                    let converted = watchMessage.toMessage()

                    let proposed: Conversation
                    let createdPlaceholder: Bool
                    if var conversation = conversationManager.conversations.first(where: { $0.id == conversationID }) {
                        createdPlaceholder = false
                        if let index = conversation.messages.firstIndex(where: { $0.id == converted.id }) {
                            guard conversation.messages[index] != converted else { return }
                            conversation.messages[index] = converted
                        } else {
                            conversation.messages.append(converted)
                        }
                        conversation.updatedAt = max(conversation.updatedAt, converted.timestamp)
                        proposed = conversation
                    } else {
                        createdPlaceholder = true
                        proposed = Conversation(
                            id: conversationID,
                            title: "Watch Chat",
                            messages: [converted],
                            createdAt: converted.timestamp,
                            updatedAt: converted.timestamp,
                            model: AIService.shared.selectedModel
                        )
                    }
                    guard await self.persistLegacyConversation(proposed, with: conversationManager) else { return }
                    if createdPlaceholder,
                       self.legacyPlaceholderConversationIDs.insert(conversationID).inserted
                    {
                        self.persistSyncMetadata()
                    }
                    self.syncConversationsToWatch(conversationManager.conversations)
                }
            }

            private func handleLegacyConversation(
                _ watchConversation: WatchConversation,
                metadata: WatchLegacyMutationMetadata
            ) async {
                await processLegacyPayload { [weak self] conversationManager in
                    guard let self,
                          self.tombstoneRevisions[watchConversation.id] == nil
                    else {
                        return
                    }

                    let existing = conversationManager.conversations.first {
                        $0.id == watchConversation.id
                    }
                    let action = WatchLegacyCreateIngressResolver.action(
                        metadata: metadata,
                        conversationID: watchConversation.id,
                        activePeerID: self.activeWatchPeerID,
                        acknowledgements: self.acknowledgedWatchRevisions,
                        conversationExists: existing != nil,
                        isTrackedPlaceholder: self.legacyPlaceholderConversationIDs.contains(
                            watchConversation.id
                        )
                    )
                    guard action != .ignore else {
                        if metadata.isCovered(
                            conversationID: watchConversation.id,
                            activePeerID: self.activeWatchPeerID,
                            acknowledgements: self.acknowledgedWatchRevisions
                        ), self.legacyPlaceholderConversationIDs.remove(watchConversation.id) != nil {
                            self.persistSyncMetadata()
                        }
                        return
                    }
                    let conversation = WatchLegacyConversationMerger.mergeCreate(
                        watchConversation,
                        into: action == .repairPlaceholder ? existing : nil
                    )
                    guard await self.persistLegacyConversation(conversation, with: conversationManager) else { return }
                    if self.legacyPlaceholderConversationIDs.remove(watchConversation.id) != nil {
                        self.persistSyncMetadata()
                    }
                    self.syncConversationsToWatch(conversationManager.conversations)
                }
            }

            private func handleLegacyTitleUpdate(
                conversationID: UUID,
                newTitle: String,
                metadata: WatchLegacyMutationMetadata
            ) async {
                await processLegacyPayload { [weak self] conversationManager in
                    guard let self,
                          metadata.isFromActivePeer(self.activeWatchPeerID),
                          !metadata.isCovered(
                              conversationID: conversationID,
                              activePeerID: self.activeWatchPeerID,
                              acknowledgements: self.acknowledgedWatchRevisions
                          ),
                          self.tombstoneRevisions[conversationID] == nil,
                          let conversation = conversationManager.conversations.first(where: { $0.id == conversationID }),
                          conversation.title != newTitle
                    else {
                        return
                    }

                    var updated = conversation
                    updated.title = newTitle
                    updated.updatedAt = Date()
                    guard await self.persistLegacyConversation(updated, with: conversationManager) else { return }
                    self.syncConversationsToWatch(conversationManager.conversations)
                }
            }

            private func handleReceivedMessage(_ message: [String: Any]) async -> [String: Any]? {
                guard let type = message[WatchMessageKeys.type] as? String else { return nil }

                switch type {
                case WatchMessageKeys.typeMutation, "conversationMutation":
                    guard let data = message[WatchMessageKeys.mutation] as? Data else {
                        return unsupportedMutationReply(for: message)
                    }
                    do {
                        let mutation = try JSONDecoder().decode(
                            WatchConversationMutation.self,
                            from: data
                        )
                        let schemaVersion = message[WatchMessageKeys.schemaVersion]
                            ?? (type == "conversationMutation" ? NSNumber(value: 1) : nil)
                        return await handleMutation(
                            mutation,
                            schemaVersion: schemaVersion
                        )
                    } catch {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Failed to decode Watch mutation",
                            metadata: ["error": error.localizedDescription]
                        )
                        return unsupportedMutationReply(for: message)
                    }

                case WatchMessageKeys.typeNewMessage:
                    guard let data = message[WatchMessageKeys.newMessage] as? Data,
                          let idString = message[WatchMessageKeys.conversationId] as? String,
                          let id = UUID(uuidString: idString),
                          let watchMessage = try? JSONDecoder().decode(WatchMessage.self, from: data)
                    else {
                        return nil
                    }
                    await handleLegacyMessage(
                        from: watchMessage,
                        conversationID: id,
                        metadata: WatchLegacyMutationMetadata(message: message)
                    )

                case WatchMessageKeys.typeNewConversation:
                    guard let data = message[WatchMessageKeys.conversation] as? Data,
                          let conversation = try? JSONDecoder().decode(WatchConversation.self, from: data)
                    else {
                        return nil
                    }
                    await handleLegacyConversation(
                        conversation,
                        metadata: WatchLegacyMutationMetadata(message: message)
                    )

                case WatchMessageKeys.typeRequestSync:
                    let advertisedMaximumSchema = WatchSyncCapability.advertisedMaximumSchemaVersion(
                        message[WatchMessageKeys.schemaVersion]
                    )
                    if let peerIDString = message[WatchMessageKeys.peerId] as? String,
                       let peerID = UUID(uuidString: peerIDString)
                    {
                        await mutationProcessingQueue.enqueue { [weak self] in
                            guard let self else { return }
                            self.activateWatchPeer(peerID)
                            self.activeWatchCapability.apply(.advertisedMaximumSchema(advertisedMaximumSchema))
                        }
                    } else {
                        await mutationProcessingQueue.enqueue { [weak self] in
                            self?.activeWatchCapability.apply(.advertisedMaximumSchema(advertisedMaximumSchema))
                        }
                    }
                    if let conversations = conversationManager?.conversations {
                        let requestedPage = (message[WatchMessageKeys.pageCycleRequest] as? Data)
                            .flatMap {
                                try? JSONDecoder().decode(WatchSyncPageCycleRequest.self, from: $0)
                            }
                        if let requestedPage,
                           requestedPage.cursor.isValid,
                           let publication = pageCycleCoordinator.publicationRequest(for: requestedPage)
                        {
                            publishConversationsToWatch(conversations, pageCycle: publication)
                        } else {
                            syncConversationsToWatch(conversations)
                        }
                    }

                case WatchMessageKeys.typeTitleUpdate:
                    guard let idString = message[WatchMessageKeys.conversationId] as? String,
                          let id = UUID(uuidString: idString),
                          let title = message[WatchMessageKeys.title] as? String
                    else {
                        return nil
                    }
                    await handleLegacyTitleUpdate(
                        conversationID: id,
                        newTitle: title,
                        metadata: WatchLegacyMutationMetadata(message: message)
                    )

                default:
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 Unknown message type from Watch",
                        metadata: ["type": type]
                    )
                }
                return nil
            }

            private func unsupportedMutationReply(
                for message: [String: Any]
            ) -> [String: Any] {
                var reply: [String: Any] = [
                    WatchMessageKeys.type: WatchMessageKeys.typeMutationAck,
                    WatchMessageKeys.status: "unsupported"
                ]
                for key in [WatchMessageKeys.operationId, WatchMessageKeys.conversationId] {
                    if let value = message[key] as? String {
                        reply[key] = value
                    }
                }
                return reply
            }

            private func reconcilePhoneManifest(_ conversations: [Conversation]) {
                let currentIDs = Set(conversations.map(\.id))
                if hasPersistedManifest {
                    let deletionRevision = nextSnapshotRevision()
                    for id in knownConversationIDs.subtracting(currentIDs) {
                        tombstoneRevisions[id] = max(
                            tombstoneRevisions[id] ?? 0,
                            acknowledgedWatchRevisions[id] ?? 0,
                            deletionRevision
                        )
                    }
                }
                for id in currentIDs {
                    tombstoneRevisions.removeValue(forKey: id)
                }
                knownConversationIDs = currentIDs
                legacyPlaceholderConversationIDs.formIntersection(currentIDs)
                hasPersistedManifest = true
                pruneSyncMetadata(currentConversationIDs: currentIDs)
                persistSyncMetadata()
            }

            private func pruneSyncMetadata(currentConversationIDs: Set<UUID>) {
                let retainedIDs = currentConversationIDs
                var retainedAcknowledgements = acknowledgedWatchRevisions.filter {
                    retainedIDs.contains($0.key)
                }
                if retainedAcknowledgements.count < 128 {
                    for entry in acknowledgedWatchRevisions
                        .filter({ !retainedIDs.contains($0.key) })
                        .sorted(by: { $0.value > $1.value })
                        .prefix(128 - retainedAcknowledgements.count)
                    {
                        retainedAcknowledgements[entry.key] = entry.value
                    }
                }
                acknowledgedWatchRevisions = retainedAcknowledgements
            }

            private func nextSnapshotRevision() -> WatchSyncRevision {
                let next = snapshotRevision &+ 1
                return next == 0 ? 1 : next
            }

            private func incrementSnapshotRevision() -> WatchSyncRevision {
                if snapshotRevision == .max {
                    sourceID = UUID()
                    snapshotRevision = 1
                } else {
                    snapshotRevision = nextSnapshotRevision()
                }
                persistSyncMetadata()
                return snapshotRevision
            }

            private func loadSyncMetadata() {
                let defaults = UserDefaults.standard
                let sourceMetadata = WatchSyncSourceMetadata.resolve(
                    persistedSourceID: defaults.string(forKey: WatchSyncPersistenceKeys.sourceID),
                    persistedSnapshotRevision: defaults.object(
                        forKey: WatchSyncPersistenceKeys.snapshotRevision
                    ),
                    replacementSourceID: UUID()
                )
                sourceID = sourceMetadata.sourceID
                snapshotRevision = sourceMetadata.snapshotRevision
                activeWatchPeerID = defaults.string(forKey: WatchSyncPersistenceKeys.activeWatchPeerID)
                    .flatMap(UUID.init(uuidString:))
                acknowledgedWatchRevisionsByPeer = WatchSyncMetadataCodec.decodePeerRevisionMaps(
                    defaults.data(forKey: WatchSyncPersistenceKeys.acknowledgedWatchRevisionsByPeer)
                )
                let legacyAcknowledgements = WatchSyncMetadataCodec.decodeRevisionMap(
                    defaults.data(forKey: WatchSyncPersistenceKeys.acknowledgedWatchRevisions)
                )
                if let activeWatchPeerID {
                    acknowledgedWatchRevisions = acknowledgedWatchRevisionsByPeer[activeWatchPeerID]
                        ?? legacyAcknowledgements
                } else {
                    acknowledgedWatchRevisions = legacyAcknowledgements
                }
                tombstoneRevisions = WatchSyncMetadataCodec.decodeRevisionMap(
                    defaults.data(forKey: WatchSyncPersistenceKeys.tombstoneRevisions)
                )
                if let trackerData = defaults.data(forKey: WatchSyncPersistenceKeys.modelRemovalTracker),
                   let decodedTracker = try? JSONDecoder().decode(
                       WatchModelRemovalTracker.self,
                       from: trackerData
                   )
                {
                    modelRemovalTracker = decodedTracker
                }
                if let encodedIDs = defaults.array(forKey: WatchSyncPersistenceKeys.authoritativeConversationIDs) as? [String] {
                    knownConversationIDs = Set(encodedIDs.compactMap(UUID.init(uuidString:)))
                    hasPersistedManifest = true
                }
                if let placeholderIDs = defaults.array(
                    forKey: WatchSyncPersistenceKeys.legacyPlaceholderConversationIDs
                ) as? [String] {
                    legacyPlaceholderConversationIDs = Set(
                        placeholderIDs.compactMap(UUID.init(uuidString:))
                    )
                }
            }

            private func persistSyncMetadata() {
                let defaults = UserDefaults.standard
                if let activeWatchPeerID {
                    acknowledgedWatchRevisionsByPeer[activeWatchPeerID] = acknowledgedWatchRevisions
                }
                defaults.set(sourceID.uuidString, forKey: WatchSyncPersistenceKeys.sourceID)
                defaults.set(NSNumber(value: snapshotRevision), forKey: WatchSyncPersistenceKeys.snapshotRevision)
                defaults.set(WatchSyncMetadataCodec.encodeRevisionMap(acknowledgedWatchRevisions), forKey: WatchSyncPersistenceKeys.acknowledgedWatchRevisions)
                defaults.set(
                    WatchSyncMetadataCodec.encodePeerRevisionMaps(acknowledgedWatchRevisionsByPeer),
                    forKey: WatchSyncPersistenceKeys.acknowledgedWatchRevisionsByPeer
                )
                defaults.set(activeWatchPeerID?.uuidString, forKey: WatchSyncPersistenceKeys.activeWatchPeerID)
                defaults.set(WatchSyncMetadataCodec.encodeRevisionMap(tombstoneRevisions), forKey: WatchSyncPersistenceKeys.tombstoneRevisions)
                defaults.set(
                    try? JSONEncoder().encode(modelRemovalTracker),
                    forKey: WatchSyncPersistenceKeys.modelRemovalTracker
                )
                defaults.set(
                    knownConversationIDs.map(\.uuidString).sorted(),
                    forKey: WatchSyncPersistenceKeys.authoritativeConversationIDs
                )
                defaults.set(
                    legacyPlaceholderConversationIDs.map(\.uuidString).sorted(),
                    forKey: WatchSyncPersistenceKeys.legacyPlaceholderConversationIDs
                )
            }

            private func activateWatchPeer(_ peerID: UUID) {
                guard activeWatchPeerID != peerID else { return }
                if let activeWatchPeerID {
                    acknowledgedWatchRevisionsByPeer[activeWatchPeerID] = acknowledgedWatchRevisions
                }
                activeWatchPeerID = peerID
                acknowledgedWatchRevisions = acknowledgedWatchRevisionsByPeer[peerID] ?? [:]
                activeWatchCapability.apply(.reset)
                pageCycleCoordinator.reset()
                persistSyncMetadata()
            }

            private func isCurrentCallback(
                sessionID: ObjectIdentifier,
                activation: WatchSessionActivationToken
            ) -> Bool {
                guard activationFence.isCurrent(activation),
                      callbackIdentityFence.isCurrent(
                          sessionID: sessionID,
                          activation: activation
                      ),
                      let session
                else {
                    return false
                }
                return ObjectIdentifier(session) == sessionID
            }
        }

        extension WatchConnectivityService {
            nonisolated func handleSessionActivation(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                state activationState: WCSessionActivationState,
                error: Error?
            ) {
                let sessionID = ObjectIdentifier(session)
                let installed = session.isWatchAppInstalled
                let reachable = session.isReachable
                let errorDescription = error?.localizedDescription
                Task { @MainActor in
                    guard isCurrentCallback(sessionID: sessionID, activation: activation) else { return }
                    if let errorDescription {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ iOS session activation failed",
                            metadata: ["error": errorDescription]
                        )
                        return
                    }
                    isWatchAppInstalled = installed
                    isReachable = reachable
                    if installed, let conversations = conversationManager?.conversations {
                        syncConversationsToWatch(conversations)
                    }
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 iOS session activated",
                        metadata: ["state": "\(activationState.rawValue)", "reachable": "\(reachable)"]
                    )
                }
            }

            nonisolated func handleSessionDidBecomeInactive(
                _ session: WCSession,
                activation: WatchSessionActivationToken
            ) {
                let sessionID = ObjectIdentifier(session)
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 iOS session became inactive"
                    )
                }
            }

            nonisolated func handleSessionDidDeactivate(
                _ session: WCSession,
                activation: WatchSessionActivationToken
            ) {
                let sessionID = ObjectIdentifier(session)
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    self.activeWatchCapability.apply(.reset)
                    self.pageCycleCoordinator.reset()
                    guard let currentSession = self.session else { return }
                    self.activateSession(currentSession)
                }
            }

            nonisolated func handleSessionWatchStateDidChange(
                _ session: WCSession,
                activation: WatchSessionActivationToken
            ) {
                let sessionID = ObjectIdentifier(session)
                let installed = session.isWatchAppInstalled
                let reachable = session.isReachable
                Task { @MainActor in
                    guard isCurrentCallback(sessionID: sessionID, activation: activation) else { return }
                    isWatchAppInstalled = installed
                    isReachable = reachable
                    if installed, let conversations = conversationManager?.conversations {
                        syncConversationsToWatch(conversations)
                    }
                }
            }

            nonisolated func handleSessionReachabilityDidChange(
                _ session: WCSession,
                activation: WatchSessionActivationToken
            ) {
                let sessionID = ObjectIdentifier(session)
                let reachable = session.isReachable
                Task { @MainActor in
                    guard isCurrentCallback(sessionID: sessionID, activation: activation) else { return }
                    isReachable = reachable
                    if reachable, let conversations = conversationManager?.conversations {
                        syncConversationsToWatch(conversations)
                    }
                }
            }

            nonisolated func handleSession(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                didReceiveMessage message: [String: Any]
            ) {
                let sessionID = ObjectIdentifier(session)
                let message = UncheckedSendableWrapper(message)
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    _ = await self.handleReceivedMessage(message.value)
                }
            }

            nonisolated func handleSession(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                didReceiveMessage message: [String: Any],
                replyHandler: @escaping ([String: Any]) -> Void
            ) {
                let sessionID = ObjectIdentifier(session)
                let message = UncheckedSendableWrapper(message)
                let replyHandler = UncheckedSendableWrapper(replyHandler)
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        replyHandler.value([WatchMessageKeys.status: "staleSession"])
                        return
                    }
                    await replyHandler.value(
                        self.handleReceivedMessage(message.value) ?? [WatchMessageKeys.status: "received"]
                    )
                }
            }

            nonisolated func handleSession(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                didReceiveUserInfo userInfo: [String: Any]
            ) {
                let sessionID = ObjectIdentifier(session)
                let userInfo = UncheckedSendableWrapper(userInfo)
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    _ = await self.handleReceivedMessage(userInfo.value)
                }
            }

            nonisolated func handleSession(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                didReceive file: WCSessionFile
            ) {
                let sessionID = ObjectIdentifier(session)
                guard activationFence.isCurrent(activation),
                      callbackIdentityFence.isCurrent(
                          sessionID: sessionID,
                          activation: activation
                      )
                else {
                    return
                }

                let capture: Result<WatchMutationFileCapture, WatchMutationFileTransportError>
                do {
                    capture = try .success(WatchMutationFileTransport.capture(
                        fileURL: file.fileURL,
                        metadata: file.metadata ?? [:],
                        sessionIsCurrent: true
                    ))
                } catch let error as WatchMutationFileTransportError {
                    capture = .failure(error)
                } catch {
                    capture = .failure(.unreadableFile)
                }
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    switch capture {
                    case let .success(captured):
                        do {
                            let received = try WatchMutationFileTransport.decode(captured)
                            _ = await self.handleMutation(
                                received.mutation,
                                schemaVersion: NSNumber(value: received.schemaVersion)
                            )
                        } catch {
                            DiagnosticsLogger.log(
                                .watchConnectivity,
                                level: .error,
                                message: "❌ Rejected Watch mutation file",
                                metadata: ["error": error.localizedDescription]
                            )
                        }
                    case let .failure(error):
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Rejected Watch mutation file",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }
        }

    #endif

    #if os(watchOS)

        @MainActor
        // swiftlint:disable:next type_body_length
        final class WatchConnectivityService: NSObject, ObservableObject {
            static let shared = WatchConnectivityService()
            @Published private(set) var isReachable = false
            @Published private(set) var lastSyncDate: Date?
            @Published var selectedModel: String = ""
            @Published var availableModels: [String] = []
            @Published private(set) var defaultSystemPrompt = WatchDefaultSystemPromptPersistence.load()

            private nonisolated let activationFence = WatchSessionActivationFence()
            private nonisolated let sessionEventQueue = WatchSessionEventQueue()
            private let legacyDeliveryTracker = WatchLegacyDeliveryTracker()
            private let legacyOperationTracker = WatchLegacyOperationTracker()
            private let legacyAcknowledgementRetryTracker = WatchLegacyAcknowledgementRetryTracker()
            private var session: WCSession?
            private var sessionDelegate: WatchSessionDelegateProxy?
            private var conversationStore: WatchConversationStore?
            private var configuredStoreID: ObjectIdentifier?
            private var queuedMutationOperationIDs: Set<UUID> = []
            private var queuedMutationFileOperationIDs: Set<UUID> = []
            private var interactiveMutationOperationIDs: Set<UUID> = []
            private var mutationFileURLs: [UUID: URL] = [:]
            private var mutationRetryAttempts: [UUID: Int] = [:]
            private var mutationRetryTasks: [UUID: Task<Void, Never>] = [:]
            private var peerSyncMode: WatchPeerSyncMode = .unknown
            private var pageCycleCoordinator = WatchPageCycleCoordinator()
            private let pageCycleRetryController = WatchPageCycleRequestRetryController()
            private var modelMetadataAccumulator = WatchModelMetadataCycleAccumulator()
            private var pendingModelMetadataEpoch: UUID?
            private var appliedModelMetadataEpoch = UserDefaults.standard
                .string(forKey: WatchSyncPersistenceKeys.appliedModelMetadataEpoch)
                .flatMap(UUID.init(uuidString:))
            private var pageCycleHandshakeTracker = WatchPageCycleHandshakeTracker()
            private var syncRequestPending = false

            override private init() {
                super.init()
                setupSession()
            }

            private func setupSession() {
                guard WCSession.isSupported() else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "WatchConnectivity not supported"
                    )
                    return
                }

                activateSession(WCSession.default)

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Watch WatchConnectivity session activating"
                )
            }

            private func activateSession(_ targetSession: WCSession) {
                retirePageCycle()
                let activation = activationFence.beginActivation()
                let delegate = WatchSessionDelegateProxy(
                    owner: self,
                    activation: activation
                )
                session = targetSession
                sessionDelegate = delegate
                targetSession.delegate = delegate
                targetSession.activate()
            }

            func configure(with store: WatchConversationStore) {
                conversationStore = store
                let storeID = ObjectIdentifier(store)
                if configuredStoreID != storeID {
                    configuredStoreID = storeID
                }

                guard let session, let activation = sessionDelegate?.activation else { return }
                let sessionID = ObjectIdentifier(session)
                let context = UncheckedSendableWrapper(session.receivedApplicationContext)
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    if !context.value.isEmpty {
                        self.processContext(context.value)
                    }
                    self.flushPendingMutations()
                }
            }

            func enqueueMutation(_ mutation: WatchConversationMutation) {
                let envelope = durableEnvelope(for: mutation)
                legacyDeliveryTracker.recordTitleMutation(envelope)
                if legacyAcknowledgementRetryTracker.contains(operationID: envelope.operationID) {
                    retryPendingLocalAcknowledgements()
                    if legacyAcknowledgementRetryTracker.contains(operationID: envelope.operationID) {
                        scheduleMutationRetry(for: envelope.operationID)
                    }
                    return
                }

                guard let session, session.activationState == .activated else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Mutation remains durable until WatchConnectivity activates",
                        metadata: ["operationId": mutation.operationID.uuidString]
                    )
                    return
                }

                do {
                    var legacyResult: WatchLegacySendResult?
                    if peerSyncMode != .revisioned {
                        legacyResult = try WatchLegacyMutationSender.prepare(
                            envelope,
                            tracker: legacyDeliveryTracker
                        )
                    }
                    if let legacyResult, !legacyResult.componentIDs.isEmpty {
                        legacyOperationTracker.begin(envelope, result: legacyResult)
                        let outstandingComponentIDs = Set(session.outstandingUserInfoTransfers.compactMap {
                            $0.userInfo[WatchMessageKeys.legacyComponentId] as? String
                        })
                        for userInfo in legacyResult.userInfos where
                            !outstandingComponentIDs.contains(
                                userInfo[WatchMessageKeys.legacyComponentId] as? String ?? ""
                            )
                        {
                            session.transferUserInfo(userInfo)
                        }
                    }
                    if peerSyncMode == .legacy {
                        guard let legacyResult else { return }
                        if legacyResult.requiresEchoRetry {
                            requestSync()
                            scheduleMutationRetry(for: envelope.operationID)
                        }
                        if legacyResult.componentIDs.isEmpty,
                           legacyResult.awaitingEchoComponentIDs.isEmpty,
                           legacyResult.fullyRepresented
                        {
                            requestSync()
                            scheduleMutationRetry(for: envelope.operationID)
                        }
                        return
                    }
                    let message = try mutationMessage(envelope)
                    queueReliableMutation(message, mutation: envelope, session: session)
                    sendInteractiveMutation(message, mutation: envelope, session: session)
                } catch let error as WatchSyncPayloadBuilderError {
                    guard case .mutationExceedsBudget = error else {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Failed to encode Watch mutation",
                            metadata: ["error": error.localizedDescription]
                        )
                        return
                    }
                    do {
                        try queueMutationFile(envelope, session: session)
                    } catch {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Failed to queue oversized Watch mutation file",
                            metadata: ["error": error.localizedDescription]
                        )
                        scheduleMutationRetry(for: envelope.operationID)
                    }
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to encode Watch mutation",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            func requestSync() {
                let request = pageCycleCoordinator.pendingRequest.map {
                    WatchSyncRequestIdentity.pageCycle($0)
                } ?? .freshCycle
                retainSyncRequest(request)
                sendSyncRequest(request)
            }

            private func sendSyncRequest(_ request: WatchSyncRequestIdentity) {
                guard let session,
                      session.activationState == .activated,
                      let activation = sessionDelegate?.activation
                else {
                    syncRequestPending = true
                    return
                }

                var message: [String: Any] = [
                    WatchMessageKeys.type: WatchMessageKeys.typeRequestSync,
                    WatchMessageKeys.peerId: conversationStore?.peerID.uuidString
                        ?? WatchSyncIdentity.legacyPeerID.uuidString,
                    WatchMessageKeys.schemaVersion: NSNumber(value: WatchSyncSnapshot.currentSchemaVersion)
                ]
                if let pageCycleRequest = request.pageCycleRequest,
                   let requestData = try? JSONEncoder().encode(pageCycleRequest)
                {
                    message[WatchMessageKeys.pageCycleRequest] = requestData
                }

                if session.isReachable {
                    let sessionID = ObjectIdentifier(session)
                    let sessionWrapper = UncheckedSendableWrapper(session)
                    let messageWrapper = UncheckedSendableWrapper(message)
                    session.sendMessage(message, replyHandler: nil) { [weak self] error in
                        let errorDescription = error.localizedDescription
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.isCurrentCallback(
                                      sessionID: sessionID,
                                      activation: activation
                                  ),
                                  self.syncRequestIdentity(in: messageWrapper.value)
                                  == self.pageCycleRetryController.pendingRequest
                            else {
                                return
                            }
                            self.queueReliableSyncRequestIfNeeded(
                                messageWrapper.value,
                                session: sessionWrapper.value
                            )
                            DiagnosticsLogger.log(
                                .watchConnectivity,
                                level: .error,
                                message: "❌ Failed to request immediate sync; queued reliable fallback",
                                metadata: ["error": errorDescription]
                            )
                        }
                    }
                } else {
                    queueReliableSyncRequestIfNeeded(message, session: session)
                }
                syncRequestPending = false
            }

            private func retainSyncRequest(_ request: WatchSyncRequestIdentity?) {
                let previousRequest = pageCycleRetryController.pendingRequest
                if previousRequest != request,
                   let previousRequest,
                   let session
                {
                    cancelReliableSyncRequest(previousRequest, session: session)
                }
                pageCycleRetryController.retain(request) { [weak self] request in
                    self?.sendSyncRequest(request)
                }
            }

            private func queueReliableSyncRequestIfNeeded(
                _ message: [String: Any],
                session: WCSession
            ) {
                guard let request = syncRequestIdentity(in: message),
                      request == pageCycleRetryController.pendingRequest
                else {
                    return
                }
                let alreadyQueued = session.outstandingUserInfoTransfers.contains { transfer in
                    syncRequestIdentity(in: transfer.userInfo) == request
                }
                guard !alreadyQueued else { return }
                session.transferUserInfo(message)
            }

            private func cancelReliableSyncRequest(
                _ request: WatchSyncRequestIdentity,
                session: WCSession
            ) {
                for transfer in session.outstandingUserInfoTransfers
                    where syncRequestIdentity(in: transfer.userInfo) == request
                {
                    transfer.cancel()
                }
            }

            private func syncRequestIdentity(
                in message: [String: Any]
            ) -> WatchSyncRequestIdentity? {
                guard message[WatchMessageKeys.type] as? String == WatchMessageKeys.typeRequestSync else {
                    return nil
                }
                guard let requestData = message[WatchMessageKeys.pageCycleRequest] as? Data else {
                    return .freshCycle
                }
                guard let request = try? JSONDecoder().decode(
                    WatchSyncPageCycleRequest.self,
                    from: requestData
                ) else {
                    return nil
                }
                return .pageCycle(request)
            }

            private func retirePageCycle() {
                if let pendingRequest = pageCycleRetryController.pendingRequest,
                   let session
                {
                    cancelReliableSyncRequest(pendingRequest, session: session)
                }
                pageCycleRetryController.cancel()
                pageCycleCoordinator.reset()
                modelMetadataAccumulator.reset()
                conversationStore?.resetPageCycleManifest()
            }

            func sendMessage(_: WatchMessage, conversationId: UUID) {
                enqueueLatestMutation(for: conversationId)
            }

            func sendConversation(_ conversation: WatchConversation) {
                enqueueLatestMutation(for: conversation.id)
            }

            func sendTitleUpdate(conversationId: UUID, newTitle _: String) {
                enqueueLatestMutation(for: conversationId)
            }

            private func enqueueLatestMutation(for conversationID: UUID) {
                guard let mutation = conversationStore?.pendingMutationsForSync
                    .filter({ $0.conversationID == conversationID })
                    .max(by: { $0.revision < $1.revision })
                else {
                    return
                }
                enqueueMutation(mutation)
            }

            private func durableEnvelope(for mutation: WatchConversationMutation) -> WatchConversationMutation {
                conversationStore?.pendingMutationsForSync
                    .filter { $0.conversationID == mutation.conversationID }
                    .max { $0.revision < $1.revision } ?? mutation
            }

            private func mutationMessage(_ mutation: WatchConversationMutation) throws -> [String: Any] {
                let payload = try WatchSyncPayloadBuilder.buildMutation(mutation)
                return [
                    WatchMessageKeys.type: WatchMessageKeys.typeMutation,
                    WatchMessageKeys.mutation: payload.data,
                    WatchMessageKeys.operationId: mutation.operationID.uuidString,
                    WatchMessageKeys.conversationId: mutation.conversationID.uuidString,
                    WatchMessageKeys.schemaVersion: NSNumber(value: WatchSyncSnapshot.currentSchemaVersion)
                ]
            }

            private func queueReliableMutation(
                _ message: [String: Any],
                mutation: WatchConversationMutation,
                session: WCSession
            ) {
                guard !queuedMutationOperationIDs.contains(mutation.operationID),
                      !hasOutstandingTransfer(for: mutation.operationID, session: session)
                else {
                    return
                }
                queuedMutationOperationIDs.insert(mutation.operationID)
                session.transferUserInfo(message)
            }

            private func queueMutationFile(
                _ mutation: WatchConversationMutation,
                session: WCSession
            ) throws {
                guard !queuedMutationFileOperationIDs.contains(mutation.operationID),
                      !WatchMutationFileTransport.hasOutstandingTransfer(
                          operationID: mutation.operationID,
                          session: session
                      )
                else {
                    return
                }

                let fileURL = try WatchMutationFileTransport.transfer(mutation, session: session)
                queuedMutationFileOperationIDs.insert(mutation.operationID)
                mutationFileURLs[mutation.operationID] = fileURL
            }

            private func sendInteractiveMutation(
                _ message: [String: Any],
                mutation: WatchConversationMutation,
                session: WCSession
            ) {
                guard session.isReachable,
                      interactiveMutationOperationIDs.insert(mutation.operationID).inserted
                else {
                    return
                }

                session.sendMessage(message) { [weak self] reply in
                    Task { @MainActor in
                        self?.interactiveMutationOperationIDs.remove(mutation.operationID)
                        self?.processMutationAcknowledgement(reply, fallback: mutation)
                    }
                } errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.interactiveMutationOperationIDs.remove(mutation.operationID)
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .info,
                            message: "⌚ Immediate mutation send failed; reliable transfer remains queued",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }

            private func processMutationAcknowledgement(
                _ reply: [String: Any],
                fallback mutation: WatchConversationMutation
            ) {
                guard let revision = WatchSyncValueDecoder.revision(reply[WatchMessageKeys.acknowledgedRevision]) else { return }
                let conversationID = (reply[WatchMessageKeys.conversationId] as? String)
                    .flatMap(UUID.init(uuidString:)) ?? mutation.conversationID
                guard conversationID == mutation.conversationID,
                      conversationStore?.acknowledgeWatchRevision(
                          conversationID: conversationID,
                          revision: revision
                      ) == true
                else {
                    scheduleMutationRetry(for: mutation.operationID)
                    return
                }
                cancelReliableTransfers(for: mutation.operationID)
                cancelMutationRetry(for: mutation.operationID)
            }

            private func retryPendingLocalAcknowledgements() {
                guard let conversationStore else { return }
                let acknowledged = legacyAcknowledgementRetryTracker.retry { conversationID, revision in
                    conversationStore.acknowledgeWatchRevision(
                        conversationID: conversationID,
                        revision: revision
                    )
                }
                for acknowledgement in acknowledged {
                    cancelReliableTransfers(for: acknowledgement.operationID)
                    cancelMutationRetry(for: acknowledgement.operationID)
                }
            }

            private func flushPendingMutations() {
                retryPendingLocalAcknowledgements()
                for mutation in conversationStore?.pendingMutationsForSync ?? [] where
                    !legacyAcknowledgementRetryTracker.contains(operationID: mutation.operationID)
                {
                    enqueueMutation(mutation)
                }
            }

            private func scheduleMutationRetry(for operationID: UUID) {
                guard mutationRetryTasks[operationID] == nil else { return }
                let attempt = mutationRetryAttempts[operationID, default: 0]
                mutationRetryAttempts[operationID] = attempt + 1
                let delay = WatchMutationRetryBackoff.seconds(forAttempt: attempt)
                mutationRetryTasks[operationID] = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.mutationRetryTasks.removeValue(forKey: operationID)
                    guard let mutation = self.conversationStore?.pendingMutationsForSync.first(where: {
                        $0.operationID == operationID
                    }) else {
                        self.mutationRetryAttempts.removeValue(forKey: operationID)
                        return
                    }
                    self.enqueueMutation(mutation)
                }
            }

            private func cancelMutationRetry(for operationID: UUID) {
                mutationRetryTasks.removeValue(forKey: operationID)?.cancel()
                mutationRetryAttempts.removeValue(forKey: operationID)
            }

            private func hasOutstandingTransfer(for operationID: UUID, session: WCSession) -> Bool {
                session.outstandingUserInfoTransfers.contains { transfer in
                    (transfer.userInfo[WatchMessageKeys.operationId] as? String) == operationID.uuidString
                }
            }

            private func cancelReliableTransfers(for operationID: UUID) {
                if let session {
                    for transfer in session.outstandingUserInfoTransfers where
                        (transfer.userInfo[WatchMessageKeys.operationId] as? String) == operationID.uuidString
                    {
                        transfer.cancel()
                    }
                    for transfer in session.outstandingFileTransfers where
                        (transfer.file.metadata?[WatchMessageKeys.operationId] as? String) == operationID.uuidString
                    {
                        transfer.cancel()
                    }
                }
                queuedMutationOperationIDs.remove(operationID)
                queuedMutationFileOperationIDs.remove(operationID)
                legacyOperationTracker.cancel(operationID: operationID)
                legacyAcknowledgementRetryTracker.cancel(operationID: operationID)
                if let fileURL = mutationFileURLs.removeValue(forKey: operationID) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }

            private func processContext(_ context: [String: Any]) {
                retryPendingLocalAcknowledgements()
                let applicationMode = processConversationsFromContext(context)
                guard applicationMode.appliesSnapshotSettings else { return }
                processModelSettingsFromContext(context, mode: applicationMode)
                processAPIKeysFromContext(context, mode: applicationMode)
                processTavilySettingsFromContext(context, mode: applicationMode)
                processWebFetchSettingsFromContext(context)
                processMemoryFromContext(context)
                let updatedDefaultSystemPrompt = WatchDefaultSystemPromptReducer.value(
                    current: defaultSystemPrompt,
                    incoming: context[WatchContextKeys.defaultSystemPrompt]
                )
                if updatedDefaultSystemPrompt != defaultSystemPrompt {
                    defaultSystemPrompt = updatedDefaultSystemPrompt
                    WatchDefaultSystemPromptPersistence.store(updatedDefaultSystemPrompt)
                }

                if let syncTimestamp = context[WatchContextKeys.lastSyncDate] as? TimeInterval {
                    lastSyncDate = Date(timeIntervalSince1970: syncTimestamp)
                }
            }

            private func processConversationsFromContext(
                _ context: [String: Any]
            ) -> WatchContextApplicationMode {
                let legacyConversations = (context[WatchContextKeys.conversations] as? Data).flatMap {
                    try? JSONDecoder().decode([WatchConversation].self, from: $0)
                }

                var rejectedRevisionedSnapshot = false
                if let data = context[WatchContextKeys.syncSnapshot] as? Data {
                    do {
                        let snapshot = try JSONDecoder().decode(WatchSyncSnapshot.self, from: data)
                        if WatchSyncSnapshot.supportsSchemaVersion(snapshot.schemaVersion) {
                            let pageMetadata = (context[WatchContextKeys.syncPageCycle] as? Data)
                                .flatMap {
                                    try? JSONDecoder().decode(WatchSyncPageCycleMetadata.self, from: $0)
                                }
                            guard prepareRevisionedSnapshotApplication(
                                snapshot,
                                pageMetadata: pageMetadata
                            ) else {
                                return .ignore
                            }
                            let pendingBefore = Set(
                                conversationStore?.pendingMutationsForSync.map(\.operationID) ?? []
                            )
                            let applyOutcome: WatchSyncSnapshotApplyOutcome = if let pageMetadata,
                                                                                 pageMetadata.isValid(for: snapshot)
                            {
                                conversationStore?.applySyncSnapshot(
                                    snapshot,
                                    pageCycleMetadata: pageMetadata
                                ) ?? .persistenceFailed
                            } else {
                                conversationStore?.applySyncSnapshot(snapshot) ?? .persistenceFailed
                            }
                            let pendingAfter = Set(
                                conversationStore?.pendingMutationsForSync.map(\.operationID) ?? []
                            )
                            for operationID in pendingBefore.subtracting(pendingAfter) {
                                cancelReliableTransfers(for: operationID)
                                cancelMutationRetry(for: operationID)
                            }

                            if let pageMetadata {
                                guard pageMetadata.isValid(for: snapshot) else {
                                    if pageCycleCoordinator.pendingRequest != nil {
                                        requestSync()
                                    }
                                    flushPendingMutations()
                                    return .ignore
                                }

                                pageCycleHandshakeTracker.pageCycleReceived()
                                let pageUpdate = pageCycleCoordinator.receive(
                                    pageMetadata,
                                    after: applyOutcome
                                )
                                retainSyncRequest(pageUpdate.pendingRequest.map {
                                    WatchSyncRequestIdentity.pageCycle($0)
                                })
                                if pageUpdate.pendingRequest != nil || pageUpdate.requiresFreshCycle {
                                    requestSync()
                                }
                                if applyOutcome == .persistenceFailed {
                                    DiagnosticsLogger.log(
                                        .watchConnectivity,
                                        level: .error,
                                        message: "⌚ Snapshot page was not durable; retaining exact continuation",
                                        metadata: [
                                            "cycleId": pageMetadata.cycleID.uuidString,
                                            "pageIndex": "\(pageMetadata.cursor.pageIndex)"
                                        ]
                                    )
                                }
                                flushPendingMutations()
                                guard pageUpdate.acceptedPage else { return .ignore }
                                return .page(
                                    cycleID: pageMetadata.cycleID,
                                    completesCycle: pageUpdate.completedCycle,
                                    metadataComplete: pageMetadata.modelMetadataCycleIsAuthoritative
                                )
                            }

                            flushPendingMutations()
                            guard applyOutcome.isDurable else {
                                if applyOutcome == .persistenceFailed {
                                    requestSync()
                                }
                                return .ignore
                            }

                            if snapshot.schemaVersion == WatchSyncSnapshot.currentSchemaVersion {
                                switch pageCycleHandshakeTracker.disposition(
                                    sourceID: snapshot.sourceID,
                                    snapshotRevision: snapshot.revision,
                                    pendingRequest: pageCycleRetryController.pendingRequest
                                ) {
                                case .requestFreshCycle:
                                    retirePageCycle()
                                    requestSync()
                                case .preservePendingFreshCycle:
                                    break
                                case .retireWithoutRequest:
                                    retirePageCycle()
                                }
                            } else {
                                retirePageCycle()
                            }
                            return .standalone(
                                after: applyOutcome,
                                metadataIsComplete: WatchModelMetadataCompleteness
                                    .isExplicitlyComplete(in: context)
                            )
                        }
                        rejectedRevisionedSnapshot = true
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "Ignoring unsupported Watch sync schema and trying legacy payload",
                            metadata: ["schemaVersion": "\(snapshot.schemaVersion)"]
                        )
                    } catch {
                        rejectedRevisionedSnapshot = true
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Failed to decode Watch sync snapshot",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }

                if let legacyConversations {
                    reconcileLegacyDeliveryEchoes(legacyConversations)
                    conversationStore?.updateConversations(legacyConversations)
                    adoptLegacyPeerMode()
                    return .legacy(
                        metadataIsComplete: WatchModelMetadataCompleteness
                            .legacyContextIsComplete(in: context)
                    )
                }

                guard !rejectedRevisionedSnapshot else { return .ignore }
                retirePageCycle()
                return .legacy(
                    metadataIsComplete: WatchModelMetadataCompleteness
                        .legacyContextIsComplete(in: context)
                )
            }

            private func prepareRevisionedSnapshotApplication(
                _ snapshot: WatchSyncSnapshot,
                pageMetadata: WatchSyncPageCycleMetadata?
            ) -> Bool {
                guard conversationStore?.clearLegacyDeliveryCoverage() == true else {
                    if let pageMetadata, pageMetadata.isValid(for: snapshot) {
                        let pageUpdate = pageCycleCoordinator.receive(
                            pageMetadata,
                            after: .persistenceFailed
                        )
                        retainSyncRequest(pageUpdate.pendingRequest.map {
                            WatchSyncRequestIdentity.pageCycle($0)
                        })
                    }
                    requestSync()
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "⌚ Revisioned snapshot deferred because legacy delivery reset was not durable",
                        metadata: ["snapshotRevision": "\(snapshot.revision)"]
                    )
                    return false
                }

                peerSyncMode = .revisioned
                legacyDeliveryTracker.reset()
                legacyAcknowledgementRetryTracker.reset()
                legacyOperationTracker.reset()
                return true
            }

            private func reconcileLegacyDeliveryEchoes(_ echoedConversations: [WatchConversation]) {
                guard let conversationStore else { return }
                for mutation in conversationStore.pendingMutationsForSync {
                    let reconciliation = legacyDeliveryTracker.reconcile(
                        mutation,
                        echoedConversations: echoedConversations
                    )
                    guard conversationStore.markLegacyComponentsDelivered(
                        reconciliation.matchedComponents,
                        for: mutation
                    ) else {
                        scheduleMutationRetry(for: mutation.operationID)
                        continue
                    }
                    for component in reconciliation.matchedComponents {
                        let userInfo = component.deliveryUserInfo(for: mutation)
                        legacyDeliveryTracker.confirm(userInfo)
                    }

                    guard WatchLegacyEchoReconciler.canAcknowledge(
                        mutation,
                        currentMatches: reconciliation.matchedComponents,
                        durableCoverage: conversationStore.durableLegacyDeliveryCoverage(
                            for: mutation.conversationID
                        )
                    ) else {
                        continue
                    }
                    legacyAcknowledgementRetryTracker.retain(mutation)
                    guard conversationStore.acknowledgeWatchRevision(
                        conversationID: mutation.conversationID,
                        revision: mutation.revision
                    ) else {
                        scheduleMutationRetry(for: mutation.operationID)
                        continue
                    }
                    cancelReliableTransfers(for: mutation.operationID)
                    cancelMutationRetry(for: mutation.operationID)
                }
            }

            private func adoptLegacyPeerMode() {
                retirePageCycle()
                peerSyncMode = .legacy
                flushPendingMutations()
            }

            private func processModelSettingsFromContext(
                _ context: [String: Any],
                mode: WatchContextApplicationMode
            ) {
                if case .ignore = mode {
                    return
                }

                let page = WatchModelMetadataPage(context: context)
                let incomingEpoch = (context[WatchContextKeys.modelMetadataEpoch] as? String)
                    .flatMap(UUID.init(uuidString:))
                var state = currentModelMetadataState()
                let epochToPersist = WatchModelMetadataContextReducer.apply(
                    page,
                    mode: mode,
                    incomingEpoch: incomingEpoch,
                    appliedEpoch: appliedModelMetadataEpoch,
                    pendingEpoch: &pendingModelMetadataEpoch,
                    accumulator: &modelMetadataAccumulator,
                    to: &state
                )
                applyModelMetadataState(state)
                if let epochToPersist {
                    appliedModelMetadataEpoch = epochToPersist
                    UserDefaults.standard.set(
                        epochToPersist.uuidString,
                        forKey: WatchSyncPersistenceKeys.appliedModelMetadataEpoch
                    )
                }
            }

            private func currentModelMetadataState() -> WatchModelMetadataState {
                WatchModelMetadataState(
                    selectedModel: selectedModel,
                    availableModels: availableModels,
                    customModels: AIService.shared.customModels,
                    defaultProvider: AIService.shared.provider.rawValue,
                    modelProviders: AIService.shared.modelProviders.mapValues(\.rawValue),
                    modelEndpoints: AIService.shared.modelEndpoints,
                    modelEndpointTypes: AIService.shared.modelEndpointTypes.mapValues(\.rawValue),
                    modelUsesGitHubOAuth: AIService.shared.modelUsesGitHubOAuth,
                    modelAPIKeys: AIService.shared.modelAPIKeys
                )
            }

            private func applyModelMetadataState(_ state: WatchModelMetadataState) {
                selectedModel = state.selectedModel
                AIService.shared.selectedModel = state.selectedModel
                availableModels = state.availableModels
                AIService.shared.customModels = state.customModels
                if let provider = AIProvider(rawValue: state.defaultProvider) {
                    AIService.shared.provider = provider
                }
                AIService.shared.modelProviders = state.modelProviders.reduce(into: [:]) { result, pair in
                    if let provider = AIProvider(rawValue: pair.value) {
                        result[pair.key] = provider
                    }
                }
                AIService.shared.modelEndpoints = state.modelEndpoints
                AIService.shared.modelEndpointTypes = state.modelEndpointTypes.reduce(into: [:]) { result, pair in
                    if let endpointType = APIEndpointType(rawValue: pair.value) {
                        result[pair.key] = endpointType
                    }
                }
                AIService.shared.modelUsesGitHubOAuth = state.modelUsesGitHubOAuth
                AIService.shared.modelAPIKeys = state.modelAPIKeys
            }

            private func processAPIKeysFromContext(
                _ context: [String: Any],
                mode: WatchContextApplicationMode
            ) {
                if let githubToken = context[WatchContextKeys.githubAccessToken] as? String {
                    if githubToken.isEmpty {
                        GitHubOAuthService.shared.signOut()
                    } else {
                        GitHubOAuthService.shared.setAccessTokenFromWatch(githubToken)
                    }
                } else if mode.treatsOmittedCredentialsAsRemoved {
                    GitHubOAuthService.shared.signOut()
                }
            }

            private func processTavilySettingsFromContext(
                _ context: [String: Any],
                mode: WatchContextApplicationMode
            ) {
                if let key = context[WatchContextKeys.tavilyAPIKey] as? String {
                    AIService.shared.tavilyAPIKey = key
                    TavilyService.shared.apiKey = key
                } else if mode.treatsOmittedCredentialsAsRemoved {
                    AIService.shared.tavilyAPIKey = ""
                    TavilyService.shared.apiKey = ""
                }
                if let enabled = context[WatchContextKeys.tavilyEnabled] as? Bool {
                    AIService.shared.tavilyEnabled = enabled
                    AIService.shared.webSearchEnabled = enabled
                    TavilyService.shared.isEnabled = enabled
                }
            }

            private func processWebFetchSettingsFromContext(_ context: [String: Any]) {
                if let enabled = context[WatchContextKeys.webFetchEnabled] as? Bool {
                    WebFetchService.shared.isEnabled = enabled
                }
            }

            private func processMemoryFromContext(_ context: [String: Any]) {
                if let enabled = context[WatchContextKeys.memoryEnabled] as? Bool {
                    MemoryContextProvider.shared.setMemoryEnabled(enabled)
                    if !enabled {
                        UserMemoryService.shared.loadFactsFromSync([])
                        return
                    }
                }
                if let data = context[WatchContextKeys.memoryFacts] as? Data {
                    if data.isEmpty {
                        UserMemoryService.shared.loadFactsFromSync([])
                    } else if let facts = try? JSONDecoder().decode([UserMemoryFact].self, from: data) {
                        UserMemoryService.shared.loadFactsFromSync(facts)
                    }
                }
            }

            private func isCurrentCallback(
                sessionID: ObjectIdentifier,
                activation: WatchSessionActivationToken
            ) -> Bool {
                guard activationFence.isCurrent(activation), let session else { return false }
                return ObjectIdentifier(session) == sessionID
            }
        }

        extension WatchConnectivityService {
            nonisolated func handleSessionActivation(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                state activationState: WCSessionActivationState,
                error: Error?
            ) {
                let sessionID = ObjectIdentifier(session)
                let reachable = session.isReachable
                let receivedContext = UncheckedSendableWrapper(session.receivedApplicationContext)
                let errorDescription = error?.localizedDescription
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    if let errorDescription {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Watch session activation failed",
                            metadata: ["error": errorDescription]
                        )
                        return
                    }
                    self.isReachable = reachable
                    self.peerSyncMode = .unknown
                    self.pageCycleHandshakeTracker.reset()
                    if self.configuredStoreID == nil, let conversationStore = self.conversationStore {
                        conversationStore.initializeFromDisk()
                        self.configuredStoreID = ObjectIdentifier(conversationStore)
                    }
                    if !receivedContext.value.isEmpty {
                        self.processContext(receivedContext.value)
                    }
                    self.flushPendingMutations()
                    if self.syncRequestPending || receivedContext.value.isEmpty {
                        self.requestSync()
                    }
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Watch session activated",
                        metadata: ["state": "\(activationState.rawValue)", "reachable": "\(reachable)"]
                    )
                }
            }

            nonisolated func handleSessionReachabilityDidChange(
                _ session: WCSession,
                activation: WatchSessionActivationToken
            ) {
                let sessionID = ObjectIdentifier(session)
                let reachable = session.isReachable
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    self.isReachable = reachable
                    if reachable {
                        self.flushPendingMutations()
                        self.requestSync()
                    }
                }
            }

            nonisolated func handleSession(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                didReceiveApplicationContext applicationContext: [String: Any]
            ) {
                let sessionID = ObjectIdentifier(session)
                let applicationContext = UncheckedSendableWrapper(applicationContext)
                sessionEventQueue.enqueue { [weak self] in
                    guard let self,
                          self.isCurrentCallback(sessionID: sessionID, activation: activation)
                    else {
                        return
                    }
                    self.processContext(applicationContext.value)
                }
            }

            nonisolated func handleSession(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                error: Error?
            ) {
                let sessionID = ObjectIdentifier(session)
                let operationID = (userInfoTransfer.userInfo[WatchMessageKeys.operationId] as? String)
                    .flatMap(UUID.init(uuidString:))
                let legacyComponentID = userInfoTransfer.userInfo[WatchMessageKeys.legacyComponentId] as? String
                let succeeded = error == nil
                Task { @MainActor in
                    guard isCurrentCallback(sessionID: sessionID, activation: activation), let operationID else {
                        return
                    }
                    let pendingMutations = conversationStore?.pendingMutationsForSync ?? []
                    if let legacyComponentID {
                        let pendingMutation = WatchLegacyTransferCompletionResolver.pendingMutation(
                            originalOperationID: operationID,
                            componentID: legacyComponentID,
                            pendingMutations: pendingMutations
                        )
                        legacyDeliveryTracker.recordTransferCompletion(
                            componentID: legacyComponentID,
                            succeeded: succeeded && pendingMutation != nil
                        )
                        if succeeded, let pendingMutation {
                            requestSync()
                            scheduleMutationRetry(for: pendingMutation.operationID)
                        } else if let pendingMutation {
                            scheduleMutationRetry(for: pendingMutation.operationID)
                        }
                        return
                    }

                    queuedMutationOperationIDs.remove(operationID)
                    if pendingMutations.contains(where: { $0.operationID == operationID }) {
                        scheduleMutationRetry(for: operationID)
                    }
                }
            }

            nonisolated func handleSession(
                _ session: WCSession,
                activation: WatchSessionActivationToken,
                didFinish fileTransfer: WCSessionFileTransfer,
                error _: Error?
            ) {
                let sessionID = ObjectIdentifier(session)
                let operationID = (fileTransfer.file.metadata?[WatchMessageKeys.operationId] as? String)
                    .flatMap(UUID.init(uuidString:))
                let fileURL = fileTransfer.file.fileURL
                Task { @MainActor in
                    guard isCurrentCallback(sessionID: sessionID, activation: activation), let operationID else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    queuedMutationFileOperationIDs.remove(operationID)
                    mutationFileURLs.removeValue(forKey: operationID)
                    try? FileManager.default.removeItem(at: fileURL)
                    if conversationStore?.pendingMutationsForSync.contains(where: {
                        $0.operationID == operationID
                    }) == true {
                        scheduleMutationRetry(for: operationID)
                    }
                }
            }
        }

    #endif

#endif
