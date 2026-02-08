//
//  ToolExecutionIndicator.swift
//  ayna
//
//  Extracted from MacChatView/MacNewChatView - Tool execution status indicator
//

import SwiftUI

/// Displays the current tool execution status during AI response generation
struct ToolExecutionIndicator: View {
    let toolName: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .scaleEffect(0.8)
                .controlSize(.small)

            Text(displayText)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, Spacing.sm)
        .background(Theme.accent.opacity(0.1))
    }

    private var displayText: String {
        if toolName.hasPrefix("Analyzing") {
            "🔄 \(toolName)..."
        } else {
            "🔧 Using tool: \(toolName)..."
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ToolExecutionIndicator(toolName: "web_search")
        ToolExecutionIndicator(toolName: "Analyzing web_search results")
    }
    .padding()
}
