@testable import Ayna
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
}
