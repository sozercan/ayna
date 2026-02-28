//
//  Typography.swift
//  ayna
//
//  Design System: Typography Scale
//  Consistent type styles across platforms with semantic naming.
//  Uses Dynamic Type for accessibility compliance on iOS/watchOS.
//  Respects user's text size preferences automatically.
//

import SwiftUI

// MARK: - Typography

/// Centralized typography definitions for the Ayna design system.
/// All fonts use Dynamic Type (Text Styles) for accessibility.
/// Fonts scale automatically based on user's accessibility settings.
public enum Typography {
    // MARK: - Legacy Size Reference (for non-font uses like icons, spacing calculations)

    /// Reference sizes for calculations that need fixed values (icons, spacing).
    /// DO NOT use these for Font - use the semantic Font properties instead.
    public enum Size {
        /// Extra small reference: 9pt (macOS/iOS), 8pt (watchOS)
        public static var xs: CGFloat {
            #if os(watchOS)
                8
            #else
                9
            #endif
        }

        /// Small reference: 11pt (macOS/iOS), 10pt (watchOS)
        public static var sm: CGFloat {
            #if os(watchOS)
                10
            #else
                11
            #endif
        }

        /// Caption reference: 12pt (macOS/iOS), 11pt (watchOS)
        public static var caption: CGFloat {
            #if os(watchOS)
                11
            #else
                12
            #endif
        }

        /// Body reference: 14pt (macOS/iOS), 13pt (watchOS)
        public static var body: CGFloat {
            #if os(watchOS)
                13
            #else
                14
            #endif
        }

        /// Standard reference: 15pt (macOS/iOS), 14pt (watchOS)
        public static var standard: CGFloat {
            #if os(watchOS)
                14
            #else
                15
            #endif
        }

        /// Subheadline reference: 16pt (macOS/iOS), 15pt (watchOS)
        public static var subheadline: CGFloat {
            #if os(watchOS)
                15
            #else
                16
            #endif
        }

        /// Headline reference: 18pt (macOS/iOS), 16pt (watchOS)
        public static var headline: CGFloat {
            #if os(watchOS)
                16
            #else
                18
            #endif
        }

        /// Title 3 reference: 20pt (macOS/iOS), 18pt (watchOS)
        public static var title3: CGFloat {
            #if os(watchOS)
                18
            #else
                20
            #endif
        }

        /// Title 2 reference: 22pt (macOS/iOS), 20pt (watchOS)
        public static var title2: CGFloat {
            #if os(watchOS)
                20
            #else
                22
            #endif
        }

        /// Title 1 reference: 28pt (macOS/iOS), 24pt (watchOS)
        public static var title1: CGFloat {
            #if os(watchOS)
                24
            #else
                28
            #endif
        }

        /// Large Title reference: 34pt (macOS/iOS), 28pt (watchOS)
        public static var largeTitle: CGFloat {
            #if os(watchOS)
                28
            #else
                34
            #endif
        }

        /// Hero reference: 48pt (macOS/iOS), 32pt (watchOS)
        public static var hero: CGFloat {
            #if os(watchOS)
                32
            #else
                48
            #endif
        }
    }

    // MARK: - Semantic Text Styles (Dynamic Type)

    // These fonts automatically scale with user's accessibility settings

    /// Large title for hero sections - scales with Dynamic Type
    public static var largeTitle: Font {
        .largeTitle.weight(.bold)
    }

    /// Primary title - scales with Dynamic Type
    public static var title1: Font {
        .title.weight(.bold)
    }

    /// Secondary title - scales with Dynamic Type
    public static var title2: Font {
        .title2.weight(.semibold)
    }

    /// Tertiary title - scales with Dynamic Type
    public static var title3: Font {
        .title3.weight(.semibold)
    }

    /// Section headline - scales with Dynamic Type
    public static var headline: Font {
        .headline
    }

    /// Subheadline / emphasized body - scales with Dynamic Type
    public static var subheadline: Font {
        .subheadline.weight(.medium)
    }

    /// Standard body text (used in message bubbles) - scales with Dynamic Type
    public static var body: Font {
        .body
    }

    /// Secondary body text (slightly smaller) - scales with Dynamic Type
    public static var bodySecondary: Font {
        .callout
    }

    /// Caption text - scales with Dynamic Type
    public static var caption: Font {
        .caption
    }

    /// Caption with emphasis - scales with Dynamic Type
    public static var captionBold: Font {
        .caption.weight(.semibold)
    }

    /// Small auxiliary text - scales with Dynamic Type
    public static var footnote: Font {
        .footnote
    }

    /// Extra small text (timestamps, badges) - scales with Dynamic Type
    public static var micro: Font {
        .caption2
    }

    // MARK: - Special Styles (Dynamic Type with design variants)

    /// Code/monospaced text - scales with Dynamic Type
    public static var code: Font {
        .system(.caption, design: .monospaced)
    }

    /// Code block text (slightly larger) - scales with Dynamic Type
    public static var codeBlock: Font {
        .system(.callout, design: .monospaced)
    }

    /// Rounded style for friendly elements (buttons, badges) - scales with Dynamic Type
    public static var rounded: Font {
        .system(.callout, design: .rounded, weight: .medium)
    }

    /// Rounded caption - scales with Dynamic Type
    public static var roundedCaption: Font {
        .system(.caption, design: .rounded, weight: .medium)
    }

    /// Model/provider name display - scales with Dynamic Type
    public static var modelName: Font {
        .caption.weight(.medium)
    }

    /// Timestamp display - scales with Dynamic Type
    public static var timestamp: Font {
        .caption2.weight(.medium)
    }

    /// Button text - scales with Dynamic Type
    public static var button: Font {
        .body.weight(.semibold)
    }

    /// Small button text - scales with Dynamic Type
    public static var buttonSmall: Font {
        .caption.weight(.medium)
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

public extension View {
    /// Applies the standard body text style with Dynamic Type support
    func bodyText() -> some View {
        font(Typography.body)
            .lineSpacing(Typography.bodyLineSpacing)
    }

    /// Applies the caption text style with Dynamic Type support
    func captionText() -> some View {
        font(Typography.caption)
            .foregroundStyle(Theme.textSecondary)
    }

    /// Applies the headline text style with Dynamic Type support
    func headlineText() -> some View {
        font(Typography.headline)
    }

    /// Applies the code text style with Dynamic Type support
    func codeText() -> some View {
        font(Typography.code)
    }
}

// MARK: - Icon Sizes

public extension Typography {
    /// Consistent icon sizes that pair well with text.
    /// Note: Icons use fixed sizes as SF Symbols scale independently via symbolRenderingMode.
    enum IconSize {
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
