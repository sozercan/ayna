import Combine
import SwiftUI

public enum Motion {
    public enum Duration {
        public static let instant: Double = 0.1

        public static let quick: Double = 0.15

        public static let standard: Double = 0.2

        public static let slow: Double = 0.4
    }

    public static let springSnappy = Animation.spring(response: 0.25, dampingFraction: 0.85)

    public static let springStandard = Animation.spring(response: 0.3, dampingFraction: 0.8)

    public static let easeStandard = Animation.easeInOut(duration: Duration.standard)

    public static let easeQuick = Animation.easeInOut(duration: Duration.quick)

    public static let easeOut = Animation.easeOut(duration: Duration.standard)

    public static let easeIn = Animation.easeIn(duration: Duration.standard)
}

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

    private func offsetForDot(at index: Int) -> CGFloat {
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
