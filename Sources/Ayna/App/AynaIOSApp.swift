// swiftformat:options --ifdef no-indent
#if os(iOS)

import os
import SwiftUI
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

private let handoffActivityType = "com.sertacozercan.ayna.conversation"

@main
struct AynaIOSApp: App {
    @StateObject private var conversationManager: ConversationManager
    @StateObject private var aiService: AIService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppPreferences.registerDefaults()
        UITestEnvironment.configureIfNeeded()

        Message.attachmentLoader = { path in
            AttachmentStorage.shared.load(path: path)
        }
        Message.attachmentAsyncLoader = { path in
            await AttachmentStorage.shared.loadData(path: path)
        }

        _aiService = StateObject(wrappedValue: AIService.shared)

        let manager: ConversationManager = if UITestEnvironment.isEnabled {
            UITestEnvironment.makeConversationManager()
        } else {
            ConversationManager()
        }
        _conversationManager = StateObject(wrappedValue: manager)
        if !UITestEnvironment.isEnabled {
            Task { @MainActor in
                MemoryContextProvider.shared.attachConversationSource(manager)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environmentObject(conversationManager)
                .environmentObject(aiService)
                .onOpenURL { url in
                    Task {
                        await conversationManager.loadingTask?.value

                        await DeepLinkManager.shared.handle(url: url)

                        if let chatRequest = DeepLinkManager.shared.consumeNextReadyChat() {
                            _ = conversationManager.startConversation(
                                model: chatRequest.model,
                                prompt: chatRequest.prompt,
                                systemPrompt: chatRequest.systemPrompt
                            )
                        }
                    }
                }
                .onContinueUserActivity(handoffActivityType) { activity in
                    handleHandoff(activity)
                }
                .task {
                    guard !UITestEnvironment.isEnabled else { return }
                    await setupWatchConnectivity()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        Task { @MainActor in
                            await conversationManager.flushPendingSaves()
                            await MemoryContextProvider.shared.saveAll()
                        }
                    }
                }
        }
    }

    @MainActor
    private func setupWatchConnectivity() async {
        await conversationManager.loadingTask?.value

        WatchConnectivityService.shared.configure(with: conversationManager)

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
#endif
