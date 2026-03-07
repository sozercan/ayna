@testable import Ayna
import Foundation
import Testing

@Suite("ConversationPersistenceCoordinator Tests", .tags(.persistence, .async), .serialized)
struct ConversationPersistenceCoordinatorTests {
    @Test("Flush pending saves persists all queued conversations")
    func flushPendingSavesPersistsAllQueuedConversations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )

        await coordinator.enqueueSave(TestHelpers.sampleConversation(title: "Alpha"))
        await coordinator.enqueueSave(TestHelpers.sampleConversation(title: "Beta"))
        await coordinator.flushPendingSaves()

        let loaded = try await store.loadConversations()
        #expect(Set(loaded.map(\.title)) == Set(["Alpha", "Beta"]))
    }

    @Test("Flush pending saves keeps the latest enqueued version")
    func flushPendingSavesKeepsLatestVersion() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let coordinator = ConversationPersistenceCoordinator(
            store: store,
            debounceDuration: .seconds(10)
        )

        let conversationId = UUID()
        let original = TestHelpers.sampleConversation(id: conversationId, title: "Original")
        var updated = original
        updated.title = "Updated"

        await coordinator.enqueueSave(original)
        await coordinator.enqueueSave(updated)
        await coordinator.flushPendingSaves()

        let loaded = try await store.loadConversations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Updated")
    }
}
