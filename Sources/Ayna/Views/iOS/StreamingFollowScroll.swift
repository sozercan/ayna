// swiftformat:options --ifdef no-indent
#if os(iOS)

import SwiftUI

struct StreamingFollowScroll: ViewModifier {
    @Binding var followsLatest: Bool
    @Binding var isAwayFromEnd: Bool
    @State private var phase: ScrollPhase = .idle

    static let tolerance: CGFloat = 60

    static func isAtEnd(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
    }

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in
                phase = newPhase
                if newPhase == .interacting || newPhase == .decelerating, isAwayFromEnd {
                    followsLatest = false
                }
            }
            .onScrollGeometryChange(for: Bool.self, of: Self.isAtEnd) { _, isAtEnd in
                isAwayFromEnd = !isAtEnd
                if isAtEnd {
                    followsLatest = true
                } else if phase == .interacting || phase == .decelerating {
                    followsLatest = false
                }
            }
    }
}

@MainActor
enum TranscriptReadingPosition {
    private static var pending: (conversationId: UUID, offset: CGFloat)?

    static func handOver(_ offset: CGFloat, in conversationId: UUID) {
        pending = (conversationId, offset)
    }

    static func take(for conversationId: UUID) -> CGFloat? {
        guard let handoff = pending, handoff.conversationId == conversationId else { return nil }
        pending = nil
        return handoff.offset
    }

    static func offset(of geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }
}

extension View {
    func followsStreamingContent(_ followsLatest: Binding<Bool>, isAwayFromEnd: Binding<Bool>) -> some View {
        modifier(StreamingFollowScroll(followsLatest: followsLatest, isAwayFromEnd: isAwayFromEnd))
    }
}
#endif
