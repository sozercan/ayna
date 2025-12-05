//
//  ScrollToBottomButton.swift
//  ayna
//
//  Design System: Scroll-to-Bottom Button
//  A floating pill button that appears when user scrolls up from bottom.
//  Apple-native design with blur background and spring animation.
//

import SwiftUI

// MARK: - iOS Scroll-to-Bottom Button

#if os(iOS)
    /// A floating pill button that scrolls to the bottom of a message list.
    /// Appears with spring animation when user scrolls away from bottom.
    /// Uses materials for native blur effect.
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

    // MARK: - Scroll Position Tracker

    /// A preference key to track scroll position relative to content
    struct ScrollOffsetPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    /// A view modifier that tracks scroll position and shows/hides the scroll-to-bottom button
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
        /// Tracks scroll position for scroll-to-bottom button visibility
        func trackScrollPosition(showButton: Binding<Bool>, threshold: CGFloat = 100) -> some View {
            modifier(ScrollToBottomModifier(showButton: showButton, threshold: threshold))
        }
    }
#endif

// MARK: - macOS Version (Placeholder)

#if os(macOS)
    /// macOS version - simplified since macOS has native scroll behavior
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
