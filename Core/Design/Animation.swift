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

        /// Comfortable transitions: 0.3s
        public static let comfortable: Double = 0.3

        /// Slow/emphasized transitions: 0.4s
        public static let slow: Double = 0.4

        /// Very slow/cinematic: 0.5s
        public static let verySlow: Double = 0.5
    }

    // MARK: - Spring Presets

    /// Snappy spring for quick interactions (toggles, buttons)
    public static let springSnappy = Animation.spring(response: 0.25, dampingFraction: 0.85)

    /// Standard spring for most UI transitions
    public static let springStandard = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Gentle spring for larger movements (sheets, modals)
    public static let springGentle = Animation.spring(response: 0.4, dampingFraction: 0.75)

    /// Bouncy spring for playful interactions
    public static let springBouncy = Animation.spring(response: 0.35, dampingFraction: 0.65)

    /// Stiff spring for quick snaps
    public static let springStiff = Animation.spring(response: 0.2, dampingFraction: 0.9)

    // MARK: - Easing Presets

    /// Standard ease in-out
    public static let easeStandard = Animation.easeInOut(duration: Duration.standard)

    /// Quick ease for hover states
    public static let easeQuick = Animation.easeInOut(duration: Duration.quick)

    /// Slow ease for emphasis
    public static let easeSlow = Animation.easeInOut(duration: Duration.slow)

    /// Ease out for entering elements
    public static let easeOut = Animation.easeOut(duration: Duration.standard)

    /// Ease in for exiting elements
    public static let easeIn = Animation.easeIn(duration: Duration.standard)

    // MARK: - Semantic Animations

    /// Message bubble appearance
    public static let messageAppear = springStandard

    /// Message bubble content update (streaming)
    public static let messageUpdate = Animation.easeOut(duration: Duration.instant)

    /// Typing indicator
    public static let typingIndicator = Animation.easeInOut(duration: Duration.slow).repeatForever()

    /// Button press
    public static let buttonPress = springSnappy

    /// Hover state change
    public static let hover = easeQuick

    /// Expand/collapse
    public static let expandCollapse = springStandard

    /// Sheet presentation
    public static let sheetPresent = springGentle

    /// Scroll position changes
    public static let scrollAnchor = springStiff

    /// Error shake
    public static let errorShake = Animation.spring(response: 0.15, dampingFraction: 0.3)

    /// Success pulse
    public static let successPulse = springBouncy

    // MARK: - Transitions

    /// Standard opacity transition
    @MainActor
    public static var fadeTransition: AnyTransition {
        AnyTransition.opacity
    }

    /// Scale + fade for popovers
    @MainActor
    public static var scaleTransition: AnyTransition {
        AnyTransition.opacity.combined(with: .scale(scale: 0.95))
    }

    /// Slide from bottom (sheets)
    @MainActor
    public static var slideUpTransition: AnyTransition {
        AnyTransition.move(edge: .bottom).combined(with: .opacity)
    }

    /// Slide from top (notifications)
    @MainActor
    public static var slideDownTransition: AnyTransition {
        AnyTransition.move(edge: .top).combined(with: .opacity)
    }

    /// Message appearance transition
    @MainActor
    public static var messageTransition: AnyTransition {
        AnyTransition.opacity.combined(with: .scale(scale: 0.98))
    }
}

// MARK: - View Modifiers

public extension View {
    /// Applies standard animation to a value change
    func animateStandard(value: some Equatable) -> some View {
        animation(Motion.springStandard, value: value)
    }

    /// Applies quick animation to a value change
    func animateQuick(value: some Equatable) -> some View {
        animation(Motion.easeQuick, value: value)
    }

    /// Applies snappy spring animation to a value change
    func animateSnappy(value: some Equatable) -> some View {
        animation(Motion.springSnappy, value: value)
    }

    /// Fades in the view when it appears
    func fadeIn() -> some View {
        transition(Motion.fadeTransition)
    }

    /// Scales in the view when it appears (for popovers)
    func scaleIn() -> some View {
        transition(Motion.scaleTransition)
    }

    /// Slides up when appearing (for sheets)
    func slideUp() -> some View {
        transition(Motion.slideUpTransition)
    }

    /// Applies message appearance transition
    func messageAppearance() -> some View {
        transition(Motion.messageTransition)
    }
}

// MARK: - Shimmer Effect (for loading states)

/// A shimmer modifier for loading/typing states
public struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    public func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.3),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: -geometry.size.width + phase * geometry.size.width * 2)
                }
                .mask(content)
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
    }
}

public extension View {
    /// Applies a shimmer effect for loading states
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Pulse Effect

/// A subtle pulse effect for attention
public struct PulseModifier: ViewModifier {
    let isActive: Bool
    @State private var scale: CGFloat = 1.0

    public func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: isActive) { _, active in
                if active {
                    withAnimation(
                        .easeInOut(duration: 0.8)
                            .repeatForever(autoreverses: true)
                    ) {
                        scale = 1.05
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1.0
                    }
                }
            }
    }
}

public extension View {
    /// Applies a subtle pulse effect when active
    func pulse(isActive: Bool) -> some View {
        modifier(PulseModifier(isActive: isActive))
    }
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
