@testable import Ayna
import CryptoKit
import Foundation
import Testing

@Suite("EncryptedConversationStore Tests", .tags(.persistence, .slow))
struct EncryptedConversationStoreTests {
    @Test
    func `duplicate UUID filenames prefer the canonical storage name`() {
        let id = UUID()
        let root = URL(fileURLWithPath: "/tmp/duplicate-storage-fixture")
        let canonicalConversation = root.appendingPathComponent("\(id.uuidString).enc")
        let lowercaseConversation = root.appendingPathComponent("\(id.uuidString.lowercased()).enc")
        let canonicalMetadata = root.appendingPathComponent("\(id.uuidString).metadata.enc")
        let lowercaseMetadata = root.appendingPathComponent("\(id.uuidString.lowercased()).metadata.enc")

        let conversations = EncryptedConversationStore.conversationFileURLsById(
            from: [lowercaseConversation, canonicalConversation]
        )
        let metadata = EncryptedConversationStore.metadataFileURLsById(
            from: [lowercaseMetadata, canonicalMetadata]
        )
        let conversationAliases = EncryptedConversationStore.conversationFileURLs(
            matching: id,
            from: [lowercaseConversation, canonicalConversation]
        )
        let metadataAliases = EncryptedConversationStore.metadataFileURLs(
            matching: id,
            from: [lowercaseMetadata, canonicalMetadata]
        )

        #expect(conversations[id] == canonicalConversation)
        #expect(metadata[id] == canonicalMetadata)
        #expect(Set(conversationAliases) == [lowercaseConversation, canonicalConversation])
        #expect(Set(metadataAliases) == [lowercaseMetadata, canonicalMetadata])
    }

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
        #expect(Set(files.map(\.lastPathComponent)) == Set(["Metadata", "SearchIndex"]))
        for directoryURL in files {
            #expect(try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ).isEmpty)
        }
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
    func `loading empty metadata does not create an encryption key`() async throws {
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

    @Test
    func `legacy metadata migration deduplicates conversation IDs with last entry winning`() async throws {
        let tempRoot = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let directory = tempRoot.appendingPathComponent("Conversations", isDirectory: true)
        let legacyFileURL = tempRoot.appendingPathComponent("conversations.enc")
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try keychain.setData(keyData, for: keyIdentifier)
        try keychain.setString("1", for: "\(keyIdentifier)_initialized")

        let conversationId = UUID()
        var older = TestHelpers.sampleConversation(id: conversationId, title: "Older Duplicate")
        older.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        var newer = TestHelpers.sampleConversation(id: conversationId, title: "Newer Duplicate")
        newer.updatedAt = Date(timeIntervalSinceReferenceDate: 200)

        let encoded = try JSONEncoder().encode([older, newer])
        let sealed = try AES.GCM.seal(encoded, using: key)
        let encrypted = try #require(sealed.combined)
        try encrypted.write(to: legacyFileURL, options: .atomic)

        let store = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFileURL,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let metadata = try await store.loadConversationMetadata()
        let migrated = try #require(try await store.loadConversation(id: conversationId))

        #expect(metadata.count == 1)
        #expect(metadata.first?.title == "Newer Duplicate")
        #expect(migrated.title == "Newer Duplicate")
        #expect(!FileManager.default.fileExists(atPath: legacyFileURL.path))
    }

    @Test
    func `legacy migration replaces an unreadable canonical conversation`() async throws {
        let tempRoot = try TestHelpers.makeTemporaryDirectory()
        let directory = tempRoot.appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyFileURL = tempRoot.appendingPathComponent("conversations.enc")
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try keychain.setData(keyData, for: keyIdentifier)
        try keychain.setString("1", for: "\(keyIdentifier)_initialized")

        let conversation = TestHelpers.sampleConversation(title: "Recoverable Legacy")
        let encoded = try JSONEncoder().encode([conversation])
        let sealed = try AES.GCM.seal(encoded, using: key)
        try #require(sealed.combined).write(to: legacyFileURL, options: .atomic)
        try Data("corrupt canonical".utf8).write(
            to: directory.appendingPathComponent("\(conversation.id.uuidString).enc")
        )

        let store = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFileURL,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let migrated = try #require(try await store.loadConversations().first)

        #expect(migrated.title == "Recoverable Legacy")
        #expect(!FileManager.default.fileExists(atPath: legacyFileURL.path))
    }

    @Test
    func `legacy migration replaces an older canonical conversation`() async throws {
        let tempRoot = try TestHelpers.makeTemporaryDirectory()
        let directory = tempRoot.appendingPathComponent("Conversations", isDirectory: true)
        let legacyFileURL = tempRoot.appendingPathComponent("conversations.enc")
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try keychain.setData(keyData, for: keyIdentifier)
        try keychain.setString("1", for: "\(keyIdentifier)_initialized")

        let conversationId = UUID()
        var canonical = TestHelpers.sampleConversation(id: conversationId, title: "Older Canonical")
        canonical.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let firstStore = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFileURL,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        try await firstStore.save(canonical)

        var legacy = canonical
        legacy.title = "Newer Legacy"
        legacy.updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let encoded = try JSONEncoder().encode([legacy])
        let sealed = try AES.GCM.seal(encoded, using: key)
        try #require(sealed.combined).write(to: legacyFileURL, options: .atomic)

        let secondStore = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFileURL,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let migrated = try #require(try await secondStore.loadConversations().first)

        #expect(migrated.title == "Newer Legacy")
        #expect(!FileManager.default.fileExists(atPath: legacyFileURL.path))
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

    @Test
    func `save writes encrypted metadata sidecar and loads it newest first`() async throws {
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

    @Test
    func `metadata loading backfills missing sidecars from full conversation files`() async throws {
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

    @Test
    func `metadata loading rebuilds stale sidecar when full file is newer`() async throws {
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

    @Test
    func `metadata loading rebuilds sidecar newer by less than one second`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Near Original")
        try await store.save(conversation)

        let metadataURL = store.metadataFileURL(for: conversation.id)
        let originalMetadataData = try Data(contentsOf: metadataURL)

        conversation.title = "Near Updated"
        conversation.addMessage(Message(role: .user, content: "Subsecond newer message"))
        try await store.save(conversation)

        try originalMetadataData.write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 199.8)],
            ofItemAtPath: metadataURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 200)],
            ofItemAtPath: store.fileURL(for: conversation.id).path
        )

