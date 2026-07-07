@testable import Ayna
import Foundation
import Testing

@Suite("EncryptedConversationStore Tests", .tags(.persistence, .slow))
struct EncryptedConversationStoreTests {
    private final class CountingKeychainStorage: KeychainStoring, @unchecked Sendable {
        private var storage: [String: Data] = [:]
        private let lock = NSLock()
        private var dataReads = 0
        private var stringReads = 0

        func setString(_ value: String, for key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = Data(value.utf8)
        }

        func string(for key: String) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            stringReads += 1
            guard let data = storage[key] else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func setData(_ data: Data, for key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = data
        }

        func data(for key: String) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            dataReads += 1
            return storage[key]
        }

        func removeValue(for key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = nil
        }

        func readCounts() -> (dataReads: Int, stringReads: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (dataReads, stringReads)
        }
    }

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

    @Test("Loading an empty store does not create an encryption key")
    func loadingEmptyStoreDoesNotCreateEncryptionKey() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = CountingKeychainStorage()
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: keychain
        )

        let loaded = try await store.loadConversations()
        let counts = keychain.readCounts()

        #expect(loaded.isEmpty)
        #expect(counts.dataReads == 0)
        #expect(counts.stringReads == 0)
    }

    @Test("Loading empty metadata does not create an encryption key")
    func loadingEmptyMetadataDoesNotCreateEncryptionKey() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = CountingKeychainStorage()
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: keychain
        )

        let metadata = try await store.loadConversationMetadata()
        let counts = keychain.readCounts()

        #expect(metadata.isEmpty)
        #expect(counts.dataReads == 0)
        #expect(counts.stringReads == 0)
    }

    @Test("Encryption key is cached across repeated save and load operations")
    func encryptionKeyIsCachedAcrossOperations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = CountingKeychainStorage()
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: keychain
        )

        try await store.save(TestHelpers.sampleConversation(title: "First"))
        _ = try await store.loadConversations()
        try await store.save(TestHelpers.sampleConversation(title: "Second"))

        let counts = keychain.readCounts()
        #expect(counts.dataReads == 1)
        #expect(counts.stringReads == 1)
    }

    @Test("Save writes encrypted metadata sidecar and loads it newest first")
    func saveWritesMetadataSidecarAndLoadsNewestFirst() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let olderDate = Date(timeIntervalSinceReferenceDate: 100)
        let newerDate = Date(timeIntervalSinceReferenceDate: 200)
        let older = Conversation(
            title: "Older",
            messages: [Message(role: .user, content: "One")],
            createdAt: olderDate,
            updatedAt: olderDate,
            model: "gpt-4o"
        )
        let newer = Conversation(
            title: "Newer",
            messages: [
                Message(role: .user, content: "One"),
                Message(role: .assistant, content: "Two"),
            ],
            createdAt: newerDate,
            updatedAt: newerDate,
            model: "gpt-4o-mini"
        )

        try await store.save(older)
        try await store.save(newer)

        #expect(FileManager.default.fileExists(atPath: store.metadataFileURL(for: older.id).path))
        #expect(FileManager.default.fileExists(atPath: store.metadataFileURL(for: newer.id).path))

        let metadata = try await store.loadConversationMetadata()

        #expect(metadata.map(\.id) == [newer.id, older.id])
        #expect(metadata.first?.title == "Newer")
        #expect(metadata.first?.messageCount == 2)
        #expect(metadata.first?.model == "gpt-4o-mini")
    }

    @Test("Metadata loading backfills missing sidecars from full conversation files")
    func metadataLoadingBackfillsMissingSidecars() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Backfill")
        try await store.save(conversation)
        try FileManager.default.removeItem(at: store.metadataFileURL(for: conversation.id))

        let metadata = try await store.loadConversationMetadata()

        #expect(metadata.count == 1)
        #expect(metadata.first?.id == conversation.id)
        #expect(metadata.first?.title == "Backfill")
        #expect(metadata.first?.messageCount == conversation.messages.count)
        #expect(FileManager.default.fileExists(atPath: store.metadataFileURL(for: conversation.id).path))
    }

    @Test("Metadata loading rebuilds stale sidecar when full file is newer")
    func metadataLoadingRebuildsStaleSidecarWhenFullFileIsNewer() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Original")
        try await store.save(conversation)

        let metadataURL = store.metadataFileURL(for: conversation.id)
        let originalMetadataData = try Data(contentsOf: metadataURL)

        conversation.title = "Updated"
        conversation.addMessage(Message(role: .user, content: "Newer message"))
        try await store.save(conversation)

        try originalMetadataData.write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 100)],
            ofItemAtPath: metadataURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 200)],
            ofItemAtPath: store.fileURL(for: conversation.id).path
        )

        let metadata = try await store.loadConversationMetadata()

        #expect(metadata.count == 1)
        #expect(metadata.first?.title == "Updated")
        #expect(metadata.first?.messageCount == conversation.messages.count)
    }

    @Test("Legacy metadata without preview fields requires backfill")
    func legacyMetadataWithoutPreviewFieldsRequiresBackfill() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "Legacy Metadata",
          "createdAt": 100,
          "updatedAt": 200,
          "model": "gpt-4o",
          "systemPromptMode": { "type": "inheritGlobal" },
          "temperature": 0.7,
          "multiModelEnabled": false,
          "activeModels": [],
          "messageCount": 2,
          "responseGroupCount": 0
        }
        """
        let metadata = try JSONDecoder().decode(ConversationMetadata.self, from: Data(json.utf8))

        #expect(metadata.requiresBackfill == true)
        #expect(metadata.lastMessagePreview == "")
        #expect(metadata.searchableText == "Legacy Metadata")
    }

    @Test("Metadata searchable text includes older messages up to cap")
    func metadataSearchableTextIncludesOlderMessagesUpToCap() {
        var conversation = Conversation(title: "Searchable")
        for index in 0 ..< 25 {
            let content = index == 0 ? "needle-in-first-message" : "message \(index)"
            conversation.addMessage(Message(role: .user, content: content))
        }

        let metadata = ConversationMetadata(conversation: conversation)

        #expect(metadata.searchableText.contains("needle-in-first-message"))
        #expect(metadata.messageCount == 25)
    }

    @Test("Metadata searchable text includes recent tail beyond cap")
    func metadataSearchableTextIncludesRecentTailBeyondCap() {
        var conversation = Conversation(title: "Long Searchable")
        conversation.addMessage(Message(role: .user, content: String(repeating: "early ", count: 3000)))
        conversation.addMessage(Message(role: .assistant, content: "recent-tail-needle"))

        let metadata = ConversationMetadata(conversation: conversation)

        #expect(metadata.searchableText.contains("early"))
        #expect(metadata.searchableText.contains("recent-tail-needle"))
        #expect(metadata.searchableText.count <= 12003)
    }

    @Test("Load conversation by id returns full conversation when present")
    func loadConversationByIdReturnsFullConversation() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Full")
        try await store.save(conversation)

        let loaded = try #require(try await store.loadConversation(id: conversation.id))
        let missing = try await store.loadConversation(id: UUID())

        #expect(loaded == conversation)
        #expect(missing == nil)
    }

    @Test("Delete removes conversation and metadata sidecar")
    func deleteRemovesConversationAndMetadataSidecar() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Delete")
        try await store.save(conversation)

        try await store.delete(conversation.id)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.metadataFileURL(for: conversation.id).path))
        let metadata = try await store.loadConversationMetadata()
        #expect(metadata == [])
    }
}
