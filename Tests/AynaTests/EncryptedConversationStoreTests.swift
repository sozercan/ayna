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
}