        let metadata = try await store.loadConversationMetadata()

        #expect(metadata.count == 1)
        #expect(metadata.first?.title == "Near Updated")
        #expect(metadata.first?.messageCount == conversation.messages.count)
    }

    @Test
    func `legacy metadata without preview fields requires backfill`() throws {
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

    @Test
    func `metadata preview uses the true latest message`() {
        var conversation = Conversation(title: "Latest Preview")
        conversation.addMessage(Message(role: .assistant, content: "Older assistant reply"))
        conversation.addMessage(Message(role: .user, content: "Latest unanswered prompt"))

        let metadata = ConversationMetadata(conversation: conversation)

        #expect(metadata.lastMessagePreview == "Latest unanswered prompt")
    }

    @Test
    func `metadata searchable text includes older messages up to cap`() {
        var conversation = Conversation(title: "Searchable")
        for index in 0 ..< 25 {
            let content = index == 0 ? "needle-in-first-message" : "message \(index)"
            conversation.addMessage(Message(role: .user, content: content))
        }

        let metadata = ConversationMetadata(conversation: conversation)

        #expect(metadata.searchableText.contains("needle-in-first-message"))
        #expect(metadata.messageCount == 25)
    }

    @Test
    func `metadata searchable text includes recent tail beyond cap`() {
        var conversation = Conversation(title: "Long Searchable")
        conversation.addMessage(Message(role: .user, content: String(repeating: "early ", count: 3000)))
        conversation.addMessage(Message(role: .assistant, content: "recent-tail-needle"))

        let metadata = ConversationMetadata(conversation: conversation)

        #expect(metadata.searchableText.contains("early"))
        #expect(metadata.searchableText.contains("recent-tail-needle"))
        #expect(metadata.searchableText.count <= 12003)
    }

    @Test
    func `metadata searchable text preserves exact bounded head and tail`() {
        var conversation = Conversation(title: String(repeating: "t", count: 4000))
        conversation.addMessage(Message(role: .user, content: String(repeating: "u", count: 5000)))
        conversation.addMessage(Message(role: .assistant, content: String(repeating: "a", count: 5000)))

        let fullText = ([conversation.title] + conversation.messages.map(\.content)).joined(separator: "\n")
        let expected = "\(fullText.prefix(6000))\n…\n\(fullText.suffix(6000))"
        let metadata = ConversationMetadata(conversation: conversation)

        #expect(metadata.searchableText == expected)
    }

    @Test
    func `full-text search finds omitted middle content and invalidates cached text after save`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let store = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        var conversation = Conversation(title: "Indexed Search")
        conversation.addMessage(Message(role: .user, content: String(repeating: "head ", count: 2000)))
        conversation.addMessage(Message(role: .assistant, content: "middle-only-search-index-needle"))
        conversation.addMessage(Message(role: .user, content: String(repeating: "tail ", count: 2000)))
        try await store.save(conversation)
        let searchIndexURL = store.searchIndexFileURL(for: conversation.id)
        #expect(!FileManager.default.fileExists(atPath: searchIndexURL.path))

        let coldStore = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let matches = try await coldStore.conversationIdsMatchingSearch(
            query: "middle-only-search-index-needle",
            candidateIds: [conversation.id]
        )
        #expect(matches == [conversation.id])
        #expect(FileManager.default.fileExists(atPath: searchIndexURL.path))

        try await coldStore.warmConversationSearchIndex(candidateIds: [conversation.id])
        #expect(FileManager.default.fileExists(atPath: searchIndexURL.path))

        conversation.messages[1].content = "replacement-middle-text"
        conversation.updatedAt = Date().addingTimeInterval(1)
        try await store.save(conversation)
        #expect(!FileManager.default.fileExists(atPath: searchIndexURL.path))

        let staleMatches = try await coldStore.conversationIdsMatchingSearch(
            query: "middle-only-search-index-needle",
            candidateIds: [conversation.id]
        )
        let currentMatches = try await coldStore.conversationIdsMatchingSearch(
            query: "replacement-middle-text",
            candidateIds: [conversation.id]
        )
        #expect(staleMatches.isEmpty)
        #expect(currentMatches == [conversation.id])
    }

    @Test
    func `cold and cached full-text searches do not match across message boundaries`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = Conversation(title: "Boundary Search")
        conversation.addMessage(Message(role: .user, content: "foo"))
        conversation.addMessage(Message(role: .assistant, content: "bar"))
        try await store.save(conversation)

        let coldMatches = try await store.conversationIdsMatchingSearch(
            query: "foo\nbar",
            candidateIds: [conversation.id]
        )
        let cachedMatches = try await store.conversationIdsMatchingSearch(
            query: "foo\nbar",
            candidateIds: [conversation.id]
        )

        #expect(coldMatches.isEmpty)
        #expect(cachedMatches.isEmpty)
    }

    @Test
    func `full-text search keeps field boundaries consistent across cache states`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let store = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        var conversation = Conversation(title: "alpha")
        conversation.addMessage(Message(role: .user, content: "beta"))
        try await store.save(conversation)

        let spanningQuery = "alpha\nbeta"
        try await store.warmConversationSearchIndex(candidateIds: [conversation.id])
        let warmResult = try await store.conversationIdsMatchingSearch(
            query: spanningQuery,
            candidateIds: [conversation.id]
        )
        let coldStore = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let persistedResult = try await coldStore.conversationIdsMatchingSearch(
            query: spanningQuery,
            candidateIds: [conversation.id]
        )

        #expect(warmResult.isEmpty)
        #expect(persistedResult.isEmpty)
    }

    @Test
    func `background warmup persists indexes before interactive search`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversations = [
            TestHelpers.sampleConversation(title: "Warm One"),
            TestHelpers.sampleConversation(title: "Warm Two"),
        ]
        for conversation in conversations {
            try await store.save(conversation)
            #expect(!FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: conversation.id).path))
        }

        try await store.warmConversationSearchIndex(candidateIds: Set(conversations.map(\.id)))

        for conversation in conversations {
            #expect(FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: conversation.id).path))
        }
    }

    @Test
    func `background warmup prunes indexes outside the retained set`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let retained = TestHelpers.sampleConversation(title: "Retained Index")
        let evicted = TestHelpers.sampleConversation(title: "Evicted Index")
        try await store.save([retained, evicted])
        try await store.warmConversationSearchIndex(candidateIds: [retained.id, evicted.id])

        #expect(FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: retained.id).path))
        #expect(FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: evicted.id).path))

        try await store.warmConversationSearchIndex(candidateIds: [retained.id])

        #expect(FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: retained.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: evicted.id).path))

        try await store.warmConversationSearchIndex(candidateIds: [])
        #expect(!FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: retained.id).path))
    }

    @Test
    func `full-text search propagates cancellation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Cancellation")
        try await store.save(conversation)

        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.conversationIdsMatchingSearch(
                    query: "missing",
                    candidateIds: [conversation.id]
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(result)
    }

    @Test
    func `load conversation by id returns full conversation when present`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Full")
        try await store.save(conversation)

        let loaded = try #require(try await store.loadConversation(id: conversation.id))
        let missing = try await store.loadConversation(id: UUID())

        #expect(loaded == conversation)
        #expect(missing == nil)
    }

    @Test
    func `load conversation by id propagates cancellation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Cancelled Load")
        try await store.save(conversation)

        let didCancel = await Task.detached {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            do {
                _ = try await store.loadConversation(id: conversation.id)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(didCancel)
    }

    @Test
    func `delete removes conversation and metadata sidecar`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Delete")
        try await store.save(conversation)
        try await store.warmConversationSearchIndex(candidateIds: [conversation.id])
        let searchIndexURL = store.searchIndexFileURL(for: conversation.id)
        #expect(FileManager.default.fileExists(atPath: searchIndexURL.path))

        try await store.delete(conversation.id)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.metadataFileURL(for: conversation.id).path))
        #expect(!FileManager.default.fileExists(atPath: searchIndexURL.path))
        let metadata = try await store.loadConversationMetadata()
        #expect(metadata == [])
    }

    @Test
    func `in-flight saves cannot recreate a deleted conversation`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = TestHelpers.sampleConversation(title: "Delete Race")
        try await store.save(conversation)

        let saveTasks = (0 ..< 8).map { _ in
            Task {
                try? await store.save(conversation)
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        try await store.delete(conversation.id)
        for task in saveTasks {
            await task.value
        }

        #expect(try await store.loadConversation(id: conversation.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.metadataFileURL(for: conversation.id).path))
    }

    @Test
    func `cancelling a save cancels detached persistence work`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Cancelled Save")
        conversation.messages = [
            Message(role: .user, content: String(repeating: "payload", count: 500_000))
        ]

        let conversationToSave = conversation
        let saveTask = Task.detached { @Sendable in
            try await store.save(conversationToSave)
        }
        saveTask.cancel()

        do {
            try await saveTask.value
            Issue.record("Expected save cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(try await store.loadConversation(id: conversation.id) == nil)
    }

    @Test
    func `a new save can reuse an ID after deletion completes`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        var conversation = TestHelpers.sampleConversation(title: "Original")
        try await store.save(conversation)
        try await store.delete(conversation.id)

        conversation.title = "Restored from sync"
        conversation.updatedAt = Date().addingTimeInterval(10)
        try await store.save(conversation)

        let restored = try #require(try await store.loadConversation(id: conversation.id))
        #expect(restored.title == "Restored from sync")
    }

    @Test
    func `in-flight saves cannot repopulate a cleared store`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversations = (0 ..< 8).map { index in
            TestHelpers.sampleConversation(title: "Clear Race \(index)")
        }
        let saveTasks = conversations.map { conversation in
            Task {
                try? await store.save(conversation)
            }
        }
        try await Task.sleep(for: .milliseconds(10))

        try store.clear()
        for task in saveTasks {
            await task.value
        }

        #expect(try await store.loadConversations().isEmpty)
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(Set(remainingFiles.map(\.lastPathComponent)) == Set(["Metadata", "SearchIndex"]))
        for directoryURL in remainingFiles {
            #expect(try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ).isEmpty)
        }
    }

    @Test
    func `save after clear recreates metadata and search index directories`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let removed = TestHelpers.sampleConversation(title: "Before Clear")
        try await store.save(removed)
        try store.clear()

        let retained = TestHelpers.sampleConversation(title: "After Clear")
        try await store.save(retained)
        #expect(FileManager.default.fileExists(atPath: store.metadataFileURL(for: retained.id).path))

        try await store.warmConversationSearchIndex(candidateIds: [retained.id])
        #expect(FileManager.default.fileExists(atPath: store.searchIndexFileURL(for: retained.id).path))
    }

    @Test
    func `separate store instances share clear generations`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let savingStore = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let clearingStore = TestHelpers.makeTestStore(
            directory: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let conversations = (0 ..< 8).map { index -> Conversation in
            var conversation = TestHelpers.sampleConversation(title: "Cross-store Clear \(index)")
            conversation.messages = [
                Message(role: .user, content: String(repeating: "payload", count: 100_000))
            ]
            return conversation
        }
        let saveTasks = conversations.map { conversation in
            Task {
                try? await savingStore.save(conversation)
            }
        }
        try await Task.sleep(for: .milliseconds(10))

        try clearingStore.clear()
        for task in saveTasks {
            await task.value
        }

        #expect(try await clearingStore.loadConversations().isEmpty)
    }

    @Test
    func `store startup and clear remove abandoned staging directories`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let startupStaging = parent.appendingPathComponent(
            ".AynaConversationStaging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: startupStaging, withIntermediateDirectories: true)
        try Data("encrypted residue".utf8).write(
            to: startupStaging.appendingPathComponent("stale.tmp")
        )

        let store = TestHelpers.makeTestStore(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: startupStaging.path))

        let clearStaging = parent.appendingPathComponent(
            ".AynaConversationStaging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: clearStaging, withIntermediateDirectories: true)
        try Data("encrypted residue".utf8).write(
            to: clearStaging.appendingPathComponent("stale.tmp")
        )

        try store.clear()
        #expect(!FileManager.default.fileExists(atPath: clearStaging.path))
    }
}
