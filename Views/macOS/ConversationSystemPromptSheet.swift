//
//  ConversationSystemPromptSheet.swift
//  ayna
//
//  Created on 11/25/25.
//

import SwiftUI

/// A sheet view for editing the system prompt mode of a conversation.
struct ConversationSystemPromptSheet: View {
    let conversation: Conversation
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversationManager: ConversationManager

    @State private var selectedMode: SystemPromptModeSelection = .inheritGlobal
    @State private var customPrompt: String = ""

    enum SystemPromptModeSelection: String, CaseIterable {
        case inheritGlobal = "Use Global Default"
        case custom = "Custom"
        case disabled = "Disabled"
    }

    init(conversation: Conversation) {
        self.conversation = conversation

        // Initialize state from conversation
        switch conversation.systemPromptMode {
        case .inheritGlobal:
            _selectedMode = State(initialValue: .inheritGlobal)
            _customPrompt = State(initialValue: "")
        case let .custom(prompt):
            _selectedMode = State(initialValue: .custom)
            _customPrompt = State(initialValue: prompt)
        case .disabled:
            _selectedMode = State(initialValue: .disabled)
            _customPrompt = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("System Prompt")
                .font(Typography.headline)

            Picker("Mode", selection: $selectedMode) {
                ForEach(SystemPromptModeSelection.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("chat.systemPromptMode.picker")

            if selectedMode == .inheritGlobal {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Current Global Prompt:")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    let globalPrompt = AppPreferences.globalSystemPrompt
                    if globalPrompt.isEmpty {
                        Text("(No global prompt set)")
                            .foregroundStyle(Theme.textTertiary)
                            .italic()
                    } else {
                        Text(globalPrompt)
                            .font(Typography.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
                    }
                }
            } else if selectedMode == .custom {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Custom Prompt:")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    TextEditor(text: $customPrompt)
                        .font(Typography.body)
                        .frame(minHeight: 100, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.sm)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
                                .stroke(Theme.separator, lineWidth: Spacing.Border.standard)
                        )
                        .accessibilityIdentifier("chat.systemPrompt.customEditor")
                }
            } else {
                Text("No system prompt will be used for this conversation.")
                    .foregroundStyle(Theme.textSecondary)
                    .italic()
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 450, height: 350)
    }

    private func saveAndDismiss() {
        let mode: SystemPromptMode = switch selectedMode {
        case .inheritGlobal:
            .inheritGlobal
        case .custom:
            .custom(customPrompt)
        case .disabled:
            .disabled
        }

        conversationManager.updateSystemPromptMode(for: conversation, mode: mode)
        dismiss()
    }
}

#Preview {
    ConversationSystemPromptSheet(conversation: Conversation())
        .environmentObject(ConversationManager())
}
