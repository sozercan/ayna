//
//  SidebarView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @Binding var selectedConversationId: UUID?
    @State private var selectedConversations = Set<UUID>()

    var body: some View {
        ZStack {
            // Sidebar background with material
            Color.clear
                .background(.ultraThinMaterial)

            VStack(spacing: 0) {
                // Conversation List
                if conversationManager.conversations.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "message")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)

                    Text("No conversations yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(selection: $selectedConversations) {
                    ForEach(conversationManager.conversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .contextMenu {
                                Button(role: .destructive, action: {
                                    conversationManager.deleteConversation(conversation)
                                    if selectedConversationId == conversation.id {
                                        selectedConversationId = nil
                                    }
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }

                                if selectedConversations.count > 1 {
                                    Button(role: .destructive, action: {
                                        deleteSelectedConversations()
                                    }) {
                                        Label("Delete \(selectedConversations.count) Conversations", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedConversations) { _, newSelection in
                    // Keep single selection in sync for chat view
                    if let firstId = newSelection.first, newSelection.count == 1 {
                        selectedConversationId = firstId
                    }
                }
            }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    conversationManager.createNewConversation()
                    if let newConversation = conversationManager.conversations.first {
                        selectedConversationId = newConversation.id
                        selectedConversations = [newConversation.id]
                    }
                }) {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
    }

    private func deleteSelectedConversations() {
        for conversationId in selectedConversations {
            if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                conversationManager.deleteConversation(conversation)
            }
        }

        // Clear selection
        if selectedConversations.contains(selectedConversationId ?? UUID()) {
            selectedConversationId = nil
        }
        selectedConversations.removeAll()
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "message")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text(conversation.title)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

#Preview {
    SidebarView(selectedConversationId: .constant(nil))
        .environmentObject(ConversationManager())
        .frame(width: 300, height: 600)
}
