//
//  ToolExecutionIndicator.swift
//  ayna
//

import SwiftUI

/// Tool execution status indicator shown during tool calls
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
