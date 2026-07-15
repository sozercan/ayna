//
//  ConversationSummaryServiceTests.swift
//  ayna
//
//  Created on 1/29/26.
//

@testable import Ayna
import Foundation
import Testing

@Suite("ConversationSummaryService Tests")
@MainActor
struct ConversationSummaryServiceTests {
    // MARK: - Summary Generation

    @Test
    func `clear invalidates a summary load already in flight`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let staleDigest = {
            var digest = RecentConversationsDigest()
            digest.upsertSummary(ConversationSummary(id: UUID(), title: "Cleared History"))
            return digest
        }()
        let loadGate = ConversationSummaryLoadGate(digest: staleDigest)
        let service = ConversationSummaryService(
            store: store,
            summaryLoader: { try await loadGate.load() },
            summaryClearOperation: {}
        )

        let loadTask = Task { @MainActor in
            await service.loadSummaries()
        }
        await loadGate.waitUntilStarted()

        try await service.clearAllSummaries()
        await loadGate.release()
        await loadTask.value

        #expect(service.isLoaded)
        #expect(service.summaryCount == 0)
        #expect(service.formattedForContext() == nil)
    }

    @Test
    func `conversation clear blocks summary loads until cleanup completes`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let staleDigest = {
            var digest = RecentConversationsDigest()
            digest.upsertSummary(ConversationSummary(id: UUID(), title: "Cleared History"))
            return digest
        }()
        let persistenceProbe = SummaryPersistenceProbe()
        let service = ConversationSummaryService(
            store: store,
            summaryLoader: { staleDigest },
            summarySaveOperation: { digest in
                persistenceProbe.save(digest)
            },
            summaryClearOperation: {
                persistenceProbe.clear()
            }
        )

        _ = service.invalidateForConversationClear()
        await service.loadSummaries()
        try await service.clearAllSummaries(
            preservingCurrentDigest: true,
            completingConversationClear: true
        )

        #expect(service.summaryCount == 0)
        #expect(service.formattedForContext() == nil)
        #expect(persistenceProbe.persistedDigest == nil)
    }

    @Test
    func `earlier summary cleanup cannot unblock a newer conversation clear`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let staleDigest = {
            var digest = RecentConversationsDigest()
            digest.upsertSummary(ConversationSummary(id: UUID(), title: "Cleared History"))
            return digest
        }()
        let clearGate = BlockingSummaryClearOperationGate()
        let service = ConversationSummaryService(
            store: store,
            summaryLoader: { staleDigest },
            summaryClearOperation: {
                clearGate.run()
            }
        )

        _ = service.invalidateForConversationClear()
        let firstCleanup = Task { @MainActor in
            try await service.clearAllSummaries(
                preservingCurrentDigest: true,
                completingConversationClear: true
            )
        }
        while !clearGate.hasStarted() {
            await Task.yield()
        }

        _ = service.invalidateForConversationClear()
        clearGate.release()
        try await firstCleanup.value
        await service.loadSummaries()

        #expect(service.summaryCount == 0)
        #expect(service.formattedForContext() == nil)
    }

    @Test
    func `clear waits for an immediate summary save before deleting storage`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let saveGate = ConversationSummarySaveGate()
        let persistenceProbe = SummaryPersistenceProbe()
        let service = ConversationSummaryService(
            store: store,
            summarySaveOperation: { digest in
                await saveGate.wait()
                persistenceProbe.save(digest)
            },
            summaryClearOperation: {
                persistenceProbe.clear()
            }
        )
        service.updateSummary(for: TestHelpers.sampleConversation(title: "Must Stay Cleared"))

        let saveTask = Task { @MainActor in
            await service.saveImmediately()
        }
        await saveGate.waitUntilStarted()
        let clearTask = Task { @MainActor in
            try await service.clearAllSummaries()
        }

        for _ in 0 ..< 100 where !persistenceProbe.wasCleared {
            await Task.yield()
        }
        await saveGate.release()
        await saveTask.value
        try await clearTask.value

        #expect(service.summaryCount == 0)
        #expect(persistenceProbe.persistedDigest == nil)
    }

    @Test
    func `local summary mutation wins over an in-flight stale load`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let loadGate = ConversationSummaryLoadGate(digest: RecentConversationsDigest())
        let service = ConversationSummaryService(
            store: store,
            summaryLoader: { try await loadGate.load() },
            summarySaveOperation: { _ in }
        )
        let loadTask = Task { @MainActor in
            await service.loadSummaries()
        }
        await loadGate.waitUntilStarted()

        service.updateSummary(for: TestHelpers.sampleConversation(title: "New Local Summary"))
        await loadGate.release()
        await loadTask.value

        #expect(service.summaryCount == 1)
        #expect(service.digest.summaries.first?.title == "New Local Summary")
    }

    @Test
    func `failed conversation clear restores summaries durably`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let persistenceProbe = SummaryPersistenceProbe()
        let service = ConversationSummaryService(
            store: store,
            summarySaveOperation: { digest in
                persistenceProbe.save(digest)
            }
        )
        service.updateSummary(for: TestHelpers.sampleConversation(title: "Rollback Summary"))

        let snapshot = service.invalidateForConversationClear()
        try await service.restoreAfterFailedConversationClear(snapshot)

        #expect(service.digest.summaries.first?.title == "Rollback Summary")
        #expect(persistenceProbe.persistedDigest?.summaries.first?.title == "Rollback Summary")
    }

    @Test
    func `failed clear merges summaries created while the clear was running`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let service = ConversationSummaryService(
            store: store,
            summarySaveOperation: { _ in }
        )
        let original = TestHelpers.sampleConversation(title: "Original Summary")
        service.updateSummary(for: original)
        let snapshot = service.invalidateForConversationClear()

        var recreated = original
        recreated.title = "Newer Summary"
        recreated.updatedAt = Date().addingTimeInterval(1)
        service.updateSummary(for: recreated)
        service.updateSummary(for: TestHelpers.sampleConversation(title: "Created During Clear"))

        try await service.restoreAfterFailedConversationClear(snapshot)

        #expect(service.digest.summaries.contains { $0.title == "Newer Summary" })
        #expect(service.digest.summaries.contains { $0.title == "Created During Clear" })
        #expect(!service.digest.summaries.contains { $0.title == "Original Summary" })
    }

    @Test
    func `failed clear reloads persisted summaries when the digest was not loaded`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let persistedDigest = {
            var digest = RecentConversationsDigest()
            digest.upsertSummary(ConversationSummary(id: UUID(), title: "Persisted Summary"))
            return digest
        }()
        let service = ConversationSummaryService(
            store: store,
            summaryLoader: { persistedDigest },
            summarySaveOperation: { _ in }
        )

        let snapshot = service.invalidateForConversationClear()
        service.updateSummary(for: TestHelpers.sampleConversation(title: "Created During Clear"))
        try await service.restoreAfterFailedConversationClear(snapshot)

        #expect(service.digest.summaries.contains { $0.title == "Persisted Summary" })
        #expect(service.digest.summaries.contains { $0.title == "Created During Clear" })
    }

    @Test
    func `explicit memory clear supersedes an older conversation rollback snapshot`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let service = ConversationSummaryService(
            store: store,
            summarySaveOperation: { _ in },
            summaryClearOperation: {}
        )
        service.updateSummary(for: TestHelpers.sampleConversation(title: "Explicitly Cleared"))
        let rollbackSnapshot = service.invalidateForConversationClear()

        try await service.clearAllSummaries()

        await #expect(throws: CancellationError.self) {
            try await service.restoreAfterFailedConversationClear(rollbackSnapshot)
        }
        #expect(service.summaryCount == 0)
    }

    @Test
    func `failed summary rollback save keeps the clear barrier active`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let service = ConversationSummaryService(
            store: store,
            summaryLoader: { RecentConversationsDigest() },
            summarySaveOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        service.updateSummary(for: TestHelpers.sampleConversation(title: "Unsaved Rollback Summary"))
        let snapshot = service.invalidateForConversationClear()

        do {
            try await service.restoreAfterFailedConversationClear(snapshot)
            Issue.record("Expected summary rollback persistence to fail")
        } catch {
            // Expected: the transactional restore must report the persistence failure.
        }
        await service.loadSummaries()

        #expect(service.digest.summaries.first?.title == "Unsaved Rollback Summary")
    }

    @Test
    func `generate summary extracts title and timestamp`() {
        let service = ConversationSummaryService()
        let conversation = TestHelpers.sampleConversation(title: "Test Conversation")

        let summary = service.generateSummary(for: conversation)

        #expect(summary.id == conversation.id)
        #expect(summary.title == "Test Conversation")
        #expect(summary.timestamp == conversation.updatedAt)
    }

    @Test
    func `generate summary extracts user message snippets`() {
        let service = ConversationSummaryService()

        var conversation = Conversation(title: "Chat")
        conversation.addMessage(Message(role: .user, content: "Hello, how are you?"))
        conversation.addMessage(Message(role: .assistant, content: "I'm doing well!"))
        conversation.addMessage(Message(role: .user, content: "Can you help me with Swift?"))

        let summary = service.generateSummary(for: conversation)

        #expect(summary.userMessageSnippets.count == 2)
        #expect(summary.userMessageSnippets.contains { $0.contains("Hello") })
        #expect(summary.userMessageSnippets.contains { $0.contains("Swift") })
    }

    @Test
    func `generate summary limits snippet count`() {
        let service = ConversationSummaryService()

        var conversation = Conversation(title: "Long Chat")
        for index in 1 ... 10 {
            conversation.addMessage(Message(role: .user, content: "User message \(index)"))
            conversation.addMessage(Message(role: .assistant, content: "Response \(index)"))
        }

        let summary = service.generateSummary(for: conversation)

        #expect(summary.userMessageSnippets.count <= ConversationSummary.maxSnippets)
    }

    @Test
    func `generate summary extracts topics from content`() {
        let service = ConversationSummaryService()

        var conversation = Conversation(title: "Swift Discussion")
        conversation.addMessage(Message(role: .user, content: "I want to learn about SwiftUI and Swift concurrency"))
        conversation.addMessage(Message(role: .assistant, content: "Great topics!"))
        conversation.addMessage(Message(role: .user, content: "Tell me more about SwiftUI views and modifiers"))

        let summary = service.generateSummary(for: conversation)

        // Should extract frequent meaningful words
        #expect(!summary.topics.isEmpty)
    }

    // MARK: - Digest Management

    @Test
    func `update summary adds to digest`() {
        let service = ConversationSummaryService()
        let conversation = TestHelpers.sampleConversation(title: "New Chat")

        service.updateSummary(for: conversation)

        #expect(service.summaryCount == 1)
        #expect(service.digest.summaries.first?.title == "New Chat")
    }

    @Test
    func `update summary replaces existing summary for same conversation`() {
        let service = ConversationSummaryService()

        var conversation = TestHelpers.sampleConversation(title: "Original Title")
        service.updateSummary(for: conversation)

        // Update the same conversation with new title
        conversation.title = "Updated Title"
        service.updateSummary(for: conversation)

        #expect(service.summaryCount == 1)
        #expect(service.digest.summaries.first?.title == "Updated Title")
    }

    @Test
    func `remove summary deletes from digest`() {
        let service = ConversationSummaryService()
        let conversation = TestHelpers.sampleConversation()

        service.updateSummary(for: conversation)
        #expect(service.summaryCount == 1)

        service.removeSummary(for: conversation.id)
        #expect(service.summaryCount == 0)
    }

    @Test
    func `digest enforces max summaries limit`() {
        let service = ConversationSummaryService()

        // Add more than max summaries
        for index in 1 ... (RecentConversationsDigest.defaultMaxSummaries + 5) {
            let conversation = TestHelpers.sampleConversation(title: "Chat \(index)")
            service.updateSummary(for: conversation)
        }

        #expect(service.summaryCount <= RecentConversationsDigest.defaultMaxSummaries)
    }

    // MARK: - Context Formatting

    @Test
    func `formatted for context returns nil when empty`() {
        let service = ConversationSummaryService()

        let formatted = service.formattedForContext()

        #expect(formatted == nil)
    }

    @Test
    func `formatted for context includes summaries`() {
        let service = ConversationSummaryService()

        let conversation = TestHelpers.sampleConversation(title: "Important Discussion")
        service.updateSummary(for: conversation)

        let formatted = service.formattedForContext()

        #expect(formatted != nil)
        #expect(formatted?.contains("Recent Conversations") == true)
        #expect(formatted?.contains("Important Discussion") == true)
    }

    @Test
    func `formatted for context excludes specified conversation`() {
        let service = ConversationSummaryService()

        let conversation1 = TestHelpers.sampleConversation(title: "First Chat")
        let conversation2 = TestHelpers.sampleConversation(title: "Second Chat")

        service.updateSummary(for: conversation1)
        service.updateSummary(for: conversation2)

        let formatted = service.formattedForContext(excludeConversationId: conversation1.id)

        #expect(formatted?.contains("First Chat") != true)
        #expect(formatted?.contains("Second Chat") == true)
    }

    @Test
    func `formatted for context respects token budget`() {
        let service = ConversationSummaryService()

        // Add several summaries
        for index in 1 ... 10 {
            let conversation = TestHelpers.sampleConversation(title: "Conversation with a longer title number \(index)")
            service.updateSummary(for: conversation)
        }

        // Very small token budget
        let formatted = service.formattedForContext(tokenBudget: 50)

        // Should have some content but be limited
        #expect(formatted != nil)
        // With tiny budget, shouldn't include all 10 conversations
        let lineCount = formatted?.components(separatedBy: "\n").count ?? 0
        #expect(lineCount < 12) // Header + max ~10 entries
    }

    // MARK: - Backfill

    @Test
    func `backfill summaries creates summaries for existing conversations`() {
        let service = ConversationSummaryService()

        let conversations = [
            TestHelpers.sampleConversation(title: "Chat 1"),
            TestHelpers.sampleConversation(title: "Chat 2"),
            TestHelpers.sampleConversation(title: "Chat 3")
        ]

        service.backfillSummaries(from: conversations)

        #expect(service.summaryCount == 3)
    }

    @Test
    func `backfill summaries respects limit`() {
        let service = ConversationSummaryService()

        let conversations = (1 ... 20).map { index in
            TestHelpers.sampleConversation(title: "Chat \(index)")
        }

        service.backfillSummaries(from: conversations, limit: 5)

        #expect(service.summaryCount == 5)
    }
}

