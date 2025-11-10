//
//  ContentView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
  @State private var selectedConversationId: UUID?

    var body: some View {
    NavigationSplitView {
            SidebarView(selectedConversationId: $selectedConversationId)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            if let conversationId = selectedConversationId,
               let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                ChatView(conversation: conversation)
                    .id(conversationId)
            } else {
                // Empty state
                Color.clear
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "message")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)

                            Text("No conversation selected")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    )
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ConversationManager())
}
