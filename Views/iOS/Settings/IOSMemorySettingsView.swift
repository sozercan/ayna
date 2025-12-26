//
//  IOSMemorySettingsView.swift
//  ayna
//
//  Created on 12/25/25.
//

import SwiftUI

/// iOS Memory Settings View.
/// Allows users to manage memory facts, view summaries, and configure memory options.
struct IOSMemorySettingsView: View {
    private var memoryService = UserMemoryService.shared
    private var summaryService = ConversationSummaryService.shared
    private var memoryProvider = MemoryContextProvider.shared
    private var metadataService = SessionMetadataService.shared

    @State private var showClearConfirmation = false
    @State private var showFactEditor = false
    @State private var editingFact: UserMemoryFact?
    @State private var newFactContent = ""
    @State private var newFactCategory: UserMemoryFact.MemoryCategory = .other

    var body: some View {
        Form {
            enableSection
            factsSection
            summariesSection
            privacySection
            dangerZoneSection
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if memoryProvider.isMemoryEnabled, !memoryService.isLoaded {
                await memoryProvider.loadAll()
            }
        }
        .sheet(isPresented: $showFactEditor) {
            factEditorSheet
        }
        .confirmationDialog(
            "Clear All Memory",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                clearAllMemory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all stored facts and conversation summaries. This action cannot be undone.")
        }
    }

    // MARK: - Enable Section

    private var enableSection: some View {
        Section {
            Toggle("Enable Memory", isOn: Binding(
                get: { memoryProvider.isMemoryEnabled },
                set: { newValue in
                    memoryProvider.setMemoryEnabled(newValue)
                    if newValue {
                        Task {
                            await memoryProvider.loadAll()
                        }
                    }
                }
            ))
        } header: {
            Text("Memory")
        } footer: {
            Text("Memory allows Ayna to remember information about you across sessions. Say \"remember that...\" to store facts.")
        }
    }

    // MARK: - Facts Section

    private var factsSection: some View {
        Section {
            if !memoryProvider.isMemoryEnabled {
                Text("Enable memory to view and manage facts")
                    .foregroundStyle(.secondary)
            } else if memoryService.facts.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("No facts stored yet")
                        .foregroundStyle(.secondary)
                    Text("Try saying \"Remember that I prefer Swift\" in a conversation")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(memoryService.activeFacts()) { fact in
                    factRow(fact)
                }
                .onDelete(perform: deleteFacts)
            }

            if memoryProvider.isMemoryEnabled {
                Button {
                    editingFact = nil
                    newFactContent = ""
                    newFactCategory = .other
                    showFactEditor = true
                } label: {
                    Label("Add Fact", systemImage: "plus.circle")
                }
            }
        } header: {
            HStack {
                Text("Stored Facts")
                Spacer()
                if memoryProvider.isMemoryEnabled {
                    Text("\(memoryService.activeFacts().count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func factRow(_ fact: UserMemoryFact) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: fact.category.icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(fact.content)
                    .lineLimit(2)

                Text(fact.category.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingFact = fact
            newFactContent = fact.content
            newFactCategory = fact.category
            showFactEditor = true
        }
    }

    private func deleteFacts(at offsets: IndexSet) {
        let facts = memoryService.activeFacts()
        for index in offsets {
            memoryService.deleteFact(facts[index].id)
        }
    }

    // MARK: - Summaries Section

    private var summariesSection: some View {
        Section {
            if !memoryProvider.isMemoryEnabled {
                Text("Enable memory to view conversation summaries")
                    .foregroundStyle(.secondary)
            } else if summaryService.digest.summaries.isEmpty {
                Text("No conversation summaries yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summaryService.digest.summaries) { summary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                            .lineLimit(1)
                        Text(summary.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text("Recent Conversations")
                Spacer()
                if memoryProvider.isMemoryEnabled {
                    Text("\(summaryService.summaryCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("Summaries of your recent conversations help provide context in new chats.")
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        Section {
            Toggle("Session Metadata", isOn: Binding(
                get: { metadataService.isEnabled },
                set: { metadataService.isEnabled = $0 }
            ))

            Toggle("Automatic Fact Extraction", isOn: Binding(
                get: { memoryProvider.isAutoExtractionEnabled },
                set: { memoryProvider.setAutoExtractionEnabled($0) }
            ))
            .disabled(!memoryProvider.isMemoryEnabled)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Session metadata includes device type, timezone, and app version. No personal data is collected.")
        }
    }

    // MARK: - Danger Zone Section

    private var dangerZoneSection: some View {
        Section {
            Button("Clear All Memory", role: .destructive) {
                showClearConfirmation = true
            }
            .disabled(!memoryProvider.isMemoryEnabled)
        } header: {
            Text("Danger Zone")
        }
    }

    // MARK: - Fact Editor Sheet

    private var factEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should Ayna remember?", text: $newFactContent, axis: .vertical)
                        .lineLimit(3 ... 5)
                } header: {
                    Text("Fact")
                }

                Section {
                    Picker("Category", selection: $newFactCategory) {
                        ForEach(UserMemoryFact.MemoryCategory.allCases, id: \.self) { category in
                            Label(category.displayName, systemImage: category.icon)
                                .tag(category)
                        }
                    }
                }
            }
            .navigationTitle(editingFact == nil ? "Add Fact" : "Edit Fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showFactEditor = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingFact == nil ? "Add" : "Save") {
                        saveFact()
                        showFactEditor = false
                    }
                    .disabled(newFactContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func saveFact() {
        let content = newFactContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if let existing = editingFact {
            memoryService.updateFact(existing.id, content: content)
            memoryService.updateFact(existing.id, category: newFactCategory)
        } else {
            memoryService.addFact(content, category: newFactCategory)
        }
    }

    private func clearAllMemory() {
        memoryService.clearAllFacts()
        summaryService.clearAllSummaries()
    }
}

#Preview {
    NavigationStack {
        IOSMemorySettingsView()
    }
}
