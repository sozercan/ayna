//
//  WatchContentView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

import SwiftUI

/// Main content view for Watch app
/// Shows conversation list with navigation to chat
struct WatchContentView: View {
    @EnvironmentObject var conversationStore: WatchConversationStore
    @EnvironmentObject var connectivityService: WatchConnectivityService
    @StateObject private var viewModel = WatchChatViewModel()

    var body: some View {
        NavigationStack {
            WatchConversationListView(viewModel: viewModel)
                .navigationTitle("Ayna")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Configure services
            connectivityService.configure(with: conversationStore)
        }
    }
}

#if DEBUG
struct WatchContentView_Previews: PreviewProvider {
    static var previews: some View {
        WatchContentView()
            .environmentObject(WatchConversationStore.shared)
            .environmentObject(WatchConnectivityService.shared)
    }
}
#endif

#endif
