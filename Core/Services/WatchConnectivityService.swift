//
//  WatchConnectivityService.swift
//  ayna
//
//  Created on 11/29/25.
//

import Combine
import Foundation
import os
import WatchConnectivity

/// Lightweight conversation model for Watch sync (strips heavy data like images and attachments)
struct WatchConversation: Codable, Identifiable {
    let id: UUID
    var title: String
    var messages: [WatchMessage]
    var model: String
    var updatedAt: Date
    var createdAt: Date

    init(from conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        model = conversation.model
        updatedAt = conversation.updatedAt
        createdAt = conversation.createdAt
        // Only include recent messages and strip attachments
        messages = conversation.messages.suffix(20).map { WatchMessage(from: $0) }
    }

    func toConversation() -> Conversation {
        var conversation = Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            model: model
        )
        conversation.updatedAt = updatedAt
        conversation.messages = messages.map { $0.toMessage() }
        return conversation
    }
}

/// Lightweight message model for Watch sync (no images or attachments)
struct WatchMessage: Codable, Identifiable {
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var model: String?

    init(from message: Message) {
        id = message.id
        role = message.role.rawValue
        content = message.content
        timestamp = message.timestamp
        model = message.model
    }

    func toMessage() -> Message {
        Message(
            id: id,
            role: Message.Role(rawValue: role) ?? .assistant,
            content: content,
            timestamp: timestamp,
            model: model
        )
    }
}

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
    static let apiKey = "apiKey"
    static let modelAPIKeys = "modelAPIKeys"
    static let githubAccessToken = "githubAccessToken"
    static let tavilyAPIKey = "tavilyAPIKey"
    static let tavilyEnabled = "tavilyEnabled"
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

        override private init() {
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

            // Observe conversation changes (skip empty lists to avoid resetting Watch)
            conversationManager.$conversations
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .filter { !$0.isEmpty } // Don't sync empty lists
                .sink { [weak self] conversations in
                    self?.syncConversationsToWatch(conversations)
                }
                .store(in: &cancellables)
        }

        /// Sync conversations to Watch via application context
        func syncConversationsToWatch(_ conversations: [Conversation]) {
            guard let session, session.isPaired, session.isWatchAppInstalled else {
                return
            }

            // Only sync the 10 most recent conversations
            let recentConversations = Array(conversations.prefix(10))
            let watchConversations = recentConversations.map { WatchConversation(from: $0) }

            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(watchConversations)

                // Get all model configuration for Watch
                let availableModels = OpenAIService.shared.usableModels
                let selectedModel = OpenAIService.shared.selectedModel
                let customModels = OpenAIService.shared.customModels
                let defaultProvider = OpenAIService.shared.provider.rawValue
                let modelProviders = OpenAIService.shared.modelProviders.mapValues { $0.rawValue }
                let modelEndpoints = OpenAIService.shared.modelEndpoints
                let modelEndpointTypes = OpenAIService.shared.modelEndpointTypes.mapValues { $0.rawValue }
                let modelUsesGitHubOAuth = OpenAIService.shared.modelUsesGitHubOAuth

                // API keys via WatchConnectivity (for free dev accounts without shared Keychain)
                let globalAPIKey = OpenAIService.shared.apiKey
                let modelAPIKeys = OpenAIService.shared.modelAPIKeys

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
                    WatchContextKeys.lastSyncDate: Date().timeIntervalSince1970
                ]

                // Only send API keys/tokens if they exist (don't overwrite with empty)
                if !globalAPIKey.isEmpty {
                    context[WatchContextKeys.apiKey] = globalAPIKey
                }
                if !modelAPIKeys.isEmpty {
                    context[WatchContextKeys.modelAPIKeys] = modelAPIKeys
                }
                if !githubAccessToken.isEmpty {
                    context[WatchContextKeys.githubAccessToken] = githubAccessToken
                }

                // Tavily settings (always send to keep watch in sync)
                if !tavilyAPIKey.isEmpty {
                    context[WatchContextKeys.tavilyAPIKey] = tavilyAPIKey
                }
                context[WatchContextKeys.tavilyEnabled] = tavilyEnabled

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
        private func handleNewMessage(from watchMessage: WatchMessage, conversationId: UUID) {
            guard let conversationManager else { return }

            // Find the conversation or create it if it doesn't exist
            if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
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
                let model = OpenAIService.shared.selectedModel
                let newConversation = Conversation(
                    id: conversationId,
                    title: "Watch Chat",
                    createdAt: Date(),
                    model: model
                )
                conversationManager.conversations.insert(newConversation, at: 0)

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
        }

        /// Handle new conversation created on Watch
        private func handleNewConversation(_ watchConversation: WatchConversation) {
            guard let conversationManager else { return }

            // Check if conversation already exists
            if conversationManager.conversations.contains(where: { $0.id == watchConversation.id }) {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .debug,
                    message: "📱 Conversation already exists",
                    metadata: ["conversationId": watchConversation.id.uuidString]
                )
                return
            }

            // Create the conversation on iPhone
            let conversation = watchConversation.toConversation()
            conversationManager.conversations.insert(conversation, at: 0)

            DiagnosticsLogger.log(
                .watchConnectivity,
                level: .info,
                message: "📱 Created conversation from Watch",
                metadata: ["conversationId": watchConversation.id.uuidString, "title": watchConversation.title]
            )
        }

        /// Handle title update from Watch
        private func handleTitleUpdate(conversationId: UUID, newTitle: String) {
            guard let conversationManager else { return }

            if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversationId }) {
                conversationManager.conversations[index].title = newTitle

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 Updated conversation title from Watch",
                    metadata: ["conversationId": conversationId.uuidString, "title": newTitle]
                )
            }
        }
    }

    extension WatchConnectivityService: WCSessionDelegate {
        nonisolated func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: Error?
        ) {
            Task { @MainActor in
                if let error {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ iOS session activation failed",
                        metadata: ["error": error.localizedDescription]
                    )
                    return
                }

                isWatchAppInstalled = session.isWatchAppInstalled
                isReachable = session.isReachable

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 iOS session activated",
                    metadata: [
                        "state": "\(activationState.rawValue)",
                        "watchAppInstalled": "\(session.isWatchAppInstalled)",
                        "reachable": "\(session.isReachable)"
                    ]
                )

                // Trigger initial sync if Watch is available
                if session.isWatchAppInstalled, let conversations = conversationManager?.conversations {
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
            Task { @MainActor in
                isWatchAppInstalled = session.isWatchAppInstalled
                isReachable = session.isReachable

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 Watch state changed",
                    metadata: [
                        "watchAppInstalled": "\(session.isWatchAppInstalled)",
                        "reachable": "\(session.isReachable)"
                    ]
                )
            }
        }

        nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
            Task { @MainActor in
                isReachable = session.isReachable

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 Watch reachability changed",
                    metadata: ["reachable": "\(session.isReachable)"]
                )
            }
        }

        nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any]) {
            Task { @MainActor in
                handleReceivedMessage(message)
            }
        }

        nonisolated func session(
            _: WCSession,
            didReceiveMessage message: [String: Any],
            replyHandler: @escaping ([String: Any]) -> Void
        ) {
            Task { @MainActor in
                handleReceivedMessage(message)
                replyHandler(["status": "received"])
            }
        }

        nonisolated func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
            Task { @MainActor in
                handleReceivedMessage(userInfo)
            }
        }

        @MainActor
        private func handleReceivedMessage(_ message: [String: Any]) {
            guard let type = message[WatchMessageKeys.type] as? String else { return }

            switch type {
            case WatchMessageKeys.typeNewMessage:
                // Handle new message from Watch
                guard let messageData = message[WatchMessageKeys.newMessage] as? Data,
                      let conversationIdString = message[WatchMessageKeys.conversationId] as? String,
                      let conversationId = UUID(uuidString: conversationIdString)
                else {
                    return
                }

                do {
                    let watchMessage = try JSONDecoder().decode(WatchMessage.self, from: messageData)
                    handleNewMessage(from: watchMessage, conversationId: conversationId)
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to decode message from Watch",
                        metadata: ["error": error.localizedDescription]
                    )
                }

            case WatchMessageKeys.typeNewConversation:
                // Handle new conversation created on Watch
                guard let conversationData = message[WatchMessageKeys.conversation] as? Data else {
                    return
                }

                do {
                    let watchConversation = try JSONDecoder().decode(WatchConversation.self, from: conversationData)
                    handleNewConversation(watchConversation)
                } catch {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Failed to decode conversation from Watch",
                        metadata: ["error": error.localizedDescription]
                    )
                }

            case WatchMessageKeys.typeRequestSync:
                // Watch requested a sync
                if let conversations = conversationManager?.conversations {
                    syncConversationsToWatch(conversations)
                }

            case WatchMessageKeys.typeTitleUpdate:
                // Handle title update from Watch
                guard let conversationIdString = message[WatchMessageKeys.conversationId] as? String,
                      let conversationId = UUID(uuidString: conversationIdString),
                      let newTitle = message[WatchMessageKeys.title] as? String
                else {
                    return
                }
                handleTitleUpdate(conversationId: conversationId, newTitle: newTitle)

            default:
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "📱 Unknown message type from Watch",
                    metadata: ["type": type]
                )
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
        func sendMessage(_ watchMessage: WatchMessage, conversationId: UUID) {
            guard let session else { return }

            do {
                let messageData = try JSONEncoder().encode(watchMessage)
                let message: [String: Any] = [
                    WatchMessageKeys.type: WatchMessageKeys.typeNewMessage,
                    WatchMessageKeys.newMessage: messageData,
                    WatchMessageKeys.conversationId: conversationId.uuidString
                ]

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
                let message: [String: Any] = [
                    WatchMessageKeys.type: WatchMessageKeys.typeNewConversation,
                    WatchMessageKeys.conversation: conversationData
                ]

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

            let message: [String: Any] = [
                WatchMessageKeys.type: WatchMessageKeys.typeTitleUpdate,
                WatchMessageKeys.conversationId: conversationId.uuidString,
                WatchMessageKeys.title: newTitle
            ]

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
            // Update conversations
            if let conversationsData = context[WatchContextKeys.conversations] as? Data {
                do {
                    let watchConversations = try JSONDecoder().decode(
                        [WatchConversation].self,
                        from: conversationsData
                    )
                    conversationStore?.updateConversations(watchConversations)

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

            // Update model settings
            if let model = context[WatchContextKeys.selectedModel] as? String {
                selectedModel = model
                OpenAIService.shared.selectedModel = model
            }

            if let models = context[WatchContextKeys.availableModels] as? [String] {
                availableModels = models
            }

            // Update custom models in OpenAIService
            if let customModels = context[WatchContextKeys.customModels] as? [String] {
                OpenAIService.shared.customModels = customModels
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Updated custom models from iPhone",
                    metadata: ["count": "\(customModels.count)"]
                )
            }

            // Update default provider
            if let providerRaw = context[WatchContextKeys.defaultProvider] as? String,
               let provider = AIProvider(rawValue: providerRaw)
            {
                OpenAIService.shared.provider = provider
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Updated default provider from iPhone",
                    metadata: ["provider": providerRaw]
                )
            }

            // Update model providers mapping in OpenAIService
            if let providersDict = context[WatchContextKeys.modelProviders] as? [String: String] {
                var modelProviders: [String: AIProvider] = [:]
                for (model, providerRaw) in providersDict {
                    if let provider = AIProvider(rawValue: providerRaw) {
                        modelProviders[model] = provider
                    }
                }
                OpenAIService.shared.modelProviders = modelProviders

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Updated model providers from iPhone",
                    metadata: ["count": "\(modelProviders.count)"]
                )
            }

            // Update model endpoints for Azure OpenAI and other custom endpoints
            if let modelEndpoints = context[WatchContextKeys.modelEndpoints] as? [String: String] {
                OpenAIService.shared.modelEndpoints = modelEndpoints
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Updated model endpoints from iPhone",
                    metadata: ["count": "\(modelEndpoints.count)"]
                )
            }

            // Update model endpoint types (Chat Completions vs Responses API)
            if let endpointTypesDict = context[WatchContextKeys.modelEndpointTypes] as? [String: String] {
                var modelEndpointTypes: [String: APIEndpointType] = [:]
                for (model, typeRaw) in endpointTypesDict {
                    if let endpointType = APIEndpointType(rawValue: typeRaw) {
                        modelEndpointTypes[model] = endpointType
                    }
                }
                OpenAIService.shared.modelEndpointTypes = modelEndpointTypes
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Updated model endpoint types from iPhone",
                    metadata: ["count": "\(modelEndpointTypes.count)"]
                )
            }

            // Update GitHub OAuth flags for models
            if let modelUsesGitHubOAuth = context[WatchContextKeys.modelUsesGitHubOAuth] as? [String: Bool] {
                OpenAIService.shared.modelUsesGitHubOAuth = modelUsesGitHubOAuth
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Updated GitHub OAuth flags from iPhone",
                    metadata: ["count": "\(modelUsesGitHubOAuth.count)"]
                )
            }

            // Update API keys from iPhone (for free dev accounts without shared Keychain)
            if let apiKey = context[WatchContextKeys.apiKey] as? String, !apiKey.isEmpty {
                OpenAIService.shared.apiKey = apiKey
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Received API key from iPhone"
                )
            }

            if let modelAPIKeys = context[WatchContextKeys.modelAPIKeys] as? [String: String], !modelAPIKeys.isEmpty {
                OpenAIService.shared.modelAPIKeys = modelAPIKeys
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Received model API keys from iPhone",
                    metadata: ["count": "\(modelAPIKeys.count)"]
                )
            }

            // Update GitHub access token for GitHub Models
            if let githubToken = context[WatchContextKeys.githubAccessToken] as? String, !githubToken.isEmpty {
                GitHubOAuthService.shared.setAccessTokenFromWatch(githubToken)
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Received GitHub access token from iPhone"
                )
            }

            // Update Tavily web search settings (stored in OpenAIService for watchOS)
            if let tavilyKey = context[WatchContextKeys.tavilyAPIKey] as? String, !tavilyKey.isEmpty {
                OpenAIService.shared.tavilyAPIKey = tavilyKey
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Received Tavily API key from iPhone"
                )
            }
            if let tavilyEnabled = context[WatchContextKeys.tavilyEnabled] as? Bool {
                OpenAIService.shared.tavilyEnabled = tavilyEnabled
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Updated Tavily enabled state from iPhone",
                    metadata: ["enabled": "\(tavilyEnabled)"]
                )
            }

            if let syncTimestamp = context[WatchContextKeys.lastSyncDate] as? TimeInterval {
                lastSyncDate = Date(timeIntervalSince1970: syncTimestamp)
            }
        }
    }

    extension WatchConnectivityService: WCSessionDelegate {
        nonisolated func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: Error?
        ) {
            Task { @MainActor in
                if let error {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "❌ Watch session activation failed",
                        metadata: ["error": error.localizedDescription]
                    )
                    return
                }

                isReachable = session.isReachable

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Watch session activated",
                    metadata: [
                        "state": "\(activationState.rawValue)",
                        "reachable": "\(session.isReachable)"
                    ]
                )

                // Process any existing context
                let context = session.receivedApplicationContext
                if !context.isEmpty {
                    processContext(context)
                }
            }
        }

        nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
            Task { @MainActor in
                isReachable = session.isReachable

                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ iPhone reachability changed",
                    metadata: ["reachable": "\(session.isReachable)"]
                )
            }
        }

        nonisolated func session(
            _: WCSession,
            didReceiveApplicationContext applicationContext: [String: Any]
        ) {
            Task { @MainActor in
                processContext(applicationContext)
            }
        }
    }

#endif
