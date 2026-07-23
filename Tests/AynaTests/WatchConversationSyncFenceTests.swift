@testable import Ayna
import Foundation
import Testing

@Suite("Watch Conversation Sync Fence Tests", .tags(.fast))
struct WatchConversationSyncFenceTests {
    @Test
    func `watch mutations require an established phone epoch`() {
        #expect(!WatchConversationSyncFence.canInitiateMutation(currentEpoch: nil))
        #expect(WatchConversationSyncFence.canInitiateMutation(currentEpoch: UUID()))
    }

    @Test
    func `conversation mutations require epoch generation and no pending clear`() {
        let epoch = UUID()
        #expect(WatchConversationSyncFence.acceptsMutation(
            incomingEpoch: epoch,
            incomingGeneration: 4,
            currentEpoch: epoch,
            currentGeneration: 4,
            pendingClearCount: 0
        ))
        #expect(!WatchConversationSyncFence.acceptsMutation(
            incomingEpoch: epoch,
            incomingGeneration: 4,
            currentEpoch: epoch,
            currentGeneration: 4,
            pendingClearCount: 1
        ))
        #expect(!WatchConversationSyncFence.acceptsMutation(
            incomingEpoch: UUID(),
            incomingGeneration: 4,
            currentEpoch: epoch,
            currentGeneration: 4,
            pendingClearCount: 0
        ))
        #expect(!WatchConversationSyncFence.acceptsMutation(
            incomingEpoch: epoch,
            incomingGeneration: 3,
            currentEpoch: epoch,
            currentGeneration: 4,
            pendingClearCount: 0
        ))
        #expect(WatchConversationSyncFence.acceptsMutation(
            incomingEpoch: nil,
            incomingGeneration: nil,
            currentEpoch: epoch,
            currentGeneration: 0,
            pendingClearCount: 0
        ))
        #expect(!WatchConversationSyncFence.acceptsMutation(
            incomingEpoch: nil,
            incomingGeneration: nil,
            currentEpoch: epoch,
            currentGeneration: 1,
            pendingClearCount: 0
        ))
    }

    @Test
    func `legacy phone context is accepted before an epoch is established`() {
        #expect(WatchConversationSyncFence.acceptsContext(
            incomingEpoch: nil,
            incomingGeneration: nil,
            currentEpoch: nil,
            currentGeneration: 0
        ))
    }

    @Test
    func `new phone epoch authoritatively rebases the watch`() {
        let oldEpoch = UUID()
        let newEpoch = UUID()

        #expect(WatchConversationSyncFence.acceptsContext(
            incomingEpoch: newEpoch,
            incomingGeneration: 0,
            currentEpoch: oldEpoch,
            currentGeneration: 9
        ))
        #expect(WatchConversationSyncFence.contextRequiresAuthoritativeReset(
            incomingEpoch: newEpoch,
            incomingGeneration: 0,
            currentEpoch: oldEpoch,
            currentGeneration: 9
        ))
    }

    @Test
    func `same epoch contexts may advance but never rewind`() {
        let epoch = UUID()
        #expect(WatchConversationSyncFence.acceptsContext(
            incomingEpoch: epoch,
            incomingGeneration: 5,
            currentEpoch: epoch,
            currentGeneration: 4
        ))
        #expect(!WatchConversationSyncFence.acceptsContext(
            incomingEpoch: epoch,
            incomingGeneration: 3,
            currentEpoch: epoch,
            currentGeneration: 4
        ))
        #expect(WatchConversationSyncFence.contextRequiresAuthoritativeReset(
            incomingEpoch: epoch,
            incomingGeneration: 5,
            currentEpoch: epoch,
            currentGeneration: 4
        ))
    }
}
