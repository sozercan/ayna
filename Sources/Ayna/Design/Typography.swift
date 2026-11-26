import SwiftUI

public enum Typography {
    public enum Size {
        public static var xs: CGFloat {
            #if os(watchOS)
                8
            #else
                9
            #endif
        }

        public static var sm: CGFloat {
            #if os(watchOS)
                10
            #else
                11
            #endif
        }

        public static var caption: CGFloat {
            #if os(watchOS)
                11
            #else
                12
            #endif
        }

        public static var body: CGFloat {
            #if os(watchOS)
                13
            #else
                14
            #endif
        }

        public static var standard: CGFloat {
            #if os(watchOS)
                14
            #else
                15
            #endif
        }

        public static var subheadline: CGFloat {
            #if os(watchOS)
                15
            #else
                16
            #endif
        }

        public static var headline: CGFloat {
            #if os(watchOS)
                16
            #else
                18
            #endif
        }

        public static var title3: CGFloat {
            #if os(watchOS)
                18
            #else
                20
            #endif
        }

        public static var title2: CGFloat {
            #if os(watchOS)
                20
            #else
                22
            #endif
        }

        public static var title1: CGFloat {
            #if os(watchOS)
                24
            #else
                28
            #endif
        }

        public static var hero: CGFloat {
            #if os(watchOS)
                32
            #else
                48
            #endif
        }
    }

    public static var title1: Font {
        .title.weight(.bold)
    }

    public static var title2: Font {
        .title2.weight(.semibold)
    }

    public static var title3: Font {
        .title3.weight(.semibold)
    }

    public static var headline: Font {
        .headline
    }

    public static var subheadline: Font {
        .subheadline.weight(.medium)
    }

    public static var body: Font {
        .body
    }

    public static var bodySecondary: Font {
        .callout
    }

    public static var caption: Font {
        .caption
    }

    public static var captionBold: Font {
        .caption.weight(.semibold)
    }

    public static var footnote: Font {
        .footnote
    }

    public static var micro: Font {
        .caption2
    }

    public static var code: Font {
        .system(.caption, design: .monospaced)
    }

    public static var codeBlock: Font {
        .system(.callout, design: .monospaced)
    }

    public static var rounded: Font {
        .system(.callout, design: .rounded, weight: .medium)
    }

    public static var modelName: Font {
        .caption.weight(.medium)
    }

    public static var timestamp: Font {
        .caption2.weight(.medium)
    }

    public static var button: Font {
        .body.weight(.semibold)
    }

    public static var buttonSmall: Font {
        .caption.weight(.medium)
    }

    public static let bodyLineSpacing: CGFloat = 4
}

public extension View {
    func bodyText() -> some View {
        font(Typography.body)
            .lineSpacing(Typography.bodyLineSpacing)
    }

    func captionText() -> some View {
        font(Typography.caption)
            .foregroundStyle(Theme.textSecondary)
    }

    func headlineText() -> some View {
        font(Typography.headline)
    }

    func codeText() -> some View {
        font(Typography.code)
    }
}

public extension Typography {
    enum IconSize {
        public static let xs: CGFloat = 12

        public static let sm: CGFloat = 14

        public static let md: CGFloat = 16

        public static let lg: CGFloat = 20

        public static let xl: CGFloat = 24

        public static let hero: CGFloat = 48

        public static let heroLarge: CGFloat = 60
    }
}
