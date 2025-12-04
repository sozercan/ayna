//
//  Typography.swift
//  ayna
//
//  Design System: Typography Scale
//  Consistent type styles across platforms with semantic naming.
//  Uses SF Pro as the system font with platform-appropriate sizing.
//

import SwiftUI

// MARK: - Typography

/// Centralized typography definitions for the Ayna design system.
/// Provides semantic text styles that adapt to each platform.
public enum Typography {

    // MARK: - Type Scale (in points)

    /// Base type scale following a modular scale (1.2 ratio)
    /// watchOS uses smaller sizes, iOS/macOS use standard sizes
    public enum Size {
        /// Extra small: 9pt (macOS/iOS), 8pt (watchOS)
        public static var xs: CGFloat {
            #if os(watchOS)
            8
            #else
            9
            #endif
        }

        /// Small: 11pt (macOS/iOS), 10pt (watchOS)
        public static var sm: CGFloat {
            #if os(watchOS)
            10
            #else
            11
            #endif
        }

        /// Caption: 12pt (macOS/iOS), 11pt (watchOS)
        public static var caption: CGFloat {
            #if os(watchOS)
            11
            #else
            12
            #endif
        }

        /// Body: 14pt (macOS/iOS), 13pt (watchOS)
        public static var body: CGFloat {
            #if os(watchOS)
            13
            #else
            14
            #endif
        }

        /// Standard text: 15pt (macOS/iOS), 14pt (watchOS)
        public static var standard: CGFloat {
            #if os(watchOS)
            14
            #else
            15
            #endif
        }

        /// Subheadline: 16pt (macOS/iOS), 15pt (watchOS)
        public static var subheadline: CGFloat {
            #if os(watchOS)
            15
            #else
            16
            #endif
        }

        /// Headline: 18pt (macOS/iOS), 16pt (watchOS)
        public static var headline: CGFloat {
            #if os(watchOS)
            16
            #else
            18
            #endif
        }

        /// Title 3: 20pt (macOS/iOS), 18pt (watchOS)
        public static var title3: CGFloat {
            #if os(watchOS)
            18
            #else
            20
            #endif
        }

        /// Title 2: 22pt (macOS/iOS), 20pt (watchOS)
        public static var title2: CGFloat {
            #if os(watchOS)
            20
            #else
            22
            #endif
        }

        /// Title 1: 28pt (macOS/iOS), 24pt (watchOS)
        public static var title1: CGFloat {
            #if os(watchOS)
            24
            #else
            28
            #endif
        }

        /// Large Title: 34pt (macOS/iOS), 28pt (watchOS)
        public static var largeTitle: CGFloat {
            #if os(watchOS)
            28
            #else
            34
            #endif
        }

        /// Hero: 48pt (macOS/iOS), not used on watchOS
        public static var hero: CGFloat {
            #if os(watchOS)
            32
            #else
            48
            #endif
        }
    }

    // MARK: - Semantic Text Styles

    /// Large title for hero sections
    public static var largeTitle: Font {
        .system(size: Size.largeTitle, weight: .bold)
    }

    /// Primary title
    public static var title1: Font {
        .system(size: Size.title1, weight: .bold)
    }

    /// Secondary title
    public static var title2: Font {
        .system(size: Size.title2, weight: .semibold)
    }

    /// Tertiary title
    public static var title3: Font {
        .system(size: Size.title3, weight: .semibold)
    }

    /// Section headline
    public static var headline: Font {
        .system(size: Size.headline, weight: .semibold)
    }

    /// Subheadline / emphasized body
    public static var subheadline: Font {
        .system(size: Size.subheadline, weight: .medium)
    }

    /// Standard body text (used in message bubbles)
    public static var body: Font {
        .system(size: Size.standard)
    }

    /// Secondary body text
    public static var bodySecondary: Font {
        .system(size: Size.body)
    }

    /// Caption text
    public static var caption: Font {
        .system(size: Size.caption)
    }

    /// Caption with emphasis
    public static var captionBold: Font {
        .system(size: Size.caption, weight: .semibold)
    }

    /// Small auxiliary text
    public static var footnote: Font {
        .system(size: Size.sm)
    }

    /// Extra small text (timestamps, badges)
    public static var micro: Font {
        .system(size: Size.xs)
    }

    // MARK: - Special Styles

    /// Code/monospaced text
    public static var code: Font {
        .system(size: Size.caption, design: .monospaced)
    }

    /// Code block text (slightly larger)
    public static var codeBlock: Font {
        .system(size: Size.body, design: .monospaced)
    }

    /// Rounded style for friendly elements (buttons, badges)
    public static var rounded: Font {
        .system(size: Size.body, weight: .medium, design: .rounded)
    }

    /// Rounded caption
    public static var roundedCaption: Font {
        .system(size: Size.caption, weight: .medium, design: .rounded)
    }

    /// Model/provider name display
    public static var modelName: Font {
        .system(size: Size.caption, weight: .medium)
    }

    /// Timestamp display
    public static var timestamp: Font {
        .system(size: Size.sm, weight: .medium)
    }

    /// Button text
    public static var button: Font {
        .system(size: Size.body, weight: .semibold)
    }

    /// Small button text
    public static var buttonSmall: Font {
        .system(size: Size.caption, weight: .medium)
    }

    // MARK: - Line Spacing

    /// Standard line spacing for body text
    public static let bodyLineSpacing: CGFloat = 4

    /// Tight line spacing for compact displays
    public static let tightLineSpacing: CGFloat = 2

    /// Loose line spacing for readability
    public static let looseLineSpacing: CGFloat = 6
}

// MARK: - View Modifiers

extension View {
    /// Applies the standard body text style
    public func bodyText() -> some View {
        self
            .font(Typography.body)
            .lineSpacing(Typography.bodyLineSpacing)
    }

    /// Applies the caption text style
    public func captionText() -> some View {
        self
            .font(Typography.caption)
            .foregroundStyle(Theme.textSecondary)
    }

    /// Applies the headline text style
    public func headlineText() -> some View {
        self
            .font(Typography.headline)
    }

    /// Applies the code text style
    public func codeText() -> some View {
        self
            .font(Typography.code)
    }
}

// MARK: - Icon Sizes

extension Typography {
    /// Consistent icon sizes that pair well with text
    public enum IconSize {
        /// Inline with caption text: 12pt
        public static let xs: CGFloat = 12

        /// Inline with body text: 14pt
        public static let sm: CGFloat = 14

        /// Standard icon: 16pt
        public static let md: CGFloat = 16

        /// Emphasized icon: 20pt
        public static let lg: CGFloat = 20

        /// Large icon: 24pt
        public static let xl: CGFloat = 24

        /// Hero/empty state icon: 48pt
        public static let hero: CGFloat = 48

        /// Large hero icon: 60pt
        public static let heroLarge: CGFloat = 60
    }
}
