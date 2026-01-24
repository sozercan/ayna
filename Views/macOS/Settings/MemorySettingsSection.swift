//
//  MemorySettingsSection.swift
//  ayna
//
//  Created on 12/25/25.
//

import SwiftUI

/// Memory settings section for macOS Settings view.
/// Allows users to manage memory facts, view summaries, and configure memory options.
struct MemorySettingsSection: View {
    private var memoryService = UserMemoryService.shared
    private var summaryService = ConversationSummaryService.shared
    private var memoryProvider = MemoryContextProvider.shared
    private var metadataService = SessionMetadataService.shared

    @State private var showClearConfirmation = false
    @State private var showFactEditor = false
    @State private var editingFact: UserMemoryFact?
    @State private var newFactContent = ""

    var body: some View {
        Form {
            enableSection
            factsSection
            summariesSection
            privacySection
            dangerZoneSection
        }
        .formStyle(.grouped)
        .padding()
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
            .help("When enabled, Ayna remembers facts about you across conversations")
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
            }

            if memoryProvider.isMemoryEnabled {
                Button {
                    editingFact = nil
                    newFactContent = ""
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
            Text(fact.content)
                .lineLimit(2)

            Spacer()

            Button {
                editingFact = fact
                newFactContent = fact.content
                showFactEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button {
                memoryService.deleteFact(fact.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
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
            .help("Include device and environment info for personalized responses")

            Toggle("Automatic Fact Extraction", isOn: Binding(
                get: { memoryProvider.isAutoExtractionEnabled },
                set: { memoryProvider.setAutoExtractionEnabled($0) }
            ))
            .disabled(!memoryProvider.isMemoryEnabled)
            .help("Automatically detect and store facts from conversations (opt-in)")
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
        VStack(spacing: Spacing.lg) {
            Text(editingFact == nil ? "Add Fact" : "Edit Fact")
                .font(.headline)

            TextField("Fact content", text: $newFactContent, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3 ... 5)

            HStack {
                Button("Cancel") {
                    showFactEditor = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(editingFact == nil ? "Add" : "Save") {
                    saveFact()
                    showFactEditor = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFactContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    // MARK: - Actions

    private func saveFact() {
        let content = newFactContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if let existing = editingFact {
            memoryService.updateFact(existing.id, content: content)
        } else {
            memoryService.addFact(content)
        }
    }

    private func clearAllMemory() {
        memoryService.clearAllFacts()
        summaryService.clearAllSummaries()
    }
}

#Preview {
    MemorySettingsSection()
}
