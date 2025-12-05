//
//  Spacing.swift
//  ayna
//
//  Design System: Spacing & Layout Constants
//  Consistent spacing values and layout measurements across platforms.
//

import SwiftUI

// MARK: - Spacing

/// Centralized spacing and layout constants for the Ayna design system.
/// Uses a 4pt base grid for consistency.
public enum Spacing {
    // MARK: - Base Grid (4pt)

    /// 2pt - Hairline spacing
    public static let xxxs: CGFloat = 2

    /// 4pt - Minimal spacing
    public static let xxs: CGFloat = 4

    /// 6pt - Tight spacing
    public static let xs: CGFloat = 6

    /// 8pt - Compact spacing
    public static let sm: CGFloat = 8

    /// 12pt - Standard small spacing
    public static let md: CGFloat = 12

    /// 16pt - Standard spacing
    public static let lg: CGFloat = 16

    /// 20pt - Comfortable spacing
    public static let xl: CGFloat = 20

    /// 24pt - Generous spacing
    public static let xxl: CGFloat = 24

    /// 32pt - Section spacing
    public static let xxxl: CGFloat = 32

    /// 48pt - Large section spacing
    public static let huge: CGFloat = 48

    // MARK: - Platform-Adaptive Spacing

    /// Standard content padding
    public static var contentPadding: CGFloat {
        #if os(watchOS)
            8
        #elseif os(iOS)
            16
        #else
            24
        #endif
    }

    /// Horizontal padding for message bubbles
    public static var bubblePaddingH: CGFloat {
        #if os(watchOS)
            12
        #else
            18
        #endif
    }

    /// Vertical padding for message bubbles
    public static var bubblePaddingV: CGFloat {
        #if os(watchOS)
            8
        #else
            12
        #endif
    }

    /// Spacing between messages in list
    public static var messageSpacing: CGFloat {
        #if os(watchOS)
            8
        #else
            12
        #endif
    }

    /// Spacing between sections
    public static var sectionSpacing: CGFloat {
        #if os(watchOS)
            16
        #else
            24
        #endif
    }

    /// Minimum touch target size (accessibility)
    public static var minTouchTarget: CGFloat {
        #if os(watchOS)
            38
        #else
            44
        #endif
    }

    // MARK: - Corner Radii

    public enum CornerRadius {
        /// Small radius: 4pt (tags, small badges)
        public static let xs: CGFloat = 4

        /// Compact radius: 6pt (inline elements)
        public static let sm: CGFloat = 6

        /// Standard radius: 8pt (cards, inputs)
        public static let md: CGFloat = 8

        /// Medium radius: 10pt (popovers)
        public static let lg: CGFloat = 10

        /// Large radius: 12pt (modals, sheets)
        public static let xl: CGFloat = 12

        /// Extra large: 16pt (message bubbles on watch)
        public static let xxl: CGFloat = 16

        /// Message bubble radius: 18pt (iOS/macOS)
        public static let bubble: CGFloat = 18

        /// Pill/capsule: 20pt
        public static let pill: CGFloat = 20

        /// Full capsule (half of height)
        public static let capsule: CGFloat = 999
    }

    // MARK: - Component Sizes

    public enum Component {
        /// Avatar size in sidebar
        public static var avatarSize: CGFloat {
            #if os(watchOS)
                32
            #else
                44
            #endif
        }

        /// Small avatar/icon container
        public static let avatarSmall: CGFloat = 32

        /// Status indicator dot
        public static let statusDot: CGFloat = 8

        /// Small status indicator
        public static let statusDotSmall: CGFloat = 6

        /// Icon button size
        public static var iconButton: CGFloat {
            #if os(watchOS)
                32
            #else
                36
            #endif
        }

        /// Toolbar button size
        public static let toolbarButton: CGFloat = 28

        /// Composer minimum height
        public static var composerMinHeight: CGFloat {
            #if os(watchOS)
                28
            #else
                44
            #endif
        }

        /// Composer maximum height
        public static var composerMaxHeight: CGFloat {
            #if os(watchOS)
                80
            #else
                220
            #endif
        }

        /// Sidebar width (macOS)
        public static let sidebarMinWidth: CGFloat = 260
        public static let sidebarIdealWidth: CGFloat = 280
        public static let sidebarMaxWidth: CGFloat = 320

        /// Message bubble maximum width
        public static var bubbleMaxWidth: CGFloat {
            #if os(watchOS)
                140
            #elseif os(iOS)
                300
            #else
                480
            #endif
        }

        /// Message bubble minimum width for user messages (for short text)
        public static let bubbleMinWidth: CGFloat = 60
    }

    // MARK: - Borders & Strokes

    public enum Border {
        /// Hairline border: 0.5pt
        public static let hairline: CGFloat = 0.5

        /// Standard border: 1pt
        public static let standard: CGFloat = 1

        /// Emphasized border: 1.5pt
        public static let emphasized: CGFloat = 1.5

        /// Thick border: 2pt
        public static let thick: CGFloat = 2

        /// Focus ring: 3pt
        public static let focusRing: CGFloat = 3
    }

    // MARK: - Shadow Specs

    public enum Shadow {
        /// Subtle shadow radius
        public static let radiusSubtle: CGFloat = 4

        /// Standard shadow radius
        public static let radiusStandard: CGFloat = 8

        /// Elevated shadow radius
        public static let radiusElevated: CGFloat = 16

        /// Standard shadow Y offset
        public static let offsetY: CGFloat = 2

        /// Elevated shadow Y offset
        public static let offsetYElevated: CGFloat = 4
    }
}

// MARK: - View Extensions

public extension View {
    /// Applies standard content padding
    func contentPadding() -> some View {
        padding(Spacing.contentPadding)
    }

    /// Applies horizontal content padding
    func contentPaddingH() -> some View {
        padding(.horizontal, Spacing.contentPadding)
    }

    /// Applies standard bubble padding
    func bubblePadding() -> some View {
        padding(.horizontal, Spacing.bubblePaddingH)
            .padding(.vertical, Spacing.bubblePaddingV)
    }

    /// Applies standard corner radius
    func standardCornerRadius() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }

    /// Applies bubble corner radius
    func bubbleCornerRadius() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.bubble))
    }
}

// MARK: - Safe Area Helpers

public extension Spacing {
    /// Bottom safe area padding for composer
    static var composerBottomPadding: CGFloat {
        #if os(watchOS)
            4
        #elseif os(iOS)
            8
        #else
            20
        #endif
    }
}
