//
//  MacSidebarView.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
import SwiftUI

struct MacSidebarView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var selectedConversationId: UUID?
    @State private var selectedConversations = Set<UUID>()
    @State private var searchText = ""
    @State private var searchResults: [Conversation] = []
    @State private var searchTask: Task<Void, Never>?

    private var filteredConversations: [Conversation] {
        let source = searchText.isEmpty ? conversationManager.conversations : searchResults
        return source.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var timelineSections: [ConversationTimelineSection] {
        ConversationTimelineGrouper.sections(from: filteredConversations)
    }

    private func performSearch() {
        searchTask?.cancel()
        let query = searchText

        guard !query.isEmpty else {
            searchResults = []
            return
        }

        searchTask = Task {
            // Debounce
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let currentConversations = conversationManager.conversations
            let results = await conversationManager.searchConversationsAsync(
                query: query, conversations: currentConversations
            )

            if !Task.isCancelled {
                searchResults = results
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Box - iMessage style
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 13, weight: .medium))

                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityIdentifier(TestIdentifiers.Sidebar.searchField)
                    .onChange(of: searchText) { _ in
                        performSearch()
                    }

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        performSearch()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            )
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .onChange(of: conversationManager.conversations) { _ in
                if !searchText.isEmpty {
                    performSearch()
                }
            }

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
                            ForEach(Array(section.conversations.enumerated()), id: \.element.id) { index, conversation in
                                VStack(spacing: 0) {
                                    ConversationRow(conversation: conversation)

                                    // Add divider between conversations (not after the last one in section)
                                    if index < section.conversations.count - 1 {
                                        Divider()
                                            .padding(.leading, 64) // Align with text, past the avatar (44 + 12 + 8)
                                    }
                                }
                                .tag(conversation.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    if selectedConversations.count > 1 {
                                        Button(
                                            role: .destructive,
                                            action: {
                                                deleteConversations(with: selectedConversations)
                                            }
                                        ) {
                                            Label(
                                                "Delete \(selectedConversations.count) Conversations",
                                                systemImage: "trash"
                                            )
                                        }
                                        .accessibilityIdentifier("contextMenu.delete")
                                    } else {
                                        Button(
                                            role: .destructive,
                                            action: {
                                                deleteConversation(with: conversation.id)
                                            }
                                        ) {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .accessibilityIdentifier("contextMenu.delete")
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
                .onDeleteCommand(perform: handleDeleteCommand)
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

    private func deleteConversations(with ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        for conversationId in ids {
            guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                continue
            }
            conversationManager.deleteConversation(conversation)
        }

        if let selectedConversationId, ids.contains(selectedConversationId) {
            self.selectedConversationId = nil
        }
        selectedConversations.subtract(ids)
    }

    private func handleDeleteCommand() {
        if !selectedConversations.isEmpty {
            deleteConversations(with: selectedConversations)
            return
        }

        if let selectedConversationId {
            deleteConversation(with: selectedConversationId)
        }
    }

    private func deleteConversation(with id: UUID) {
        deleteConversations(with: Set([id]))
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    private var lastMessagePreview: String {
        conversation.messages.last(where: { $0.role == .assistant })?.content ?? "No messages"
    }

    private var timeString: String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(conversation.updatedAt) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: conversation.updatedAt)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar - iMessage style gray gradient circle with first initial
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .systemGray),
                            Color(nsColor: .systemGray.withAlphaComponent(0.7)),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 44, height: 44)
                .overlay {
                    if let firstChar = conversation.title.first {
                        Text(String(firstChar).uppercased())
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                // Title row with timestamp
                HStack {
                    Text(conversation.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(timeString)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Message preview
                Text(lastMessagePreview)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationRow(for: conversation.id))
        .contentShape(Rectangle())
    }
}

#Preview {
    MacSidebarView(selectedConversationId: .constant(nil))
        .environmentObject(ConversationManager())
        .frame(width: 300, height: 600)
}
