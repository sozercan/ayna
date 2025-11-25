//
//  IOSSidebarView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import SwiftUI

struct IOSSidebarView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var isEditing = false
    @State private var selectedConversations = Set<UUID>()

    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversationManager.conversations
        }
        return conversationManager.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Grouped conversations for timeline display
    var groupedConversations: [ConversationTimelineSection] {
        ConversationTimelineGrouper.sections(from: filteredConversations)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if conversationManager.conversations.isEmpty {
                // Empty state when no conversations exist
                emptyStateView
            } else {
                conversationListView
            }

            // Bottom Bar
            bottomBar
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation {
                        isEditing.toggle()
                        if !isEditing {
                            selectedConversations.removeAll()
                        }
                    }
                }
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .accessibilityIdentifier(TestIdentifiers.Sidebar.editButton)
                .disabled(conversationManager.conversations.isEmpty)
            }

            ToolbarItem(placement: .topBarTrailing) {
                if !isEditing {
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityIdentifier(TestIdentifiers.Sidebar.settingsButton)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                IOSSettingsView()
            }
        }
        .onAppear {
            DiagnosticsLogger.log(
                .contentView,
                level: .info,
                message: "📱 IOSSidebarView appeared",
                metadata: ["conversationCount": "\(conversationManager.conversations.count)"]
            )
        }
    }

    // MARK: - Empty State View

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 70))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No Conversations Yet")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Start a new conversation to get started")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                conversationManager.selectedConversationId = ConversationManager.newConversationId
            } label: {
                Label("New Conversation", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sidebar.emptyState.newConversationButton")

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sidebar.emptyState")
    }

    // MARK: - Conversation List View

    @ViewBuilder
    private var conversationListView: some View {
        List(selection: $conversationManager.selectedConversationId) {
            ForEach(groupedConversations) { section in
                Section {
                    ForEach(section.conversations) { conversation in
                        conversationRowContent(for: conversation)
                            .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationRow(for: conversation.id))
                            .swipeActions {
                                Button(role: .destructive) {
                                    // Warning haptic for delete
                                    let generator = UINotificationFeedbackGenerator()
                                    generator.notificationOccurred(.warning)
                                    conversationManager.deleteConversation(conversation)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationList)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
    }

    @ViewBuilder
    private func conversationRowContent(for conversation: Conversation) -> some View {
        HStack {
            if isEditing {
                Image(systemName: selectedConversations.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedConversations.contains(conversation.id) ? .blue : .gray)
                    .font(.system(size: 22))
                    .onTapGesture {
                        toggleSelection(for: conversation)
                    }
                    .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationCheckbox(for: conversation.id))
            }

            if isEditing {
                ConversationRow(conversation: conversation)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleSelection(for: conversation)
                    }
            } else {
                NavigationLink(value: conversation.id) {
                    ConversationRow(conversation: conversation)
                }
            }
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        if isEditing {
            HStack {
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Text("Delete")
                        .font(.headline)
                        .foregroundStyle(selectedConversations.isEmpty ? .gray : .red)
                }
                .disabled(selectedConversations.isEmpty)
                .accessibilityIdentifier(TestIdentifiers.Sidebar.deleteSelectedButton)

                Spacer()
            }
            .padding()
            .background(Color(uiColor: .systemBackground))
        } else {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.gray)
                    TextField("Search", text: $searchText)
                        .accessibilityIdentifier(TestIdentifiers.Sidebar.searchField)
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.gray)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                }

                Button(action: {
                    // Light haptic for new conversation
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()

                    conversationManager.selectedConversationId = ConversationManager.newConversationId
                    DiagnosticsLogger.log(
                        .contentView,
                        level: .info,
                        message: "🆕 New conversation button tapped"
                    )
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background {
                            Circle()
                                .fill(.ultraThinMaterial)
                        }
                }
                .accessibilityIdentifier(TestIdentifiers.Sidebar.newConversationButton)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Private Methods

    private func toggleSelection(for conversation: Conversation) {
        if selectedConversations.contains(conversation.id) {
            selectedConversations.remove(conversation.id)
        } else {
            selectedConversations.insert(conversation.id)
        }
    }

    private func deleteSelected() {
        for id in selectedConversations {
            if let conversation = conversationManager.conversations.first(where: { $0.id == id }) {
                conversationManager.deleteConversation(conversation)
            }
        }
        withAnimation {
            isEditing = false
            selectedConversations.removeAll()
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var lastMessagePreview: String {
        conversation.messages.last?.content ?? "No messages"
    }

    var timeString: String {
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
            // Avatar
            if let image = UIImage(named: "AppIcon") {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.gradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        if let firstChar = conversation.title.first {
                            Text(String(firstChar))
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.white)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(timeString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
