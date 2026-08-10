@testable import Ayna
import Foundation
import Testing

@Suite("Watch Chat Request Ownership Tests", .tags(.fast))
struct WatchChatRequestOwnershipTests {
    @Test
    func `stale request cannot finish replacement request`() {
        var ownership = WatchChatRequestOwnership()
        let staleRequestID = ownership.begin()
        let replacementRequestID = ownership.begin()
        let staleRequestFinished = ownership.finish(ifOwnedBy: staleRequestID)

        #expect(!staleRequestFinished)
        #expect(ownership.owns(replacementRequestID))
        let replacementRequestFinished = ownership.finish(ifOwnedBy: replacementRequestID)
        #expect(replacementRequestFinished)
        #expect(ownership.activeRequestID == nil)
    }

    @Test
    func `invalidation rejects callbacks from the previous request`() {
        var ownership = WatchChatRequestOwnership()
        let requestID = ownership.begin()
        let invalidatedRequestID = ownership.invalidate()

        #expect(invalidatedRequestID == requestID)
        #expect(!ownership.owns(requestID))
        let invalidatedRequestFinished = ownership.finish(ifOwnedBy: requestID)
        #expect(!invalidatedRequestFinished)
    }

    @Test
    func `same-conversation refresh preserves the active request`() {
        let conversationID = UUID()
        var ownership = WatchChatRequestOwnership()
        let requestID = ownership.begin()
        var transitionEvents: [String] = []

        let shouldReset = ownership.prepareForConversationSelection(
            currentConversationID: conversationID,
            selectedConversationID: conversationID,
            flush: { transitionEvents.append("flush") },
            persist: { transitionEvents.append("persist") },
            cancel: { _ in transitionEvents.append("cancel") }
        )

        #expect(!shouldReset)
        #expect(transitionEvents.isEmpty)
        #expect(ownership.owns(requestID))
    }

    @Test
    func `conversation switch flushes and cancels before invalidating the request`() {
        let currentConversationID = UUID()
        let selectedConversationID = UUID()
        var ownership = WatchChatRequestOwnership()
        let requestID = ownership.begin()
        var transitionEvents: [String] = []
        var cancelledRequestID: UUID?

        let shouldReset = ownership.prepareForConversationSelection(
            currentConversationID: currentConversationID,
            selectedConversationID: selectedConversationID,
            flush: { transitionEvents.append("flush") },
            persist: { transitionEvents.append("persist") },
            cancel: { id in
                transitionEvents.append("cancel")
                cancelledRequestID = id
            }
        )

        #expect(shouldReset)
        #expect(transitionEvents == ["flush", "persist", "cancel"])
        #expect(cancelledRequestID == requestID)
        #expect(ownership.activeRequestID == nil)
    }
}
