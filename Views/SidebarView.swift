//
//  SidebarView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @StateObject private var openAIService = OpenAIService.shared
    @Binding var selectedConversationId: UUID?
    @State private var selectedConversations = Set<UUID>()
    @State private var searchText = ""

    private var filteredConversations: [Conversation] {
        conversationManager.searchConversations(query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Box
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Conversation List
            if filteredConversations.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: searchText.isEmpty ? "message" : "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)

                    Text(searchText.isEmpty ? "No conversations yet" : "No results found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedConversations) {
          // Add spacer at top to prevent first item from being cut off
          Color.clear
            .frame(height: 1)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

          ForEach(filteredConversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .contextMenu {
                                Menu("Change Model") {
                                    ForEach(openAIService.customModels, id: \.self) { model in
                                        Button(action: {
                                            conversationManager.updateModel(for: conversation, model: model)
                                        }) {
                                            HStack {
                                                Text(model)
                                                if conversation.model == model {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                Divider()

                                if selectedConversations.count > 1 {
                                    Button(role: .destructive, action: {
                                        deleteSelectedConversations()
                                    }) {
                                        Label("Delete \(selectedConversations.count) Conversations", systemImage: "trash")
                                    }
                                } else {
                                    Button(role: .destructive, action: {
                                        conversationManager.deleteConversation(conversation)
                                        if selectedConversationId == conversation.id {
                                            selectedConversationId = nil
                                        }
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onChange(of: selectedConversations) { _, newSelection in
                    // Keep single selection in sync for chat view
          if let firstId = newSelection.first, newSelection.count == 1 {
            selectedConversationId = firstId
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "message")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Text(conversation.title)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)

                Spacer()
            }

            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(conversation.model)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
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
