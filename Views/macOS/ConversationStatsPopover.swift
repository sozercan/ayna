//
//  ConversationStatsPopover.swift
//  Ayna
//
//  Displays conversation statistics in a popover including message counts,
//  word count, and conversation duration.
//

import SwiftUI

// MARK: - Conversation Stats Popover

/// A popover view that displays statistics about a conversation.
struct ConversationStatsPopover: View {
    // MARK: - Properties

    let stats: ConversationStats

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header
            Text("Conversation Statistics")
                .font(Typography.captionBold)
                .foregroundStyle(Theme.textSecondary)

            Divider()
                .padding(.vertical, Spacing.xxs)

            // Stats Grid
            statsGrid

            Divider()
                .padding(.vertical, Spacing.xxs)

            // Duration
            durationRow
        }
        .padding(Spacing.lg)
        .frame(minWidth: 200)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            StatRow(
                icon: "bubble.left.and.bubble.right",
                label: "Total Messages",
                value: "\(stats.totalMessages)"
            )

            StatRow(
                icon: "person",
                label: "Your Messages",
                value: "\(stats.userMessages)"
            )

            StatRow(
                icon: "sparkles",
                label: "Assistant Messages",
                value: "\(stats.assistantMessages)"
            )

            StatRow(
                icon: "text.word.spacing",
                label: "Word Count",
                value: "\(stats.wordCount)"
            )
        }
    }

    @ViewBuilder
    private var durationRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "clock")
                .font(.system(size: Typography.IconSize.sm))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: Typography.IconSize.md)

            Text("Duration")
                .font(Typography.footnote)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Text(stats.formattedDuration)
                .font(Typography.footnote)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Stat Row

/// A single row displaying a statistic with an icon, label, and value.
private struct StatRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: Typography.IconSize.sm))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: Typography.IconSize.md)

            Text(label)
                .font(Typography.footnote)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Text(value)
                .font(Typography.footnote)
                .fontWeight(.medium)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Previews

#if DEBUG
    #Preview("Stats Popover") {
        ConversationStatsPopover(
            stats: ConversationStats(
                totalMessages: 42,
                userMessages: 21,
                assistantMessages: 21,
                wordCount: 1250,
                duration: 3600 // 1 hour
            )
        )
        .padding()
    }

    #Preview("Empty Conversation") {
        ConversationStatsPopover(
            stats: ConversationStats(
                totalMessages: 0,
                userMessages: 0,
                assistantMessages: 0,
                wordCount: 0,
                duration: 0
            )
        )
        .padding()
    }
#endif
