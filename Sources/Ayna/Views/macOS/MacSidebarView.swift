#if os(macOS)
//
//  MacSidebarView.swift
//  ayna
//
//  Created on 11/2/25.
//

import AppKit
import Combine
import SwiftUI

struct MacSidebarView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @EnvironmentObject var projectManager: ProjectManager
    @ObservedObject private var aiService = AIService.shared
    @Binding var selectedConversationId: UUID?
    @State private var selectedConversations = Set<UUID>()
    @State private var searchText = ""
    @State private var searchResults: [Conversation] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedProjectIds = Self.loadExpandedProjectIds()
    @State private var projectPendingRename: Project?
    @State private var renameTitle = ""
    @State private var projectPendingDeletion: Project?

    private var visibleConversations: [Conversation] {
        let source = searchText.isEmpty ? conversationManager.conversations : searchResults
        return source.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var matchingConversationIds: Set<UUID> {
        Set(visibleConversations.map(\.id))
    }

    private var unassignedConversations: [Conversation] {
        visibleConversations.filter { $0.projectId == nil }
    }

    private var timelineSections: [ConversationTimelineSection] {
        ConversationTimelineGrouper.sections(from: unassignedConversations)
    }

    private var visibleProjects: [Project] {
        let filteredProjects: [Project]

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredProjects = projectManager.projects
        } else {
            filteredProjects = projectManager.projects.filter { project in
                projectMatchesQuery(project) || projectHasSearchHits(project)
            }
        }

        return filteredProjects.sorted { projectSortDate(for: $0) > projectSortDate(for: $1) }
    }

    private var hasVisibleContent: Bool {
        !timelineSections.isEmpty || !visibleProjects.isEmpty
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
                        .onChange(of: searchText) { _, _ in
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
            .onChange(of: conversationManager.conversations) { _, _ in
                if !searchText.isEmpty {
                    performSearch()
                }
            }

            // Conversation List
            if !hasVisibleContent {
                VStack(spacing: Spacing.md) {
                    Spacer()
                    Image(systemName: searchText.isEmpty ? "folder.badge.questionmark" : "magnifyingglass")
                        .font(.system(size: Typography.IconSize.hero))
                        .foregroundStyle(Theme.textTertiary)
                        .symbolEffect(.pulse, options: .repeating.speed(0.5))

                    Text(searchText.isEmpty ? "No conversations or projects yet" : "No results found")
                        .font(Typography.bodySecondary)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedConversations) {
                    sectionTitleRow("Conversations")

                    ForEach(timelineSections) { section in
                        Section {
                            ForEach(Array(section.conversations.enumerated()), id: \.element.id) { index, conversation in
                                conversationListRow(
                                    conversation,
                                    showDivider: index < section.conversations.count - 1
                                )
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

                    dividerRow
                    projectsHeaderRow

                    ForEach(visibleProjects) { project in
                        DisclosureGroup(isExpanded: expansionBinding(for: project)) {
                            let projectConversations = conversationsForVisibleProject(project)

                            if projectConversations.isEmpty {
                                Text(searchText.isEmpty ? "No conversations yet" : "No matching conversations")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.sm)
                            } else {
                                ForEach(Array(projectConversations.enumerated()), id: \.element.id) { index, conversation in
                                    conversationListRow(
                                        conversation,
                                        showDivider: index < projectConversations.count - 1,
                                        leadingInset: 28
                                    )
                                }
                            }
                        } label: {
                            projectRow(project: project)
                        }
                        .contextMenu {
                            projectContextMenu(for: project)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            selectProject(project)
                        })
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier(TestIdentifiers.Sidebar.conversationList)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedConversations) { _, newSelection in
                    // Keep single selection in sync for chat view
                    if let firstId = newSelection.first, newSelection.count == 1 {
                        selectedConversationId = firstId
                        projectManager.selectedProjectId = conversationManager
                            .conversation(byId: firstId)?
                            .projectId
                    }
                }
                .onChange(of: selectedConversationId) { _, newSelection in
                    if let newSelection {
                        selectedConversations = [newSelection]
                        if let conversation = conversationManager.conversation(byId: newSelection) {
                            projectManager.selectedProjectId = conversation.projectId
                        }
                    } else {
                        selectedConversations.removeAll()
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
        .alert(
            "Rename Project",
            isPresented: Binding(
                get: { projectPendingRename != nil },
                set: { isPresented in
                    if !isPresented {
                        projectPendingRename = nil
                    }
                }
            )
        ) {
            TextField("Project Name", text: $renameTitle)
            Button("Cancel", role: .cancel) {
                projectPendingRename = nil
            }
            Button("Rename") {
                renameProject()
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Update the project name shown in the sidebar.")
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        projectPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project Only") {
                confirmProjectDeletion(.unassignConversations)
            }
            Button("Delete Project and Conversations", role: .destructive) {
                confirmProjectDeletion(.deleteProjectAndConversations)
            }
            Button("Cancel", role: .cancel) {
                projectPendingDeletion = nil
            }
        } message: {
            if let projectPendingDeletion {
                let conversationCount = projectManager.conversationsForProject(projectPendingDeletion.id).count
                Text("\"\(projectPendingDeletion.title)\" has \(conversationCount) conversation\(conversationCount == 1 ? "" : "s").")
            }
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

    private func projectSortDate(for project: Project) -> Date {
        projectManager.conversationsForProject(project.id).map(\.updatedAt).max() ?? project.updatedAt
    }

    private func projectMatchesQuery(_ project: Project) -> Bool {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return false }

        return project.title.localizedCaseInsensitiveContains(trimmedQuery)
            || project.workspaceRoot.localizedCaseInsensitiveContains(trimmedQuery)
    }

    private func conversationsForVisibleProject(_ project: Project) -> [Conversation] {
        let conversations = projectManager.conversationsForProject(project.id)

        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return conversations
        }

        if projectMatchesQuery(project) {
            return conversations
        }

        return conversations.filter { matchingConversationIds.contains($0.id) }
    }

    private func projectHasSearchHits(_ project: Project) -> Bool {
        !conversationsForVisibleProject(project).isEmpty
    }

    private func isExpanded(_ project: Project) -> Bool {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           projectMatchesQuery(project) || projectHasSearchHits(project)
        {
            return true
        }

        return expandedProjectIds.contains(project.id)
    }

    private func expansionBinding(for project: Project) -> Binding<Bool> {
        Binding(
            get: { isExpanded(project) },
            set: { newValue in
                if newValue {
                    expandedProjectIds.insert(project.id)
                } else {
                    expandedProjectIds.remove(project.id)
                }
                Self.saveExpandedProjectIds(expandedProjectIds)
            }
        )
    }

    @ViewBuilder
    private func conversationListRow(
        _ conversation: Conversation,
        showDivider: Bool,
        leadingInset: CGFloat = 0
    ) -> some View {
        VStack(spacing: 0) {
            ConversationRow(conversation: conversation)
                .padding(.leading, leadingInset)

            if showDivider {
                Divider()
                    .padding(.leading, 64 + leadingInset)
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

    @ViewBuilder
    private func sectionTitleRow(_ title: String) -> some View {
        Text(title)
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .textCase(nil)
            .padding(.horizontal, Spacing.sm)
            .padding(.top, Spacing.xs)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .selectionDisabled(true)
    }

    private var dividerRow: some View {
        Divider()
            .padding(.vertical, Spacing.sm)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .selectionDisabled(true)
    }

    private var projectsHeaderRow: some View {
        HStack {
            Text("Projects")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Button {
                createProjectFromFolderPicker()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add Project")
        }
        .padding(.horizontal, Spacing.sm)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .selectionDisabled(true)
    }

    @ViewBuilder
    private func projectRow(project: Project) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "folder")
                .foregroundStyle(Theme.accent)
            Text(project.title)
                .font(Typography.body.weight(.semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(
            projectManager.selectedProjectId == project.id
                ? Theme.accent.opacity(0.12)
                : .clear
        )
        .clipShape(.rect(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func projectContextMenu(for project: Project) -> some View {
        Button {
            renameTitle = project.title
            projectPendingRename = project
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            expandedProjectIds.insert(project.id)
            Self.saveExpandedProjectIds(expandedProjectIds)
            selectProject(project)
            startNewConversation()
        } label: {
            Label("New Conversation", systemImage: "square.and.pencil")
        }

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.workspaceRoot)])
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }

        Button(role: .destructive) {
            projectPendingDeletion = project
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func selectProject(_ project: Project) {
        projectManager.selectedProjectId = project.id
    }

    private func renameProject() {
        guard let projectPendingRename else { return }

        var renamedProject = projectPendingRename
        renamedProject.title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        projectManager.updateProject(renamedProject)
        self.projectPendingRename = nil
    }

    private func confirmProjectDeletion(_ behavior: ProjectManager.DeletionBehavior) {
        guard let projectPendingDeletion else { return }

        let deletedConversationIds = Set(
            projectManager.conversationsForProject(projectPendingDeletion.id).map(\.id)
        )

        projectManager.deleteProject(projectPendingDeletion, behavior: behavior)

        if let selectedConversationId, deletedConversationIds.contains(selectedConversationId),
           behavior == .deleteProjectAndConversations
        {
            self.selectedConversationId = nil
        }

        selectedConversations.subtract(deletedConversationIds)
        self.projectPendingDeletion = nil
    }

    private func createProjectFromFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        if let existingProject = projectManager.project(forWorkspaceRoot: url.path) {
            expandedProjectIds.insert(existingProject.id)
            Self.saveExpandedProjectIds(expandedProjectIds)
            selectProject(existingProject)
            return
        }

        let defaultModel = aiService.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectManager.createProject(
            title: url.lastPathComponent,
            workspaceRoot: url.path,
            defaultModel: defaultModel.isEmpty ? nil : defaultModel
        )
        expandedProjectIds.insert(project.id)
        Self.saveExpandedProjectIds(expandedProjectIds)
    }

    private static func loadExpandedProjectIds() -> Set<UUID> {
        let storedIds = AppPreferences.storage.array(forKey: "expandedProjectIds") as? [String] ?? []
        return Set(storedIds.compactMap(UUID.init(uuidString:)))
    }

    private static func saveExpandedProjectIds(_ ids: Set<UUID>) {
        let encodedIds = ids.map(\.uuidString).sorted()
        AppPreferences.storage.set(encodedIds, forKey: "expandedProjectIds")
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    private var lastMessagePreview: String {
        conversation.messages.last(where: { $0.role == .assistant })?.content ?? "No messages"
    }

    private var timeString: String {
        if Calendar.current.isDateInToday(conversation.updatedAt) {
            Self.timeFormatter.string(from: conversation.updatedAt)
        } else {
            Self.dateFormatter.string(from: conversation.updatedAt)
        }
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
        #if compiler(>=6.2)
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
        #else
            content
                .background {
                    Capsule()
                        .fill(.regularMaterial)
                }
        #endif
    }
}

#Preview {
    let conversationManager = ConversationManager()
    let projectManager = ProjectManager(conversationManager: conversationManager)

    return MacSidebarView(selectedConversationId: .constant(nil))
        .environmentObject(conversationManager)
        .environmentObject(projectManager)
        .frame(width: 300, height: 600)
}
#endif
