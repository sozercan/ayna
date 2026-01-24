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
            // Search Box - iMessage style with liquid glass on macOS 26+
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                    .font(.system(size: 15, weight: .regular))

                ZStack(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textPlaceholder)
                    }
                    TextField("", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .accessibilityIdentifier(TestIdentifiers.Sidebar.searchField)
                        .onChange(of: searchText) {
                            performSearch()
                        }
                }

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        performSearch()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 30)
            .modifier(IMessageSearchBarStyle())
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .onChange(of: conversationManager.conversations) {
                if !searchText.isEmpty {
                    performSearch()
                }
            }

            // Conversation List
            if filteredConversations.isEmpty {
                VStack(spacing: Spacing.md) {
                    Spacer()
                    Image(systemName: searchText.isEmpty ? "message" : "magnifyingglass")
                        .font(.system(size: Typography.IconSize.hero))
                        .foregroundStyle(Theme.textTertiary)
                        .symbolEffect(.pulse, options: .repeating.speed(0.5))

                    Text(searchText.isEmpty ? "No conversations yet" : "No results found")
                        .font(Typography.bodySecondary)
                        .foregroundStyle(Theme.textSecondary)
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
                                .font(Typography.footnote)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.top, section.id == timelineSections.first?.id ? 0 : Spacing.xs)
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
        // Apply translucent background - on macOS 26+ use clear for glass effects, otherwise material
        .modifier(SidebarBackgroundStyle())
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

    /// Generate a consistent color based on conversation ID for unique avatars
    private var avatarColor: Color {
        let hash = conversation.id.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.4, brightness: 0.65)
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Avatar - unique color per conversation based on ID hash
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            avatarColor,
                            avatarColor.opacity(0.7)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: Spacing.Component.avatarSize, height: Spacing.Component.avatarSize)
                .overlay {
                    if let firstChar = conversation.title.first {
                        Text(String(firstChar).uppercased())
                            .font(Typography.headline)
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: Typography.IconSize.md))
                            .foregroundStyle(.white)
                    }
                }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // Title row with timestamp
                HStack {
                    Text(conversation.title)
                        .font(Typography.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(timeString)
                        .font(Typography.timestamp)
                        .foregroundStyle(Theme.textSecondary)
                }

                // Message preview
                Text(lastMessagePreview)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.md)
        .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationRow(for: conversation.id))
        .contentShape(Rectangle())
    }
}

// MARK: - iMessage Style Modifiers

/// A view modifier that applies appropriate background for the sidebar
/// Uses clear background on macOS 26+ to allow glass effects, falls back to material on earlier versions
private struct SidebarBackgroundStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
        } else {
            content
                .background(.regularMaterial)
        }
    }
}

/// A view modifier that applies iMessage-style capsule background for the search bar
/// Uses glassEffect on macOS 26+, falls back to material fill on earlier versions
private struct IMessageSearchBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background {
                    Capsule()
                        .fill(.regularMaterial)
                }
        }
    }
}

#Preview {
    MacSidebarView(selectedConversationId: .constant(nil))
        .environmentObject(ConversationManager())
        .frame(width: 300, height: 600)
}