// MARK: - ConversationSummary Tests

@Suite("ConversationSummary Tests")
struct ConversationSummaryTests {
    @Test
    func `formatted for context includes date and title`() {
        let summary = ConversationSummary(
            id: UUID(),
            title: "Test Chat",
            timestamp: Date(),
            userMessageSnippets: ["Hello world"],
            topics: ["swift", "testing"]
        )

        let formatted = summary.formattedForContext()

        #expect(formatted.contains("Test Chat"))
        #expect(formatted.contains("Hello world"))
    }
}

// MARK: - RecentConversationsDigest Tests

@Suite("RecentConversationsDigest Tests")
struct RecentConversationsDigestTests {
    @Test
    func `upsert summary adds new summary`() {
        var digest = RecentConversationsDigest()

        let summary = ConversationSummary(id: UUID(), title: "New Chat")
        digest.upsertSummary(summary)

        #expect(digest.summaries.count == 1)
        #expect(digest.summaries.first?.title == "New Chat")
    }

    @Test
    func `upsert summary updates existing summary`() {
        var digest = RecentConversationsDigest()

        let id = UUID()
        let original = ConversationSummary(id: id, title: "Original")
        digest.upsertSummary(original)

        let updated = ConversationSummary(id: id, title: "Updated")
        digest.upsertSummary(updated)

        #expect(digest.summaries.count == 1)
        #expect(digest.summaries.first?.title == "Updated")
    }

