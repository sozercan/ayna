// swiftlint:disable identifier_name
@testable import Ayna
import Foundation
import Testing

@Suite("Watch durable sync tests", .serialized)
struct WatchDurableSyncTests {
    @MainActor
    private func makeLoadedManager(with stored: [Conversation]) async throws -> ConversationManager {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(stored)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupEnabled: false
        )
        _ = await manager.loadingTask?.value
        #expect(manager.isConversationStateAuthoritative)
        return manager
    }

    @Test
    @MainActor
    func `Conversations stored before launch are durable for Watch sync`() async throws {
        let stored = (0 ..< 3).map { index in
            TestHelpers.sampleConversation(title: "Stored \(index)")
        }
        let manager = try await makeLoadedManager(with: stored)

        let snapshot = manager.durableSyncSnapshot()

        // Before the fix only this session's saves counted, so the Watch tombstoned these.
        #expect(Set(snapshot.conversations.map(\.id)) == Set(stored.map(\.id)))
        #expect(snapshot.bodyUnavailableIDs == Set(stored.map(\.id)))
    }

    @Test
    @MainActor
    func `Loading a conversation makes its stored body available for Watch sync`() async throws {
        let stored = TestHelpers.sampleConversation(title: "Hydrated")
        let manager = try await makeLoadedManager(with: [stored])

        _ = await manager.ensureConversationLoaded(stored.id)
        let snapshot = manager.durableSyncSnapshot()

        #expect(snapshot.bodyUnavailableIDs.isEmpty)
        #expect(snapshot.conversations.first?.messages.map(\.id) == stored.messages.map(\.id))
    }

    @Test
    @MainActor
    func `Deleted conversations leave the durable Watch set`() async throws {
        let kept = TestHelpers.sampleConversation(title: "Kept")
        let deleted = TestHelpers.sampleConversation(title: "Deleted")
        let manager = try await makeLoadedManager(with: [kept, deleted])

        let deletion = manager.persistProposedDeletion(conversationID: deleted.id)
        #expect(await deletion.value == .deleted)
        manager.commitPersistedDeletion(deleted.id)

        #expect(manager.durableSyncSnapshot().conversations.map(\.id) == [kept.id])
    }

    @Test
    @MainActor
    func `Watch edits load full history before saving`() async throws {
        let stored = TestHelpers.sampleConversation(title: "Edited from Watch")
        let manager = try await makeLoadedManager(with: [stored])
        #expect(manager.isMetadataOnlyConversation(stored.id))

        #expect(await manager.loadFullHistoryBeforeEdit(stored.id))

        #expect(!manager.isMetadataOnlyConversation(stored.id))
        let inMemory = manager.conversations.first { $0.id == stored.id }
        #expect(inMemory?.messages.map(\.id) == stored.messages.map(\.id))
    }

    @Test
    func `Metadata-only conversations stay in the manifest without a body`() throws {
        let newer = TestHelpers.sampleConversation(title: "Metadata only")
        var older = TestHelpers.sampleConversation(title: "Loaded")
        older.updatedAt = newer.updatedAt.addingTimeInterval(-60)
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 1

        let payload = try WatchSyncPayloadBuilder.build(
            state: PhoneWatchSyncState(
                conversations: [newer, older],
                bodyUnavailableConversationIDs: [newer.id]
            ),
            snapshotRevision: 1,
            configuration: configuration
        )
        let snapshot = try JSONDecoder().decode(WatchSyncSnapshot.self, from: payload.data)

        #expect(snapshot.conversations.map(\.id) == [older.id])
        #expect(Set(snapshot.authoritativeConversationIDs) == [newer.id, older.id])
    }
}

// swiftlint:enable identifier_name
