//
//  WatchConnectivityService.swift
//  ayna
//
//  Created on 11/29/25.
//

#if os(iOS) || os(watchOS)

    import Combine
    import Foundation
    import os
    import WatchConnectivity

    // Note: WatchConversation and WatchMessage are defined in Core/Models/WatchDataModels.swift
    // to be shared across all platforms (macOS, iOS, watchOS).

    /// Keys for WatchConnectivity context
    private enum WatchContextKeys {
        static let conversations = "conversations"
        static let selectedModel = "selectedModel"
        static let availableModels = "availableModels"
        static let customModels = "customModels"
        static let defaultProvider = "defaultProvider"
        static let modelProviders = "modelProviders"
        static let modelEndpoints = "modelEndpoints"
        static let modelEndpointTypes = "modelEndpointTypes"
        static let modelUsesGitHubOAuth = "modelUsesGitHubOAuth"
        static let modelAPIKeys = "modelAPIKeys"
        static let githubAccessToken = "githubAccessToken"
        static let tavilyAPIKey = "tavilyAPIKey"
        static let tavilyEnabled = "tavilyEnabled"
        static let webFetchEnabled = "webFetchEnabled"
        static let memoryEnabled = "memoryEnabled"
        static let memoryFacts = "memoryFacts"
        static let conversationSyncEpoch = "conversationSyncEpoch"
        static let conversationClearGeneration = "conversationClearGeneration"
        static let lastSyncDate = "lastSyncDate"
    }

    /// Keys for WatchConnectivity messages
    private enum WatchMessageKeys {
        static let type = "type"
        static let conversation = "conversation"
        static let newMessage = "newMessage"
        static let conversationId = "conversationId"
        static let title = "title"

        // Message types
        static let typeNewMessage = "newMessage"
        static let typeNewConversation = "newConversation"
        static let typeRequestSync = "requestSync"
        static let typeSyncResponse = "syncResponse"
        static let typeTitleUpdate = "titleUpdate"
        static let mutationId = "mutationId"
        static let conversationSyncEpoch = "conversationSyncEpoch"
        static let conversationClearGeneration = "conversationClearGeneration"
    }

    private enum WatchSyncPersistence {
        private static let epochKey = "com.sertacozercan.ayna.watch.conversation-sync-epoch"
        private static let generationKey = "com.sertacozercan.ayna.watch.conversation-clear-generation"
        private static let pendingClearCountKey = "com.sertacozercan.ayna.watch.pending-conversation-clears"
        private static let persistenceDirectory = WatchConversationSyncPersistenceLocations.directoryURL

        static let stateStore = WatchConversationSyncStateStore(
            fileURL: persistenceDirectory.appendingPathComponent("conversation-sync-state.json")
        )
        static let mutationInbox = WatchConversationMutationInbox(
            fileURL: persistenceDirectory.appendingPathComponent("phone-mutation-inbox.json")
        )

        static func loadState(creatingPhoneEpoch: Bool) -> WatchConversationSyncState {
            var initialState = legacyState()
            if creatingPhoneEpoch, initialState.identity.epoch == nil {
                initialState.identity = WatchConversationSyncIdentity(
                    epoch: UUID(),
                    generation: initialState.identity.generation
                )
            }

            do {
                let state = try stateStore.load(orCreating: initialState)
                removeLegacyState()
                return state
            } catch {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .error,
                    message: "Failed to load durable Watch synchronization state",
                    metadata: ["error": error.localizedDescription]
                )
                if creatingPhoneEpoch, initialState.pendingClears.isEmpty {
                    initialState.pendingClears = [
                        WatchConversationClearTransaction(baselinePrivacyMarkerToken: nil)
                    ]
                }
                return initialState
            }
        }

        static func epoch(from value: Any?) -> UUID? {
            guard let value = value as? String else { return nil }
            return UUID(uuidString: value)
        }

        static func generation(from value: Any?) -> UInt64? {
            (value as? NSNumber)?.uint64Value
        }

        private static func legacyState() -> WatchConversationSyncState {
            let epoch = UserDefaults.standard.string(forKey: epochKey).flatMap(UUID.init(uuidString:))
            let generation = (UserDefaults.standard.object(forKey: generationKey) as? NSNumber)?
                .uint64Value ?? 0
            let pendingClearCount = max(
                0,
                UserDefaults.standard.integer(forKey: pendingClearCountKey)
            )
            let pendingClears = (0 ..< pendingClearCount).map { _ in
                WatchConversationClearTransaction(baselinePrivacyMarkerToken: nil)
            }
            return WatchConversationSyncState(
                identity: WatchConversationSyncIdentity(epoch: epoch, generation: generation),
                pendingClears: pendingClears
            )
        }

        private static func removeLegacyState() {
            UserDefaults.standard.removeObject(forKey: epochKey)
            UserDefaults.standard.removeObject(forKey: generationKey)
            UserDefaults.standard.removeObject(forKey: pendingClearCountKey)
        }
    }

    // MARK: - iOS Side (Companion App)

    #if os(iOS)

        /// WatchConnectivity service for the iOS companion app
        /// Manages syncing conversations to Apple Watch and receiving new messages from Watch
        @MainActor
        final class WatchConnectivityService: NSObject, ObservableObject {
            static let shared = WatchConnectivityService()

            @Published private(set) var isWatchAppInstalled = false
            @Published private(set) var isReachable = false
            @Published private(set) var lastSyncDate: Date?

            private var session: WCSession?
            private var conversationManager: ConversationManager?
            private var cancellables = Set<AnyCancellable>()
            private var syncGeneration = 0
            private let syncStateStore: WatchConversationSyncStateStore
            private nonisolated let mutationInbox: WatchConversationMutationInbox
            private var conversationSyncState: WatchConversationSyncState
            private var conversationHistoryIsLoaded = false
            private var mutationReplayTask: Task<Void, Never>?

            private var conversationSyncEpoch: UUID {
                guard let epoch = conversationSyncState.identity.epoch else {
                    preconditionFailure("The iPhone Watch synchronization epoch must be initialized")
                }
                return epoch
            }

            private var conversationClearGeneration: UInt64 {
                conversationSyncState.identity.generation
            }

            private var pendingConversationClearCount: Int {
                conversationSyncState.pendingClearCount
            }

            override private init() {
                syncStateStore = WatchSyncPersistence.stateStore
                mutationInbox = WatchSyncPersistence.mutationInbox
                conversationSyncState = WatchSyncPersistence.loadState(creatingPhoneEpoch: true)
                super.init()
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

                session = WCSession.default
                session?.delegate = self
                session?.activate()

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 iOS WatchConnectivity session activating"
                )
            }

            /// Configure with ConversationManager to observe changes
            func configure(with conversationManager: ConversationManager) {
                self.conversationManager = conversationManager
                conversationHistoryIsLoaded = false
                cancellables.removeAll()
                recoverInterruptedConversationClearIfNeeded(using: conversationManager)

                conversationManager.$conversations
                    .debounce(for: .seconds(1), scheduler: RunLoop.main)
                    .sink { [weak self] conversations in
                        self?.syncConversationsToWatch(conversations)
                    }
                    .store(in: &cancellables)

                NotificationCenter.default.publisher(
                    for: .conversationHistoryClearStarted,
                    object: conversationManager
                )
                .sink { [weak self] notification in
                    guard let transaction = WatchConversationClearTransaction(
                        notification: notification
                    ) else {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "Conversation clear started without a transaction identity"
                        )
                        return
                    }
                    self?.beginConversationClearFence(transaction)
                }
                .store(in: &cancellables)

                NotificationCenter.default.publisher(
                    for: .conversationHistoryClearCommitted,
                    object: conversationManager
                )
                .sink { [weak self] notification in
                    guard let transaction = WatchConversationClearTransaction(
                        notification: notification
                    ) else {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "Conversation clear committed without a transaction identity"
                        )
                        return
                    }
                    self?.publishCommittedConversationClear(transaction)
                }
                .store(in: &cancellables)

                NotificationCenter.default.publisher(
                    for: .conversationHistoryClearRolledBack,
                    object: conversationManager
                )
                .sink { [weak self] notification in
                    guard let transaction = WatchConversationClearTransaction(
                        notification: notification
                    ) else {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "Conversation clear rolled back without a transaction identity"
                        )
                        return
                    }
                    self?.publishRolledBackConversationClear(transaction)
                }
                .store(in: &cancellables)
            }

            func markConversationHistoryLoaded() {
                conversationHistoryIsLoaded = true
                replayPendingConversationMutationsIfPossible()
                if let conversations = conversationManager?.conversations {
                    syncConversationsToWatch(conversations)
                }
            }

            private func beginConversationClearFence(
                _ transaction: WatchConversationClearTransaction
            ) {
                syncGeneration &+= 1
                updateConversationSyncState { state in
                    state.beginClear(transaction)
                }
            }

            private func publishCommittedConversationClear(
                _ transaction: WatchConversationClearTransaction
            ) {
                let stateWasPersisted = updateConversationSyncState { state in
                    state.commitClear(id: transaction.id)
                }
                if stateWasPersisted {
                    conversationManager?.acknowledgeWatchConversationClear(transaction)
                }
                replayPendingConversationMutationsIfPossible()
                syncConversationsToWatch(conversationManager?.conversations ?? [])
            }

            private func publishRolledBackConversationClear(
                _ transaction: WatchConversationClearTransaction
            ) {
                let stateWasPersisted = updateConversationSyncState { state in
                    state.rollBackClear(id: transaction.id)
                }
                if stateWasPersisted {
                    conversationManager?.acknowledgeWatchConversationClear(transaction)
                }
                guard pendingConversationClearCount == 0,
                      let conversations = conversationManager?.conversations
                else {
                    return
                }
                replayPendingConversationMutationsIfPossible()
                syncConversationsToWatch(conversations)
            }

            private func recoverInterruptedConversationClearIfNeeded(
                using conversationManager: ConversationManager
            ) {
                let pendingTransactions = conversationSyncState.pendingClears
                guard !pendingTransactions.isEmpty else { return }
                do {
                    var committedTransactionIds = Set<UUID>()
                    for transaction in pendingTransactions {
                        if try conversationManager.interruptedConversationClearWasCommitted(
                            transaction
                        ) {
                            committedTransactionIds.insert(transaction.id)
                        }
                    }

                    let stateWasPersisted = updateConversationSyncState { state in
                        for transaction in pendingTransactions {
                            if committedTransactionIds.contains(transaction.id) {
                                state.commitClear(id: transaction.id)
                            } else {
                                state.rollBackClear(id: transaction.id)
                            }
                        }
                    }
                    if stateWasPersisted {
                        for transaction in pendingTransactions {
                            conversationManager.acknowledgeWatchConversationClear(transaction)
                        }
                    }

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "Recovered interrupted Watch conversation clears",
                        metadata: [
                            "committed": String(committedTransactionIds.count),
                            "rolledBack": String(
                                pendingTransactions.count - committedTransactionIds.count
                            ),
                        ]
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Could not resolve interrupted clear outcome; keeping Watch fence active",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            @discardableResult
            private func updateConversationSyncState(
                _ mutation: (inout WatchConversationSyncState) -> Void
            ) -> Bool {
                do {
                    conversationSyncState = try syncStateStore.update(
                        initialState: conversationSyncState,
                        mutation
                    )
                    return true
                } catch {
                    mutation(&conversationSyncState)
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Failed to persist Watch synchronization state",
                        metadata: ["error": error.localizedDescription]
                    )
                    return false
                }
            }

            /// Sync conversations to Watch via application context
            func syncConversationsToWatch(_ conversations: [Conversation]) {
                guard conversationHistoryIsLoaded, pendingConversationClearCount == 0 else { return }
                let syncEpoch = conversationSyncEpoch
                let clearGeneration = conversationClearGeneration

                guard let session, session.isPaired, session.isWatchAppInstalled else {
                    return
                }

                // Only sync the 10 most recent conversations
                let recentConversations = Array(conversations.prefix(10))
                syncGeneration += 1
                let generation = syncGeneration
                Task { @MainActor [weak self] in
                    guard let self, self.syncGeneration == generation else { return }
                    var conversationsForSync: [Conversation] = []
                    conversationsForSync.reserveCapacity(recentConversations.count)

                    for conversation in recentConversations {
                        guard self.syncGeneration == generation else { return }

                        if self.conversationManager?.isMetadataOnlyConversation(conversation.id) == true {
                            guard let hydrated = await self.conversationManager?.ensureConversationLoaded(conversation.id) else {
                                DiagnosticsLogger.log(
                                    .watchConnectivity,
                                    level: .error,
                                    message: "Skipping conversation in Watch sync because hydration failed",
                                    metadata: ["conversationId": conversation.id.uuidString]
                                )
                                continue
                            }
                            guard self.syncGeneration == generation else { return }
                            conversationsForSync.append(hydrated)
                        } else {
                            conversationsForSync.append(conversation)
                        }
                    }

                    guard self.syncGeneration == generation else { return }
                    self.sendWatchConversations(
                        conversationsForSync,
                        syncEpoch: syncEpoch,
                        clearGeneration: clearGeneration,
                        using: session
                    )
                }
            }

            private func sendWatchConversations(
                _ conversations: [Conversation],
                syncEpoch: UUID,
                clearGeneration: UInt64,
                using session: WCSession
            ) {
                let watchConversations = conversations.map { WatchConversation(from: $0) }

                do {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(watchConversations)

                    // Warn if payload is large (WCSession limit is ~65KB for applicationContext)
                    if data.count > 50000 {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .default,
                            message: "⚠️ Watch sync payload large",
                            metadata: ["bytes": "\(data.count)"]
                        )
                    }

                    // Get all model configuration for Watch
                    let availableModels = AIService.shared.usableModels
                    let selectedModel = AIService.shared.selectedModel
                    let customModels = AIService.shared.customModels
                    let defaultProvider = AIService.shared.provider.rawValue
                    let modelProviders = AIService.shared.modelProviders.mapValues { $0.rawValue }
                    let modelEndpoints = AIService.shared.modelEndpoints
                    let modelEndpointTypes = AIService.shared.modelEndpointTypes.mapValues { $0.rawValue }
                    let modelUsesGitHubOAuth = AIService.shared.modelUsesGitHubOAuth

                    // SECURITY: API keys are persisted in WCSession applicationContext on watch.
                    // Consider migrating to sendMessage + Keychain.
                    let modelAPIKeys = AIService.shared.modelAPIKeys

                    // GitHub OAuth token for GitHub Models
                    let githubAccessToken = GitHubOAuthService.shared.getAccessToken() ?? ""

                    // Tavily web search settings
                    let tavilyAPIKey = TavilyService.shared.apiKey
                    let tavilyEnabled = TavilyService.shared.isEnabled

                    var context: [String: Any] = [
                        WatchContextKeys.conversations: data,
                        WatchContextKeys.selectedModel: selectedModel,
                        WatchContextKeys.availableModels: availableModels,
                        WatchContextKeys.customModels: customModels,
                        WatchContextKeys.defaultProvider: defaultProvider,
                        WatchContextKeys.modelProviders: modelProviders,
                        WatchContextKeys.modelEndpoints: modelEndpoints,
                        WatchContextKeys.modelEndpointTypes: modelEndpointTypes,
                        WatchContextKeys.modelUsesGitHubOAuth: modelUsesGitHubOAuth,
                        WatchContextKeys.conversationSyncEpoch: syncEpoch.uuidString,
                        WatchContextKeys.conversationClearGeneration: NSNumber(value: clearGeneration),
                        WatchContextKeys.lastSyncDate: Date().timeIntervalSince1970
                    ]

                    // Only send API keys/tokens if they exist (don't overwrite with empty)
                    if !modelAPIKeys.isEmpty {
                        context[WatchContextKeys.modelAPIKeys] = modelAPIKeys
                    }
                    if !githubAccessToken.isEmpty {
                        context[WatchContextKeys.githubAccessToken] = githubAccessToken
                    }

                    // Tavily settings (always send to keep watch in sync)
                    context[WatchContextKeys.tavilyAPIKey] = tavilyAPIKey
                    context[WatchContextKeys.tavilyEnabled] = tavilyEnabled

                    // Web fetch settings (always enabled on iOS, sync to watch)
                    context[WatchContextKeys.webFetchEnabled] = WebFetchService.shared.isEnabled

                    // Memory settings (sync facts if enabled)
                    let memoryEnabled = MemoryContextProvider.shared.isMemoryEnabled
                    context[WatchContextKeys.memoryEnabled] = memoryEnabled
                    if memoryEnabled {
                        let facts = UserMemoryService.shared.activeFacts()
                        if !facts.isEmpty, let factsData = try? JSONEncoder().encode(facts) {
                            // Only include facts if we have room (leave headroom for other context)
                            if factsData.count < 15000 {
                                context[WatchContextKeys.memoryFacts] = factsData
                            } else {
                                DiagnosticsLogger.log(
                                    .watchConnectivity,
                                    level: .default,
                                    message: "⚠️ Skipping memory facts sync - data too large",
                                    metadata: ["size": "\(factsData.count)", "factCount": "\(facts.count)"]
                                )
                            }
                        }
                    }

                    try session.updateApplicationContext(context)
                    lastSyncDate = Date()

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱→⌚ Synced \(watchConversations.count) conversations to Watch",
                        metadata: ["count": "\(watchConversations.count)"]
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

            /// Handle new message from Watch
            private func handleNewMessage(
                from watchMessage: WatchMessage,
                conversationId: UUID
            ) async -> Bool {
                guard let conversationManager else { return false }

                // Find the conversation or create it if it doesn't exist
                if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                    if conversation.messages.contains(where: { $0.id == watchMessage.id }) {
                        return await conversationManager
                            .saveImmediatelyReportingDurability(conversation).value
                    }
                    let message = watchMessage.toMessage()
                    conversationManager.addMessage(to: conversation, message: message)

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 Received message from Watch",
                        metadata: ["conversationId": conversationId.uuidString]
                    )
                } else {
                    // Conversation doesn't exist, create it
                    let model = AIService.shared.selectedModel
                    let newConversation = Conversation(
                        id: conversationId,
                        title: "Watch Chat",
                        createdAt: Date(),
                        model: model
                    )
                    conversationManager.insertConversationFromSync(newConversation, allowsRecreation: true)

                    // Now add the message
                    let message = watchMessage.toMessage()
                    conversationManager.addMessage(to: newConversation, message: message)

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 Created new conversation from Watch",
                        metadata: ["conversationId": conversationId.uuidString]
                    )
                }
                guard let updatedConversation = conversationManager.conversations.first(where: {
                    $0.id == conversationId
                }) else {
                    return false
                }
                return await conversationManager
                    .saveImmediatelyReportingDurability(updatedConversation).value
            }

            /// Handle new conversation created on Watch
            private func handleNewConversation(
                _ watchConversation: WatchConversation
            ) async -> Bool {
                guard let conversationManager else { return false }

                // Check if conversation already exists
                if conversationManager.conversations.contains(where: { $0.id == watchConversation.id }) {
                    let existingConversation = conversationManager.conversations.first(where: {
                        $0.id == watchConversation.id
                    })
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .debug,
                        message: "📱 Conversation already exists",
                        metadata: ["conversationId": watchConversation.id.uuidString]
                    )
                    if let existingConversation {
                        return await conversationManager
                            .saveImmediatelyReportingDurability(existingConversation).value
                    }
                    return false
                }

                // Create the conversation on iPhone
                let conversation = watchConversation.toConversation()
                conversationManager.insertConversationFromSync(conversation, allowsRecreation: true)

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 Created conversation from Watch",
                    metadata: ["conversationId": watchConversation.id.uuidString, "title": watchConversation.title]
                )
                return await conversationManager
                    .saveImmediatelyReportingDurability(conversation).value
            }

            /// Handle title update from Watch
            private func handleTitleUpdate(
                conversationId: UUID,
                newTitle: String
            ) async -> Bool {
                guard let conversationManager else { return false }

                if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) {
                    if conversationManager.conversations[index].title == newTitle {
                        return await conversationManager.saveImmediatelyReportingDurability(
                            conversationManager.conversations[index]
                        ).value
                    }
                    conversationManager.conversations[index].title = newTitle
                    let updatedConversation = conversationManager.conversations[index]

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 Updated conversation title from Watch",
                        metadata: ["conversationId": conversationId.uuidString, "title": newTitle]
                    )
                    return await conversationManager
                        .saveImmediatelyReportingDurability(updatedConversation).value
                }
                return true
            }
        }

        extension WatchConnectivityService: WCSessionDelegate {
            nonisolated func session(
                _ session: WCSession,
                activationDidCompleteWith activationState: WCSessionActivationState,
                error: Error?
            ) {
                let watchAppInstalled = session.isWatchAppInstalled
                let reachable = session.isReachable
                let stateRawValue = activationState.rawValue
                let errorDescription = error?.localizedDescription
                Task { @MainActor in
                    if let errorDescription {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ iOS session activation failed",
                            metadata: ["error": errorDescription]
                        )
                        return
                    }

                    isWatchAppInstalled = watchAppInstalled
                    isReachable = reachable

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 iOS session activated",
                        metadata: [
                            "state": "\(stateRawValue)",
                            "watchAppInstalled": "\(watchAppInstalled)",
                            "reachable": "\(reachable)"
                        ]
                    )

                    // Trigger initial sync if Watch is available
                    if watchAppInstalled, let conversations = conversationManager?.conversations {
                        syncConversationsToWatch(conversations)
                    }
                }
            }

            nonisolated func sessionDidBecomeInactive(_: WCSession) {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 iOS session became inactive"
                )
            }

            nonisolated func sessionDidDeactivate(_ session: WCSession) {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 iOS session deactivated"
                )
                // Reactivate session for switching between Watches
                session.activate()
            }

            nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
                let watchAppInstalled = session.isWatchAppInstalled
                let reachable = session.isReachable
                Task { @MainActor in
                    isWatchAppInstalled = watchAppInstalled
                    isReachable = reachable

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 Watch state changed",
                        metadata: [
                            "watchAppInstalled": "\(watchAppInstalled)",
                            "reachable": "\(reachable)"
                        ]
                    )
                }
            }

            nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
                let reachable = session.isReachable
                Task { @MainActor in
                    isReachable = reachable

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 Watch reachability changed",
                        metadata: ["reachable": "\(reachable)"]
                    )
                }
            }

            nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any]) {
                nonisolated(unsafe) let message = message
                switch persistConversationMutationIfPresent(message) {
                case .persisted:
                    Task { @MainActor in
                        replayPendingConversationMutationsIfPossible()
                    }
                case .notMutation:
                    Task { @MainActor in
                        handleNonMutationMessage(message)
                    }
                case .failed:
                    break
                }
            }

            nonisolated func session(
                _: WCSession,
                didReceiveMessage message: [String: Any],
                replyHandler: @escaping ([String: Any]) -> Void
            ) {
                nonisolated(unsafe) let message = message
                nonisolated(unsafe) let replyHandler = replyHandler
                switch persistConversationMutationIfPresent(message) {
                case .persisted:
                    replyHandler(["status": "persisted"])
                    Task { @MainActor in
                        replayPendingConversationMutationsIfPossible()
                    }
                case .notMutation:
                    Task { @MainActor in
                        handleNonMutationMessage(message)
                        replyHandler(["status": "received"])
                    }
                case .failed:
                    replyHandler(["status": "persistenceFailed"])
                }
            }

            nonisolated func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
                nonisolated(unsafe) let userInfo = userInfo
                switch persistConversationMutationIfPresent(userInfo) {
                case .persisted:
                    Task { @MainActor in
                        replayPendingConversationMutationsIfPossible()
                    }
                case .notMutation:
                    Task { @MainActor in
                        handleNonMutationMessage(userInfo)
                    }
                case .failed:
                    break
                }
            }

            private enum IncomingMutationPersistenceResult {
                case notMutation
                case persisted
                case failed
            }

            private enum IncomingMutationError: LocalizedError {
                case invalidPayload(String)

                var errorDescription: String? {
                    switch self {
                    case let .invalidPayload(type):
                        "Invalid Watch conversation mutation payload for type \(type)."
                    }
                }
            }

            private nonisolated func persistConversationMutationIfPresent(
                _ message: [String: Any]
            ) -> IncomingMutationPersistenceResult {
                do {
                    guard let mutation = try conversationMutation(from: message) else {
                        return .notMutation
                    }
                    try mutationInbox.enqueue(mutation)
                    return .persisted
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Failed to durably queue Watch conversation mutation",
                        metadata: ["error": error.localizedDescription]
                    )
                    return .failed
                }
            }

            private nonisolated func conversationMutation(
                from message: [String: Any]
            ) throws -> WatchConversationMutation? {
                guard let type = message[WatchMessageKeys.type] as? String else { return nil }
                let explicitMutationId = (message[WatchMessageKeys.mutationId] as? String)
                    .flatMap(UUID.init(uuidString:))
                let incomingEpoch = WatchSyncPersistence.epoch(
                    from: message[WatchMessageKeys.conversationSyncEpoch]
                )
                let incomingGeneration = WatchSyncPersistence.generation(
                    from: message[WatchMessageKeys.conversationClearGeneration]
                )

                switch type {
                case WatchMessageKeys.typeNewMessage:
                    guard let messageData = message[WatchMessageKeys.newMessage] as? Data,
                          let conversationIdString = message[WatchMessageKeys.conversationId] as? String,
                          let conversationId = UUID(uuidString: conversationIdString)
                    else {
                        throw IncomingMutationError.invalidPayload(type)
                    }
                    let watchMessage = try JSONDecoder().decode(WatchMessage.self, from: messageData)
                    return WatchConversationMutation(
                        id: explicitMutationId ?? watchMessage.id,
                        syncEpoch: incomingEpoch,
                        clearGeneration: incomingGeneration,
                        payload: .newMessage(
                            message: watchMessage,
                            conversationId: conversationId
                        )
                    )

                case WatchMessageKeys.typeNewConversation:
                    guard let conversationData = message[WatchMessageKeys.conversation] as? Data else {
                        throw IncomingMutationError.invalidPayload(type)
                    }
                    let conversation = try JSONDecoder().decode(
                        WatchConversation.self,
                        from: conversationData
                    )
                    return WatchConversationMutation(
                        id: explicitMutationId ?? conversation.id,
                        syncEpoch: incomingEpoch,
                        clearGeneration: incomingGeneration,
                        payload: .newConversation(conversation)
                    )

                case WatchMessageKeys.typeTitleUpdate:
                    guard let conversationIdString = message[WatchMessageKeys.conversationId] as? String,
                          let conversationId = UUID(uuidString: conversationIdString),
                          let title = message[WatchMessageKeys.title] as? String
                    else {
                        throw IncomingMutationError.invalidPayload(type)
                    }
                    return WatchConversationMutation(
                        id: explicitMutationId ?? UUID(),
                        syncEpoch: incomingEpoch,
                        clearGeneration: incomingGeneration,
                        payload: .titleUpdate(conversationId: conversationId, title: title)
                    )

                default:
                    return nil
                }
            }

            private func acceptsConversationMutation(
                _ mutation: WatchConversationMutation
            ) -> Bool {
                guard WatchConversationSyncFence.acceptsMutation(
                    incomingEpoch: mutation.syncEpoch,
                    incomingGeneration: mutation.clearGeneration,
                    currentEpoch: conversationSyncEpoch,
                    currentGeneration: conversationClearGeneration,
                    pendingClearCount: pendingConversationClearCount
                ) else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "Ignoring fenced or stale Watch conversation mutation",
                        metadata: [
                            "incomingEpoch": mutation.syncEpoch?.uuidString ?? "legacy",
                            "currentEpoch": conversationSyncEpoch.uuidString,
                            "incomingGeneration": mutation.clearGeneration.map(String.init) ?? "legacy",
                            "currentGeneration": String(conversationClearGeneration),
                            "pendingClears": String(pendingConversationClearCount),
                        ]
                    )
                    return false
                }
                return true
            }

            private func handleNonMutationMessage(_ message: [String: Any]) {
                guard let type = message[WatchMessageKeys.type] as? String else { return }
                switch type {
                case WatchMessageKeys.typeRequestSync:
                    // Watch requested a sync
                    if let conversations = conversationManager?.conversations {
                        syncConversationsToWatch(conversations)
                    }

                default:
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "📱 Unknown message type from Watch",
                        metadata: ["type": type]
                    )
                }
            }

            private func replayPendingConversationMutationsIfPossible() {
                guard conversationHistoryIsLoaded,
                      pendingConversationClearCount == 0,
                      mutationReplayTask == nil
                else {
                    return
                }

                mutationReplayTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let completedReplay = await self.replayPendingConversationMutations()
                    self.mutationReplayTask = nil
                    guard completedReplay,
                          self.conversationHistoryIsLoaded,
                          self.pendingConversationClearCount == 0,
                          let remainingMutations = try? self.mutationInbox.load(),
                          !remainingMutations.isEmpty
                    else {
                        return
                    }
                    self.replayPendingConversationMutationsIfPossible()
                }
            }

            private func replayPendingConversationMutations() async -> Bool {
                let mutations: [WatchConversationMutation]
                do {
                    mutations = try mutationInbox.load()
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Failed to load queued Watch conversation mutations",
                        metadata: ["error": error.localizedDescription]
                    )
                    return false
                }

                for mutation in mutations {
                    guard conversationHistoryIsLoaded, pendingConversationClearCount == 0 else {
                        return false
                    }

                    if acceptsConversationMutation(mutation) {
                        guard await applyConversationMutation(mutation) else { return false }
                        guard conversationHistoryIsLoaded,
                              pendingConversationClearCount == 0,
                              mutation.clearGeneration == nil
                              || mutation.clearGeneration == conversationClearGeneration
                        else {
                            return false
                        }
                    }

                    do {
                        try mutationInbox.remove(id: mutation.id)
                    } catch {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "Failed to acknowledge queued Watch conversation mutation",
                            metadata: [
                                "mutationId": mutation.id.uuidString,
                                "error": error.localizedDescription,
                            ]
                        )
                        return false
                    }
                }
                return true
            }

            private func applyConversationMutation(
                _ mutation: WatchConversationMutation
            ) async -> Bool {
                switch mutation.payload {
                case let .newMessage(message, conversationId):
                    await handleNewMessage(from: message, conversationId: conversationId)
                case let .newConversation(conversation):
                    await handleNewConversation(conversation)
                case let .titleUpdate(conversationId, title):
                    await handleTitleUpdate(conversationId: conversationId, newTitle: title)
                }
            }
        }

    #endif

    // MARK: - watchOS Side

    #if os(watchOS)

        /// WatchConnectivity service for the Watch app
        /// Receives conversations from iPhone and sends new messages back
        @MainActor
        final class WatchConnectivityService: NSObject, ObservableObject {
            static let shared = WatchConnectivityService()

            @Published private(set) var isReachable = false
            @Published private(set) var lastSyncDate: Date?
            @Published var selectedModel: String = ""
            @Published var availableModels: [String] = []

            private var session: WCSession?
            private var conversationStore: WatchConversationStore?
            private let syncStateStore: WatchConversationSyncStateStore
            private var conversationSyncState: WatchConversationSyncState

            private var conversationSyncEpoch: UUID? {
                conversationSyncState.identity.epoch
            }

            private var conversationClearGeneration: UInt64 {
                conversationSyncState.identity.generation
            }

            var currentConversationSyncIdentity: WatchConversationSyncIdentity {
                WatchConversationSyncIdentity(
                    epoch: conversationSyncEpoch,
                    generation: conversationClearGeneration
                )
            }

            var isConversationSyncReady: Bool {
                WatchConversationSyncFence.canInitiateMutation(currentEpoch: conversationSyncEpoch)
            }

            func matchesConversationSyncIdentity(_ identity: WatchConversationSyncIdentity) -> Bool {
                currentConversationSyncIdentity == identity
            }

            override private init() {
                syncStateStore = WatchSyncPersistence.stateStore
                conversationSyncState = WatchSyncPersistence.loadState(creatingPhoneEpoch: false)
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

                session = WCSession.default
                session?.delegate = self
                session?.activate()

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Watch WatchConnectivity session activating"
                )
            }

            /// Configure with WatchConversationStore
            func configure(with store: WatchConversationStore) {
                conversationStore = store
            }

            private func appendConversationSyncIdentity(
                to message: inout [String: Any]
            ) -> Bool {
                guard let conversationSyncEpoch else { return false }
                message[WatchMessageKeys.conversationSyncEpoch] = conversationSyncEpoch.uuidString
                message[WatchMessageKeys.conversationClearGeneration] = NSNumber(
                    value: conversationClearGeneration
                )
                return true
            }

            /// Request sync from iPhone
            func requestSync() {
                guard let session, session.isReachable else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ iPhone not reachable for sync request"
                    )
                    return
                }

                let message: [String: Any] = [
                    WatchMessageKeys.type: WatchMessageKeys.typeRequestSync
                ]

                session.sendMessage(message, replyHandler: nil) { error in
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to request sync",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            /// Send a new message to iPhone
            func sendMessage(
                _ watchMessage: WatchMessage,
                conversationId: UUID,
                expectedIdentity: WatchConversationSyncIdentity? = nil
            ) {
                guard let session else { return }
                if let expectedIdentity,
                   !matchesConversationSyncIdentity(expectedIdentity)
                {
                    return
                }

                do {
                    let messageData = try JSONEncoder().encode(watchMessage)
                    var message: [String: Any] = [
                        WatchMessageKeys.type: WatchMessageKeys.typeNewMessage,
                        WatchMessageKeys.mutationId: UUID().uuidString,
                        WatchMessageKeys.newMessage: messageData,
                        WatchMessageKeys.conversationId: conversationId.uuidString,
                    ]
                    guard appendConversationSyncIdentity(to: &message) else {
                        requestSync()
                        return
                    }

                    if session.isReachable {
                        session.sendMessage(message, replyHandler: nil) { error in
                            DiagnosticsLogger.log(
                                .watchConnectivity,
                                level: .error,
                                message: "❌ Failed to send message to iPhone",
                                metadata: ["error": error.localizedDescription]
                            )
                        }
                    } else {
                        // Use transferUserInfo for reliable delivery when not reachable
                        session.transferUserInfo(message)
                    }

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚→📱 Sent message to iPhone",
                        metadata: ["conversationId": conversationId.uuidString]
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to encode message for iPhone",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            /// Send a new conversation to iPhone
            func sendConversation(_ conversation: WatchConversation) {
                guard let session else { return }

                do {
                    let conversationData = try JSONEncoder().encode(conversation)
                    var message: [String: Any] = [
                        WatchMessageKeys.type: WatchMessageKeys.typeNewConversation,
                        WatchMessageKeys.mutationId: UUID().uuidString,
                        WatchMessageKeys.conversation: conversationData,
                    ]
                    guard appendConversationSyncIdentity(to: &message) else {
                        requestSync()
                        return
                    }

                    if session.isReachable {
                        session.sendMessage(message, replyHandler: nil) { error in
                            DiagnosticsLogger.log(
                                .watchConnectivity,
                                level: .error,
                                message: "❌ Failed to send conversation to iPhone",
                                metadata: ["error": error.localizedDescription]
                            )
                        }
                    } else {
                        // Use transferUserInfo for reliable delivery when not reachable
                        session.transferUserInfo(message)
                    }

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚→📱 Sent conversation to iPhone",
                        metadata: ["conversationId": conversation.id.uuidString]
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to encode conversation for iPhone",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            /// Send a title update to iPhone
            func sendTitleUpdate(conversationId: UUID, newTitle: String) {
                guard let session else { return }

                var message: [String: Any] = [
                    WatchMessageKeys.type: WatchMessageKeys.typeTitleUpdate,
                    WatchMessageKeys.mutationId: UUID().uuidString,
                    WatchMessageKeys.conversationId: conversationId.uuidString,
                    WatchMessageKeys.title: newTitle,
                ]
                guard appendConversationSyncIdentity(to: &message) else {
                    requestSync()
                    return
                }

                if session.isReachable {
                    session.sendMessage(message, replyHandler: nil) { error in
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Failed to send title update to iPhone",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                } else {
                    // Use transferUserInfo for reliable delivery when not reachable
                    session.transferUserInfo(message)
                }

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚→📱 Sent title update to iPhone",
                    metadata: ["conversationId": conversationId.uuidString, "title": newTitle]
                )
            }

            /// Process received application context from iPhone
            private func processContext(_ context: [String: Any]) {
                processConversationsFromContext(context)
                processModelSettingsFromContext(context)
                processAPIKeysFromContext(context)
                processTavilySettingsFromContext(context)
                processWebFetchSettingsFromContext(context)
                processMemoryFromContext(context)

                if let syncTimestamp = context[WatchContextKeys.lastSyncDate] as? TimeInterval {
                    lastSyncDate = Date(timeIntervalSince1970: syncTimestamp)
                }
            }

            /// Process conversations data from iPhone context
            private func processConversationsFromContext(_ context: [String: Any]) {
                let incomingEpoch = WatchSyncPersistence.epoch(
                    from: context[WatchContextKeys.conversationSyncEpoch]
                )
                let incomingGeneration = WatchSyncPersistence.generation(
                    from: context[WatchContextKeys.conversationClearGeneration]
                )
                guard WatchConversationSyncFence.acceptsContext(
                    incomingEpoch: incomingEpoch,
                    incomingGeneration: incomingGeneration,
                    currentEpoch: conversationSyncEpoch,
                    currentGeneration: conversationClearGeneration
                ) else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "Ignoring stale iPhone conversation context"
                    )
                    return
                }
                let discardsLocalOnlyConversations: Bool = if let incomingEpoch, let incomingGeneration {
                    WatchConversationSyncFence
                        .contextRequiresAuthoritativeReset(
                            incomingEpoch: incomingEpoch,
                            incomingGeneration: incomingGeneration,
                            currentEpoch: conversationSyncEpoch,
                            currentGeneration: conversationClearGeneration
                        )
                } else {
                    false
                }

                guard let conversationsData = context[WatchContextKeys.conversations] as? Data else { return }
                do {
                    let watchConversations = try JSONDecoder().decode(
                        [WatchConversation].self,
                        from: conversationsData
                    )
                    guard let conversationStore else { return }
                    if discardsLocalOnlyConversations {
                        AIService.shared.cancelCurrentRequest()
                    }
                    conversationStore.updateConversations(
                        watchConversations,
                        discardingLocalOnlyConversations: discardsLocalOnlyConversations
                    )
                    if let incomingEpoch, let incomingGeneration {
                        updateConversationSyncIdentity(
                            WatchConversationSyncIdentity(
                                epoch: incomingEpoch,
                                generation: incomingGeneration
                            )
                        )
                    }

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Received \(watchConversations.count) conversations from iPhone"
                    )
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to decode conversations from iPhone",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            private func updateConversationSyncIdentity(
                _ identity: WatchConversationSyncIdentity
            ) {
                do {
                    conversationSyncState = try syncStateStore.update(
                        initialState: conversationSyncState
                    ) { state in
                        state.identity = identity
                    }
                } catch {
                    conversationSyncState.identity = identity
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "Failed to persist Watch synchronization identity",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            /// Process model settings from iPhone context
            private func processModelSettingsFromContext(_ context: [String: Any]) {
                if let model = context[WatchContextKeys.selectedModel] as? String {
                    selectedModel = model
                    AIService.shared.selectedModel = model
                }

                if let models = context[WatchContextKeys.availableModels] as? [String] {
                    availableModels = models
                }

                if let customModels = context[WatchContextKeys.customModels] as? [String] {
                    AIService.shared.customModels = customModels
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated custom models from iPhone",
                        metadata: ["count": "\(customModels.count)"]
                    )
                }

                if let providerRaw = context[WatchContextKeys.defaultProvider] as? String,
                   let provider = AIProvider(rawValue: providerRaw)
                {
                    AIService.shared.provider = provider
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated default provider from iPhone",
                        metadata: ["provider": providerRaw]
                    )
                }

                processModelProviderMappings(context)
                processModelEndpointSettings(context)
            }

            /// Process model provider mappings from context
            private func processModelProviderMappings(_ context: [String: Any]) {
                if let providersDict = context[WatchContextKeys.modelProviders] as? [String: String] {
                    var modelProviders: [String: AIProvider] = [:]
                    for (model, providerRaw) in providersDict {
                        if let provider = AIProvider(rawValue: providerRaw) {
                            modelProviders[model] = provider
                        }
                    }
                    AIService.shared.modelProviders = modelProviders
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated model providers from iPhone",
                        metadata: ["count": "\(modelProviders.count)"]
                    )
                }

                if let modelUsesGitHubOAuth = context[WatchContextKeys.modelUsesGitHubOAuth] as? [String: Bool] {
                    AIService.shared.modelUsesGitHubOAuth = modelUsesGitHubOAuth
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated GitHub OAuth flags from iPhone",
                        metadata: ["count": "\(modelUsesGitHubOAuth.count)"]
                    )
                }
            }

            /// Process model endpoint settings from context
            private func processModelEndpointSettings(_ context: [String: Any]) {
                if let modelEndpoints = context[WatchContextKeys.modelEndpoints] as? [String: String] {
                    AIService.shared.modelEndpoints = modelEndpoints
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated model endpoints from iPhone",
                        metadata: ["count": "\(modelEndpoints.count)"]
                    )
                }

                if let endpointTypesDict = context[WatchContextKeys.modelEndpointTypes] as? [String: String] {
                    var modelEndpointTypes: [String: APIEndpointType] = [:]
                    for (model, typeRaw) in endpointTypesDict {
                        if let endpointType = APIEndpointType(rawValue: typeRaw) {
                            modelEndpointTypes[model] = endpointType
                        }
                    }
                    AIService.shared.modelEndpointTypes = modelEndpointTypes
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated model endpoint types from iPhone",
                        metadata: ["count": "\(modelEndpointTypes.count)"]
                    )
                }
            }

            /// Process API keys from iPhone context
            private func processAPIKeysFromContext(_ context: [String: Any]) {
                if let modelAPIKeys = context[WatchContextKeys.modelAPIKeys] as? [String: String], !modelAPIKeys.isEmpty {
                    AIService.shared.modelAPIKeys = modelAPIKeys
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Received model API keys from iPhone",
                        metadata: ["count": "\(modelAPIKeys.count)"]
                    )
                }

                if let githubToken = context[WatchContextKeys.githubAccessToken] as? String, !githubToken.isEmpty {
                    GitHubOAuthService.shared.setAccessTokenFromWatch(githubToken)
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Received GitHub access token from iPhone"
                    )
                }
            }

            /// Process Tavily web search settings from iPhone context
            private func processTavilySettingsFromContext(_ context: [String: Any]) {
                if let tavilyKey = context[WatchContextKeys.tavilyAPIKey] as? String {
                    if !tavilyKey.isEmpty {
                        AIService.shared.tavilyAPIKey = tavilyKey
                        TavilyService.shared.apiKey = tavilyKey
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .info,
                            message: "⌚ Received Tavily API key from iPhone"
                        )
                    } else {
                        AIService.shared.tavilyAPIKey = ""
                        TavilyService.shared.apiKey = ""
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .info,
                            message: "⌚ Cleared Tavily API key (removed on iPhone)"
                        )
                    }
                }
                if let tavilyEnabled = context[WatchContextKeys.tavilyEnabled] as? Bool {
                    AIService.shared.tavilyEnabled = tavilyEnabled
                    AIService.shared.webSearchEnabled = tavilyEnabled
                    TavilyService.shared.isEnabled = tavilyEnabled
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated web search settings from iPhone",
                        metadata: ["enabled": "\(tavilyEnabled)"]
                    )
                }
            }

            /// Process web fetch settings from iPhone context
            private func processWebFetchSettingsFromContext(_ context: [String: Any]) {
                if let webFetchEnabled = context[WatchContextKeys.webFetchEnabled] as? Bool {
                    WebFetchService.shared.isEnabled = webFetchEnabled
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated web fetch enabled state from iPhone",
                        metadata: ["enabled": "\(webFetchEnabled)"]
                    )
                }
            }

            /// Process memory settings from iPhone context
            private func processMemoryFromContext(_ context: [String: Any]) {
                if let memoryEnabled = context[WatchContextKeys.memoryEnabled] as? Bool {
                    MemoryContextProvider.shared.setMemoryEnabled(memoryEnabled)
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Updated memory enabled state from iPhone",
                        metadata: ["enabled": "\(memoryEnabled)"]
                    )

                    // Clear facts when memory is disabled on iPhone
                    if !memoryEnabled {
                        UserMemoryService.shared.loadFactsFromSync([])
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .info,
                            message: "⌚ Cleared memory facts (memory disabled on iPhone)"
                        )
                        return
                    }
                }

                // Decode and load facts
                if let factsData = context[WatchContextKeys.memoryFacts] as? Data {
                    do {
                        let facts = try JSONDecoder().decode([UserMemoryFact].self, from: factsData)
                        UserMemoryService.shared.loadFactsFromSync(facts)
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .info,
                            message: "⌚ Received memory facts from iPhone",
                            metadata: ["count": "\(facts.count)"]
                        )
                    } catch {
                        // Log and skip - keep existing facts on decode failure
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "⌚ Failed to decode memory facts from iPhone",
                            metadata: ["error": "\(error.localizedDescription)"]
                        )
                    }
                }
            }
        }

        extension WatchConnectivityService: WCSessionDelegate {
            nonisolated func session(
                _ session: WCSession,
                activationDidCompleteWith activationState: WCSessionActivationState,
                error: Error?
            ) {
                let reachable = session.isReachable
                let stateRawValue = activationState.rawValue
                let errorDescription = error?.localizedDescription
                let receivedContext = session.receivedApplicationContext
                nonisolated(unsafe) let receivedContextUnsafe = receivedContext
                Task { @MainActor in
                    if let errorDescription {
                        DiagnosticsLogger.log(
                            .watchConnectivity,
                            level: .error,
                            message: "❌ Watch session activation failed",
                            metadata: ["error": errorDescription]
                        )
                        return
                    }

                    isReachable = reachable

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ Watch session activated",
                        metadata: [
                            "state": "\(stateRawValue)",
                            "reachable": "\(reachable)"
                        ]
                    )

                    // Initialize conversation store from disk now that session is ready
                    conversationStore?.initializeFromDisk()

                    // Process any existing context
                    if !receivedContextUnsafe.isEmpty {
                        processContext(receivedContextUnsafe)
                    }
                }
            }

            nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
                let reachable = session.isReachable
                Task { @MainActor in
                    isReachable = reachable

                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .info,
                        message: "⌚ iPhone reachability changed",
                        metadata: ["reachable": "\(reachable)"]
                    )
                }
            }

            nonisolated func session(
                _: WCSession,
                didReceiveApplicationContext applicationContext: [String: Any]
            ) {
                nonisolated(unsafe) let applicationContext = applicationContext
                Task { @MainActor in
                    processContext(applicationContext)
                }
            }
        }

    #endif // os(watchOS)

#endif // os(iOS) || os(watchOS)
