//
//  MacScrollToBottomButton.swift
//  ayna
//
//  Design System: Scroll-to-Bottom Button (macOS)
//  A floating pill button that appears when user scrolls up from bottom.
//  Native macOS design with material background.
//

import SwiftUI

/// macOS floating scroll-to-bottom button
/// Appears with animation when user scrolls away from bottom
struct MacScrollToBottomButton: View {
    let isVisible: Bool
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(Typography.caption)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.85)
        .animation(Motion.springSnappy, value: isVisible)
        .accessibilityIdentifier("chat.scrollToBottom")
        .accessibilityLabel(unreadCount > 0 ? "Scroll to bottom, \(unreadCount) new messages" : "Scroll to bottom")
    }
}
