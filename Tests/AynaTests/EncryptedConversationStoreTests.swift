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

    @Test
    func `save and load round trips conversations`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Alpha")

        try await store.save(conversation)
        let loaded = try await store.loadConversations()

        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Alpha")
        #expect(loaded.first?.messages.count == conversation.messages.count)
    }

    @Test
    func `clear removes encrypted files`() async throws {
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

    @Test
    func `second store instance loads data using same key`() async throws {
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

    @Test
    func `loading an empty store does not create an encryption key`() async throws {
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

    @Test
    func `one unreadable record fails the whole load instead of returning a partial snapshot`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let readable = TestHelpers.sampleConversation(title: "Readable")
        let unreadable = TestHelpers.sampleConversation(title: "Unreadable")
        try await store.save(readable)
        try await store.save(unreadable)
        try Data("corrupt encrypted record".utf8).write(
            to: store.fileURL(for: unreadable.id),
            options: .atomic
        )

        await #expect(throws: EncryptedStoreError.self) {
            _ = try await store.loadConversations()
        }
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: readable.id).path))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: unreadable.id).path))
    }

    @Test
    func `encryption key is cached across repeated save and load operations`() async throws {
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