    @Test
    func `prune older removes old summaries`() throws {
        var digest = RecentConversationsDigest()

        let oldDate = try #require(Calendar.current.date(byAdding: .day, value: -10, to: Date()))
        let oldSummary = ConversationSummary(id: UUID(), title: "Old", timestamp: oldDate)
        let newSummary = ConversationSummary(id: UUID(), title: "New", timestamp: Date())

        digest.upsertSummary(oldSummary)
        digest.upsertSummary(newSummary)

        digest.pruneOlder(than: 7)

        #expect(digest.summaries.count == 1)
        #expect(digest.summaries.first?.title == "New")
    }
}

private actor ConversationSummaryLoadGate {
    private let digest: RecentConversationsDigest
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(digest: RecentConversationsDigest) {
        self.digest = digest
    }

    func load() async throws -> RecentConversationsDigest {
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        return digest
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}

private actor ConversationSummarySaveGate {
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}

private final class SummaryPersistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var digest: RecentConversationsDigest?
    private var clearCalled = false

    var persistedDigest: RecentConversationsDigest? {
        lock.withLock { digest }
    }

    var wasCleared: Bool {
        lock.withLock { clearCalled }
    }

    func save(_ digest: RecentConversationsDigest) {
        lock.withLock {
            self.digest = digest
        }
    }

    func clear() {
        lock.withLock {
            digest = nil
            clearCalled = true
        }
    }
}

private final class BlockingSummaryClearOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func run() {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func hasStarted() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
