//
//  Animation.swift
//  ayna
//
//  Design System: Animation Presets
//  Consistent animation timing and spring values across the app.
//

import Combine
import SwiftUI

// MARK: - Motion

/// Centralized animation presets for the Ayna design system.
/// Ensures consistent motion language throughout the app.
public enum Motion {
    // MARK: - Durations

    public enum Duration {
        /// Instant feedback: 0.1s
        public static let instant: Double = 0.1

        /// Quick transitions: 0.15s
        public static let quick: Double = 0.15

        /// Standard transitions: 0.2s
        public static let standard: Double = 0.2

        /// Slow/emphasized transitions: 0.4s
        public static let slow: Double = 0.4
    }

    // MARK: - Spring Presets

    /// Snappy spring for quick interactions (toggles, buttons)
    public static let springSnappy = Animation.spring(response: 0.25, dampingFraction: 0.85)

    /// Standard spring for most UI transitions
    public static let springStandard = Animation.spring(response: 0.3, dampingFraction: 0.8)

    // MARK: - Easing Presets

    /// Standard ease in-out
    public static let easeStandard = Animation.easeInOut(duration: Duration.standard)

    /// Quick ease for hover states
    public static let easeQuick = Animation.easeInOut(duration: Duration.quick)

    /// Ease out for entering elements
    public static let easeOut = Animation.easeOut(duration: Duration.standard)

    /// Ease in for exiting elements
    public static let easeIn = Animation.easeIn(duration: Duration.standard)
}

// MARK: - Typing Dots Animation

/// Animated typing dots component - iMessage style wave animation
/// Dots rise and fall sequentially for a natural "thinking" effect
public struct TypingDotsView: View {
    @State private var animatingDot = 0
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Theme.textSecondary.opacity(0.6))
                    .frame(width: 8, height: 8)
                    // Wave animation: Y offset instead of scale for iMessage feel
                    .offset(y: offsetForDot(at: index))
                    .animation(
                        .easeInOut(duration: 0.3),
                        value: animatingDot
                    )
            }
        }
        .onReceive(timer) { _ in
            animatingDot = (animatingDot + 1) % 6
        }
    }

    /// Calculate Y offset for wave effect
    /// Each dot rises when it's "active" in the wave sequence
    private func offsetForDot(at index: Int) -> CGFloat {
        // Wave pattern: dot rises when animatingDot matches its turn
        // Sequence: 0,1,2,2,1,0 creates smooth wave
        let activeIndex: Int = switch animatingDot {
        case 0, 5:
            0
        case 1, 4:
            1
        case 2, 3:
            2
        default:
            -1
        }
        return index == activeIndex ? -4 : 0
    }
}
