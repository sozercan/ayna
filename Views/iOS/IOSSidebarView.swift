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
    @ObservedObject var openAIService = OpenAIService.shared
    @Binding var columnVisibility: NavigationSplitViewVisibility
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
            conversationListView

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
        VStack(spacing: Spacing.xxl) {
            Spacer()

            if openAIService.usableModels.isEmpty {
                Image(systemName: "sparkles")
                    .font(.system(size: Typography.IconSize.heroLarge + 10))
                    .foregroundStyle(Theme.accent.opacity(0.9))
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: Typography.IconSize.heroLarge + 10))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: Spacing.sm) {
                Text(openAIService.usableModels.isEmpty ? "Welcome to Ayna" : "No Conversations Yet")
                    .font(Typography.title2)
                    .fontWeight(.semibold)

                Text(openAIService.usableModels.isEmpty ? "Please add an AI model to get started" : "Start a new conversation to get started")
                    .font(Typography.bodySecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                startNewConversation()
            } label: {
                Label(
                    openAIService.usableModels.isEmpty ? "Add Model" : "New Conversation",
                    systemImage: openAIService.usableModels.isEmpty ? "gearshape.fill" : "plus.circle.fill"
                )
                .font(Typography.headline)
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.md)
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
                                    DiagnosticsLogger.log(
                                        .conversationManager,
                                        level: .info,
                                        message: "🗑️ Deleting conversation via swipe",
                                        metadata: [
                                            "conversationId": conversation.id.uuidString,
                                            "title": conversation.title,
                                        ]
                                    )
                                    conversationManager.deleteConversation(conversation)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(section.title)
                        .font(Typography.bodySecondary)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(nil)
                }
            }

            // Hidden row for new conversation navigation
            // This ensures NavigationSplitView can navigate to the new chat view
            // even when it's not in the list of conversations
            // Moved to bottom to prevent gap at top of list
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .tag(ConversationManager.newConversationId)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
        .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationList)
        .overlay {
            if conversationManager.conversations.isEmpty {
                emptyStateView
            }
        }
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
                        .font(Typography.headline)
                        .foregroundStyle(selectedConversations.isEmpty ? Theme.textSecondary : Theme.destructive)
                }
                .disabled(selectedConversations.isEmpty)
                .accessibilityIdentifier(TestIdentifiers.Sidebar.deleteSelectedButton)

                Spacer()
            }
            .padding()
            .background(Theme.background)
        } else {
            HStack(spacing: Spacing.md) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Search", text: $searchText)
                        .accessibilityIdentifier(TestIdentifiers.Sidebar.searchField)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.vertical, Spacing.md)
                .padding(.horizontal, Spacing.md)
                .background {
                    RoundedRectangle(cornerRadius: Spacing.CornerRadius.xl)
                        .fill(.ultraThinMaterial)
                }

                Button(action: {
                    startNewConversation()
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: Typography.IconSize.lg, weight: .medium))
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
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.lg)
        }
    }

    // MARK: - Private Methods

    private func toggleSelection(for conversation: Conversation) {
        if selectedConversations.contains(conversation.id) {
            selectedConversations.remove(conversation.id)
            DiagnosticsLogger.log(
                .contentView,
                level: .debug,
                message: "⬜ Deselected conversation",
                metadata: ["conversationId": conversation.id.uuidString]
            )
        } else {
            selectedConversations.insert(conversation.id)
            DiagnosticsLogger.log(
                .contentView,
                level: .debug,
                message: "✅ Selected conversation",
                metadata: ["conversationId": conversation.id.uuidString]
            )
        }
    }

    private func deleteSelected() {
        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "🗑️ Bulk deleting conversations",
            metadata: ["count": "\(selectedConversations.count)"]
        )
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

    /// Start a new conversation and navigate to it
    private func startNewConversation() {
        // If no models are available, direct user to settings
        if openAIService.usableModels.isEmpty {
            showSettings = true
            return
        }

        // Light haptic for new conversation
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Set selection to new conversation ID
        conversationManager.selectedConversationId = ConversationManager.newConversationId

        // On iPhone, collapse sidebar to show detail view
        withAnimation {
            columnVisibility = .detailOnly
        }

        DiagnosticsLogger.log(
            .contentView,
            level: .info,
            message: "🆕 New conversation button tapped"
        )
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
                .frame(width: 48, height: 48)
                .overlay {
                    if let firstChar = conversation.title.first {
                        Text(String(firstChar).uppercased())
                            .font(Typography.title3)
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "bubble.left.fill")
                            .foregroundStyle(.white)
                    }
                }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack {
                    Text(conversation.title)
                        .font(Typography.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(timeString)
                        .font(Typography.bodySecondary)
                        .foregroundStyle(Theme.textSecondary)
                }

                Text(lastMessagePreview)
                    .font(Typography.bodySecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}
