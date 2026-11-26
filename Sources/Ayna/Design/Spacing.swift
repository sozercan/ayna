import SwiftUI

public enum Spacing {
    public static let xxxs: CGFloat = 2

    public static let xxs: CGFloat = 4

    public static let xs: CGFloat = 6

    public static let sm: CGFloat = 8

    public static let md: CGFloat = 12

    public static let lg: CGFloat = 16

    public static let xl: CGFloat = 20

    public static let xxl: CGFloat = 24

    public static let xxxl: CGFloat = 32

    public static let huge: CGFloat = 48

    public static var contentPadding: CGFloat {
        #if os(watchOS)
            8
        #elseif os(iOS)
            16
        #else
            24
        #endif
    }

    public static var bubblePaddingH: CGFloat {
        #if os(watchOS)
            12
        #else
            18
        #endif
    }

    public static var bubblePaddingV: CGFloat {
        #if os(watchOS)
            8
        #else
            12
        #endif
    }

    public static var messageSpacing: CGFloat {
        #if os(watchOS)
            8
        #else
            12
        #endif
    }

    public static var minTouchTarget: CGFloat {
        #if os(watchOS)
            38
        #else
            44
        #endif
    }

    public enum CornerRadius {
        public static let xs: CGFloat = 4

        public static let sm: CGFloat = 6

        public static let md: CGFloat = 8

        public static let lg: CGFloat = 10

        public static let xl: CGFloat = 12

        public static let xxl: CGFloat = 16

        public static let bubble: CGFloat = 18

        public static let pill: CGFloat = 20

        public static let capsule: CGFloat = 999
    }

    public enum Component {
        public static var avatarSize: CGFloat {
            #if os(watchOS)
                32
            #else
                44
            #endif
        }

        public static let avatarSmall: CGFloat = 32

        public static let statusDot: CGFloat = 8

        public static let statusDotSmall: CGFloat = 6

        public static var iconButton: CGFloat {
            #if os(watchOS)
                32
            #else
                36
            #endif
        }

        public static let sidebarMinWidth: CGFloat = 260
        public static let sidebarIdealWidth: CGFloat = 280
        public static let sidebarMaxWidth: CGFloat = 320

        public static var bubbleMaxWidth: CGFloat {
            #if os(watchOS)
                140
            #elseif os(iOS)
                300
            #else
                480
            #endif
        }

        public static let bubbleMinWidth: CGFloat = 60
    }

    public enum Border {
        public static let hairline: CGFloat = 0.5

        public static let standard: CGFloat = 1

        public static let emphasized: CGFloat = 1.5

        public static let thick: CGFloat = 2
    }

    public enum Shadow {
        public static let radiusSubtle: CGFloat = 4

        public static let radiusStandard: CGFloat = 8

        public static let offsetY: CGFloat = 2

        public static let offsetYElevated: CGFloat = 4
    }
}

public extension View {
    func contentPadding() -> some View {
        padding(Spacing.contentPadding)
    }

    func contentPaddingH() -> some View {
        padding(.horizontal, Spacing.contentPadding)
    }

    func bubblePadding() -> some View {
        padding(.horizontal, Spacing.bubblePaddingH)
            .padding(.vertical, Spacing.bubblePaddingV)
    }

    func standardCornerRadius() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }

    func bubbleCornerRadius() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.bubble))
    }
}

public extension Spacing {
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
