// swiftformat:options --ifdef no-indent
#if os(watchOS)

import SwiftUI

@main
struct AynaWatchApp: App {
    @StateObject private var connectivityService = WatchConnectivityService.shared
    @StateObject private var conversationStore = WatchConversationStore.shared

    init() {
        AppPreferences.registerDefaults()
        UITestEnvironment.configureWatchIfNeeded()
        WatchConnectivityService.shared.configure(with: WatchConversationStore.shared)
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connectivityService)
                .environmentObject(conversationStore)
                .onAppear {
                    guard !UITestEnvironment.isEnabled else { return }
                    connectivityService.requestSync()
                }
        }
    }
}
#endif
