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

/// Rate limit warning banner for GitHub Models
struct RateLimitWarningBanner: View {
    let rateLimitInfo: GitHubRateLimitInfo?
    let retryAfterDate: Date?

    var body: some View {
        if let rateLimitInfo, rateLimitInfo.isNearLimit {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.statusConnecting)
                Text(rateLimitInfo.warningMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(Spacing.sm)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
        } else if let retryAfter = retryAfterDate, retryAfter > Date() {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(Theme.statusError)
                Text("Rate limited. Retry in \(formattedTimeRemaining(until: retryAfter))")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(Spacing.sm)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
        }
    }

    private func formattedTimeRemaining(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds > 60 {
            return "\(seconds / 60) min"
        }
        return "\(max(1, seconds)) sec"
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

// Note: ErrorBannerView is defined in Core/Design/ErrorBannerView.swift
// Do not add a duplicate here - use the cross-platform version from Core
