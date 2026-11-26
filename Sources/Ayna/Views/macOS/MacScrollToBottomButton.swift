// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

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
#endif
