// swiftformat:options --ifdef no-indent
#if os(watchOS)

#if os(watchOS)

import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var conversationStore: WatchConversationStore
    @EnvironmentObject var connectivityService: WatchConnectivityService
    @StateObject private var viewModel = WatchChatViewModel()

    var body: some View {
        NavigationStack {
            WatchConversationListView(viewModel: viewModel)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            WatchNewChatView(viewModel: viewModel)
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityIdentifier(TestIdentifiers.Watch.newChatButton)
                    }
                }
        }
        .onAppear {
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
#endif
