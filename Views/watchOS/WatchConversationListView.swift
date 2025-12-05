//
//  WatchConversationListView.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

    import SwiftUI

    /// iMessage-style conversation list for Watch
    /// Shows avatar, title, preview, and timestamp for each conversation
    struct WatchConversationListView: View {
        @EnvironmentObject var conversationStore: WatchConversationStore
        @EnvironmentObject var connectivityService: WatchConnectivityService
        @ObservedObject var viewModel: WatchChatViewModel

        var body: some View {
            Group {
                if conversationStore.conversations.isEmpty {
                    emptyStateView
                } else {
                    conversationList
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchNewChatView(viewModel: viewModel)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier(TestIdentifiers.Watch.newChatButton)
                }
            }
        }

        @ViewBuilder
        private var emptyStateView: some View {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                Text("No Conversations")
                    .font(.headline)

                if !connectivityService.isReachable {
                    Text("Open Ayna on iPhone to sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    NavigationLink {
                        WatchNewChatView(viewModel: viewModel)
                    } label: {
                        Text("New Chat")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .accessibilityIdentifier(TestIdentifiers.Watch.emptyState)
        }

        private var conversationList: some View {
            List {
                ForEach(conversationStore.conversations) { conversation in
                    NavigationLink(value: conversation.id) {
                        ConversationRowView(conversation: conversation)
                    }
                    .accessibilityIdentifier(TestIdentifiers.Watch.conversationRow(for: conversation.id))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            conversationStore.deleteConversation(conversation.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.carousel)
            .accessibilityIdentifier(TestIdentifiers.Watch.conversationList)
            .navigationDestination(for: UUID.self) { conversationId in
                WatchChatView(conversationId: conversationId, viewModel: viewModel)
            }
        }
    }

    /// Single conversation row in the list
    /// Mimics iMessage style with avatar, title, preview, and time
    struct ConversationRowView: View {
        let conversation: WatchConversation

        var body: some View {
            HStack(spacing: 10) {
                // Avatar with first letter
                ZStack {
                    Circle()
                        .fill(Color.blue.gradient)
                        .frame(width: 36, height: 36)

                    Text(avatarLetter)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(conversation.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)

                        Spacer()

                        Text(formattedTime)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text(previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }

        private var avatarLetter: String {
            String(conversation.title.prefix(1)).uppercased()
        }

        private var previewText: String {
            if let lastMessage = conversation.messages.last {
                let stripped = WatchMarkdownRenderer.stripMarkdown(lastMessage.content)
                return stripped.isEmpty ? "..." : stripped
            }
            return "No messages"
        }

        private var formattedTime: String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
        }
    }

    #if DEBUG
        struct WatchConversationListView_Previews: PreviewProvider {
            static var previews: some View {
                NavigationStack {
                    WatchConversationListView(viewModel: WatchChatViewModel())
                        .environmentObject(WatchConversationStore.shared)
                        .environmentObject(WatchConnectivityService.shared)
                }
            }
        }
    #endif

#endif
