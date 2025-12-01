//
//  AynaWatchApp.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

import SwiftUI

@main
struct AynaWatchApp: App {
    @StateObject private var connectivityService = WatchConnectivityService.shared
    @StateObject private var conversationStore = WatchConversationStore.shared

    init() {
        // Configure WatchConnectivity with the conversation store
        WatchConnectivityService.shared.configure(with: WatchConversationStore.shared)
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connectivityService)
                .environmentObject(conversationStore)
                .onAppear {
                    // Request sync from iPhone when Watch app opens
                    connectivityService.requestSync()
                }
        }
    }
}
