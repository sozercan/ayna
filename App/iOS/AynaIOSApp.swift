//
//  AynaIOSApp.swift
//  ayna
//
//  Created on 11/22/25.
//

import os
import SwiftUI
#if canImport(WatchConnectivity)
    import WatchConnectivity
#endif

/// Activity type for Handoff from Apple Watch
private let handoffActivityType = "com.sertacozercan.ayna.conversation"

@main
struct AynaIOSApp: App {
    @StateObject private var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register defaults and configure UI test environment if needed
        AppPreferences.registerDefaults()
        UITestEnvironment.configureIfNeeded()

        // Configure attachment loader
        Message.attachmentLoader = { path in
            AttachmentStorage.shared.load(path: path)
        }

        // Initialize conversation manager (use test store in UI test mode)
        let manager: ConversationManager = if UITestEnvironment.isEnabled {
            UITestEnvironment.makeConversationManager()
        } else {
            ConversationManager()
        }
        _conversationManager = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environmentObject(conversationManager)
                .environmentObject(openAIService)
                .onOpenURL { url in
                    Task {
                        // Handle deep links (including OAuth callbacks)
                        await DeepLinkManager.shared.handle(url: url)

                        // Handle chat deep links by starting a conversation
                        if let chatRequest = DeepLinkManager.shared.pendingChat {
                            _ = conversationManager.startConversation(
                                model: chatRequest.model,
                                prompt: chatRequest.prompt,
                                systemPrompt: chatRequest.systemPrompt
                            )
                            DeepLinkManager.shared.clearPendingChat()
                        }
                    }
                }
                .onContinueUserActivity(handoffActivityType) { activity in
                    handleHandoff(activity)
                }
                .task {
                    // Skip WatchConnectivity setup during UI tests
                    guard !UITestEnvironment.isEnabled else { return }
                    await setupWatchConnectivity()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        // Save memory data when app goes to background
                        Task { @MainActor in
                            await MemoryContextProvider.shared.saveAll()
                        }
                    }
                }
        }
    }

    @MainActor
    private func setupWatchConnectivity() async {
        // Wait for conversations to load before syncing
        await conversationManager.loadingTask?.value

        // Configure WatchConnectivity to sync with Apple Watch
        WatchConnectivityService.shared.configure(with: conversationManager)

        // Trigger initial sync of settings and conversations (now that they're loaded)
        WatchConnectivityService.shared.syncConversationsToWatch(conversationManager.conversations)
    }

    @MainActor
    private func handleHandoff(_ activity: NSUserActivity) {
        guard let userInfo = activity.userInfo,
              let conversationIdString = userInfo["conversationId"] as? String,
              let conversationId = UUID(uuidString: conversationIdString)
        else {
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "❌ Failed to parse Handoff activity"
            )
            return
        }

        // Check if the conversation exists
        if conversationManager.conversations.contains(where: { $0.id == conversationId }) {
            conversationManager.selectedConversationId = conversationId
            DiagnosticsLogger.log(
                .app,
                level: .info,
                message: "✅ Handoff: Opened conversation from Watch",
                metadata: ["conversationId": conversationIdString]
            )
        } else {
            DiagnosticsLogger.log(
                .app,
                level: .default,
                message: "⚠️ Handoff: Conversation not found",
                metadata: ["conversationId": conversationIdString]
            )
        }
    }
}
