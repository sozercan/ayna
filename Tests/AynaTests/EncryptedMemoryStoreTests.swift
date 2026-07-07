//
//  EncryptedMemoryStoreTests.swift
//  ayna
//
//  Created on 1/29/26.
//

@testable import Ayna
import Foundation
import Testing

@Suite("EncryptedMemoryStore Tests")
struct EncryptedMemoryStoreTests {
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

    // MARK: - User Memory Round-Trip

    @Test("Save and load memory preserves facts")
    func saveAndLoadMemoryPreservesFacts() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: "test_memory_key",
            keychain: keychain
        )

        // Create test facts
        let facts = [
            UserMemoryFact(content: "Likes Swift programming"),
            UserMemoryFact(content: "Works as a developer"),
            UserMemoryFact(content: "Prefers dark mode")
        ]
        let memoryStore = UserMemoryStore(facts: facts)

        // Save
        try await store.saveMemory(memoryStore)

        // Load
        let loaded = try await store.loadMemory()

        #expect(loaded.facts.count == 3)
        #expect(loaded.facts.map(\.content).contains("Likes Swift programming"))
        #expect(loaded.facts.map(\.content).contains("Works as a developer"))
        #expect(loaded.facts.map(\.content).contains("Prefers dark mode"))
    }

    @Test("Load returns empty store when no file exists")
    func loadReturnsEmptyStoreWhenNoFileExists() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: "test_memory_key",
            keychain: keychain
        )

        let loaded = try await store.loadMemory()

        #expect(loaded.facts.isEmpty)
    }

    @Test("Clear memory removes file")
    func clearMemoryRemovesFile() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: "test_memory_key",
            keychain: keychain
        )

        // Save some data
        let memoryStore = UserMemoryStore(facts: [UserMemoryFact(content: "Test")])
        try await store.saveMemory(memoryStore)

        // Clear
        try await store.clearMemory()

        // Load should return empty
        let loaded = try await store.loadMemory()
        #expect(loaded.facts.isEmpty)
    }

    // MARK: - Conversation Summaries Round-Trip

    @Test("Save and load summaries preserves data")
    func saveAndLoadSummariesPreservesData() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: "test_summary_key",
            keychain: keychain
        )

        // Create test summaries
        let summaries = [
            ConversationSummary(
                id: UUID(),
                title: "Swift Discussion",
                userMessageSnippets: ["How do I use async/await?"],
                topics: ["swift", "concurrency"]
            ),
            ConversationSummary(
                id: UUID(),
                title: "Code Review",
                userMessageSnippets: ["Review this PR"],
                topics: ["review", "code"]
            )
        ]
        let digest = RecentConversationsDigest(summaries: summaries)

        // Save
        try await store.saveSummaries(digest)

        // Load
        let loaded = try await store.loadSummaries()

        #expect(loaded.summaries.count == 2)
        #expect(loaded.summaries.map(\.title).contains("Swift Discussion"))
        #expect(loaded.summaries.map(\.title).contains("Code Review"))
    }

    @Test("Load returns empty digest when no file exists")
    func loadReturnsEmptyDigestWhenNoFileExists() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: "test_summary_key",
            keychain: keychain
        )

        let loaded = try await store.loadSummaries()

        #expect(loaded.summaries.isEmpty)
    }

    // MARK: - Key Generation

    @Test("New key is generated on first access")
    func newKeyIsGeneratedOnFirstAccess() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let keyIdentifier = "test_new_key"
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )

        // Keychain should be empty initially
        let keyBefore = try keychain.data(for: keyIdentifier)
        #expect(keyBefore == nil)

        // Trigger key generation by saving
        let memoryStore = UserMemoryStore(facts: [UserMemoryFact(content: "Test")])
        try await store.saveMemory(memoryStore)

        // Key should now exist
        let keyAfter = try keychain.data(for: keyIdentifier)
        #expect(keyAfter != nil)
        #expect(keyAfter?.count == 32) // 256 bits = 32 bytes
    }

    @Test("Encryption key is cached across repeated memory and summary operations")
    func encryptionKeyIsCachedAcrossRepeatedMemoryAndSummaryOperations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = CountingKeychainStorage()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: "test_cached_memory_key",
            keychain: keychain
        )

        let memoryStore = UserMemoryStore(facts: [UserMemoryFact(content: "First")])
        try await store.saveMemory(memoryStore)
        _ = try await store.loadMemory()

        let digest = RecentConversationsDigest(summaries: [
            ConversationSummary(
                id: UUID(),
                title: "Cached",
                userMessageSnippets: ["memory"],
                topics: ["perf"]
            )
        ])
        try await store.saveSummaries(digest)
        _ = try await store.loadSummaries()

        let counts = keychain.readCounts()
        #expect(counts.dataReads == 1)
        #expect(counts.stringReads == 1)
    }

    @Test("Same key is reused across operations")
    func sameKeyIsReusedAcrossOperations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let keyIdentifier = "test_reuse_key"
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )

        // First save generates key
        let memoryStore1 = UserMemoryStore(facts: [UserMemoryFact(content: "First")])
        try await store.saveMemory(memoryStore1)

        let keyAfterFirst = try keychain.data(for: keyIdentifier)

        // Second save should reuse key
        let memoryStore2 = UserMemoryStore(facts: [UserMemoryFact(content: "Second")])
        try await store.saveMemory(memoryStore2)

        let keyAfterSecond = try keychain.data(for: keyIdentifier)

        #expect(keyAfterFirst == keyAfterSecond)
    }

    // MARK: - Error Handling

    @Test("Key loss is detected when flag exists but key is missing")
    func keyLossIsDetectedWhenFlagExistsButKeyIsMissing() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = InMemoryKeychainStorage()
        let keyIdentifier = "test_lost_key"
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )

        // First, save to create the key and flag
        let memoryStore = UserMemoryStore(facts: [UserMemoryFact(content: "Test")])
        try await store.saveMemory(memoryStore)

        // Simulate key loss by removing the key but keeping the flag
        try keychain.removeValue(for: keyIdentifier)

        // A fresh store (matching app relaunch) should fail with keyLost error.
        let relaunchedStore = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        await #expect(throws: EncryptedMemoryStoreError.keyLost) {
            _ = try await relaunchedStore.loadMemory()
        }
    }
}
