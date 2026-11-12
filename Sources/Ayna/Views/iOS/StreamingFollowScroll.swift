// swiftformat:options --ifdef no-indent
#if os(iOS)
//
//  StreamingFollowScroll.swift
//  Ayna
//
//  Keeps a growing reply in view until the user scrolls away from the end.
//

import SwiftUI

/// Tracks whether a transcript should keep following the newest text.
///
/// Uses scroll position, not row visibility: a lazy row's onAppear/onDisappear fires unreliably
/// while streaming content grows. Only the user's own scrolling (interacting or decelerating)
/// stops following, because content growing under a stream also leaves the end briefly.
struct StreamingFollowScroll: ViewModifier {
    @Binding var followsLatest: Bool
    @Binding var isAwayFromEnd: Bool
    @State private var phase: ScrollPhase = .idle

    /// How close to the end still counts as "at the end".
    static let tolerance: CGFloat = 60

    static func isAtEnd(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
    }

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in
                phase = newPhase
                // Growth can leave the end without a geometry change after the drag starts,
                // so a drag that begins away from the end stops following right away.
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

/// Hands the reader's place from the new-chat transcript to the conversation view that
/// replaces it when the first reply finishes, so a reader who scrolled up stays put.
@MainActor
enum TranscriptReadingPosition {
    private static var pending: (conversationId: UUID, messageId: UUID)?

    static func handOver(_ messageId: UUID, in conversationId: UUID) {
        pending = (conversationId, messageId)
    }

    /// The message to show at the top, once, if this conversation was handed a position.
    static func take(for conversationId: UUID) -> UUID? {
        guard let handoff = pending, handoff.conversationId == conversationId else { return nil }
        pending = nil
        return handoff.messageId
    }
}

extension View {
    func followsStreamingContent(_ followsLatest: Binding<Bool>, isAwayFromEnd: Binding<Bool>) -> some View {
        modifier(StreamingFollowScroll(followsLatest: followsLatest, isAwayFromEnd: isAwayFromEnd))
    }
}
#endif
