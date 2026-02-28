#if os(macOS)
//
//  ChatToolbar.swift
//  ayna
//
//  Extracted from MacChatView.swift - Toolbar items for chat view
//

import SwiftUI

/// Toolbar items for the chat view including system prompt and export buttons
struct ChatToolbarContent: ToolbarContent {
    @Binding var showingSystemPromptSheet: Bool
    let onExportMarkdown: () -> Void
    let onExportPDF: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Spacer()
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingSystemPromptSheet = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .accessibilityIdentifier("chat.systemPrompt.button")
            .help("Conversation System Prompt")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(action: onExportMarkdown) {
                    Label("Export as Markdown", systemImage: "doc.text")
                }
                Button(action: onExportPDF) {
                    Label("Export as PDF", systemImage: "doc.text.image")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuIndicator(.visible)
            .accessibilityLabel("Export conversation")
        }
    }
}

/// Tool execution status indicator
struct ToolExecutionIndicator: View {
    let toolName: String?

    var body: some View {
        if let toolName {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .scaleEffect(0.8)
                    .controlSize(.small)
                Text(toolName.hasPrefix("Analyzing") ? "🔄 \(toolName)..." : "🔧 Using tool: \(toolName)...")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, Spacing.sm)
            .background(Theme.accent.opacity(0.1))
        }
    }
}

#endif
