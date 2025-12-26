import Foundation
import Testing

@testable import Ayna

@Suite("EncryptedConversationStore Tests", .tags(.persistence, .slow))
struct EncryptedConversationStoreTests {
    @Test("Save and load round trips conversations")
    func saveAndLoadRoundTripsConversations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Alpha")

        try await store.save(conversation)
        let loaded = try await store.loadConversations()

        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Alpha")
        #expect(loaded.first?.messages.count == conversation.messages.count)
    }

    @Test("Clear removes encrypted files")
    func clearRemovesEncryptedFiles() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation()
        try await store.save(conversation)

        try store.clear()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        #expect(files.isEmpty)
    }

    @Test("Second store instance loads data using same key")
    func secondStoreInstanceLoadsDataUsingSameKey() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keyIdentifier = UUID().uuidString

        let firstStore = EncryptedConversationStore(
            directoryURL: directory, keyIdentifier: keyIdentifier
        )
        let conversation = TestHelpers.sampleConversation(title: "Persisted")
        try await firstStore.save(conversation)

        let secondStore = EncryptedConversationStore(
            directoryURL: directory, keyIdentifier: keyIdentifier
        )
        let loaded = try await secondStore.loadConversations()

        #expect(loaded.first?.title == "Persisted")
    }
}
