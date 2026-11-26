// swiftformat:options --ifdef no-indent
#if os(iOS)

import SwiftUI

#if os(iOS)
struct ScrollToBottomButton: View {
    let isVisible: Bool
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticEngine.impact(.light)
            action()
        }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(Typography.captionBold)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.8)
        .animation(Motion.springSnappy, value: isVisible)
        .accessibilityIdentifier("chat.scrollToBottom")
        .accessibilityLabel(unreadCount > 0 ? "Scroll to bottom, \(unreadCount) new messages" : "Scroll to bottom")
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollToBottomModifier: ViewModifier {
    @Binding var showButton: Bool
    let threshold: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: geo.frame(in: .named("scroll")).minY
                    )
                }
            )
    }
}

extension View {
    func trackScrollPosition(showButton: Binding<Bool>, threshold: CGFloat = 100) -> some View {
        modifier(ScrollToBottomModifier(showButton: showButton, threshold: threshold))
    }
}
#endif

#if os(macOS)
struct ScrollToBottomButton: View {
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
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .animation(Motion.easeQuick, value: isVisible)
        .accessibilityIdentifier("chat.scrollToBottom")
    }
}
#endif
#endif
