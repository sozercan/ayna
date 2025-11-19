//
//  SidebarView.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var selectedConversationId: UUID?
    @State private var selectedConversations = Set<UUID>()
    @State private var searchText = ""

    private var filteredConversations: [Conversation] {
        conversationManager
            .searchConversations(query: searchText)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var timelineSections: [ConversationTimelineSection] {
        ConversationTimelineGrouper.sections(from: filteredConversations)
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
                    .accessibilityIdentifier(TestIdentifiers.Sidebar.searchField)

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
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

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
                    ForEach(timelineSections) { section in
                        Section {
                            ForEach(section.conversations) { conversation in
                                ConversationRow(conversation: conversation)
                                    .tag(conversation.id)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                                    .contextMenu {
                                        if selectedConversations.count > 1 {
                                            Button(
                                                role: .destructive,
                                                action: {
                                                    deleteSelectedConversations()
                                                },
                                            ) {
                                                Label(
                                                    "Delete \(selectedConversations.count) Conversations",
                                                    systemImage: "trash",
                                                )
                                            }
                                        } else {
                                            Button(
                                                role: .destructive,
                                                action: {
                                                    conversationManager.deleteConversation(conversation)
                                                    if selectedConversationId == conversation.id {
                                                        selectedConversationId = nil
                                                    }
                                                },
                                            ) {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                        } header: {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, section.id == timelineSections.first?.id ? 0 : 6)
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationList)
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
                Button(action: startNewConversation) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityIdentifier(TestIdentifiers.Sidebar.newConversationButton)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConversationRequested)) { _ in
            selectedConversationId = nil
            selectedConversations.removeAll()
        }
    }

    private func startNewConversation() {
        selectedConversationId = nil
        selectedConversations.removeAll()
        NotificationCenter.default.post(name: .newConversationRequested, object: nil)
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
        .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationRow(for: conversation.id))
        .contentShape(Rectangle())
    }
}

#Preview {
    SidebarView(selectedConversationId: .constant(nil))
        .environmentObject(ConversationManager())
        .frame(width: 300, height: 600)
}
