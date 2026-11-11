// swiftlint:disable identifier_name
@testable import Ayna
import Foundation
import Testing

/// Collects values from @Sendable callbacks.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] {
        lock.withLock { stored }
    }

    func record(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}

@Suite("Conversation summaries follow storage", .serialized)
@MainActor
struct ConversationSummaryStorageTests {
    @Test
    func `A summary made before the stored digest loads is added to it, not swapped for it`() async {
        let stored = ConversationSummary(id: UUID(), title: "Stored earlier")
        let saved = Recorder<RecentConversationsDigest>()
        let service = ConversationSummaryService(
            summaryLoader: {
                var digest = RecentConversationsDigest()
                digest.upsertSummary(stored)
                return digest
            },
            summarySaveOperation: { saved.record($0) },
            existingConversationIdsLoader: nil
        )

        service.updateSummary(for: TestHelpers.sampleConversation(title: "Made before load"))
        #expect(saved.values.isEmpty)
        await service.loadSummaries()

        #expect(Set(service.digest.summaries.map(\.title)) == ["Stored earlier", "Made before load"])
        await service.saveImmediately()
        #expect(saved.values.last?.summaries.count == 2)
    }

    @Test
    func `A failed load keeps queued summaries for the next load`() async {
        let attempts = Recorder<Int>()
        let stored = ConversationSummary(id: UUID(), title: "Stored")
        let service = ConversationSummaryService(
            summaryLoader: {
                attempts.record(1)
                if attempts.values.count == 1 { throw CocoaError(.fileReadCorruptFile) }
                var digest = RecentConversationsDigest()
                digest.upsertSummary(stored)
                return digest
            },
            summarySaveOperation: { _ in },
            existingConversationIdsLoader: nil
        )
        service.updateSummary(for: TestHelpers.sampleConversation(title: "Queued"))

        await service.loadSummaries()
        #expect(!service.isLoaded)
        await service.loadSummaries()

        #expect(Set(service.digest.summaries.map(\.title)) == ["Stored", "Queued"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `Concurrent loads share one load`() async {
        let started = FlightTestSignal()
        let release = FlightTestSignal()
        let calls = Recorder<Int>()
        let service = ConversationSummaryService(
            summaryLoader: {
                calls.record(1)
                started.signal()
                await release.wait()
                return RecentConversationsDigest()
            },
            summarySaveOperation: { _ in },
            existingConversationIdsLoader: nil
        )
        let first = Task { await service.loadSummaries() }
        await started.wait()
        let second = Task { await service.loadSummaries() }
        await Task.yield()
        release.signal()
        await first.value
        await second.value

        #expect(calls.values.count == 1)
    }

    @Test
    func `Sidecars without attachment paths are rebuilt`() throws {
        // A sidecar from before attachment paths were recorded has every other field.
        var older = ConversationMetadata(conversation: TestHelpers.sampleConversation(title: "Older"))
        older.attachmentPaths = nil
        let decoded = try JSONDecoder().decode(ConversationMetadata.self, from: JSONEncoder().encode(older))

        #expect(decoded.attachmentPaths == nil)
        #expect(decoded.requiresBackfill)
        let current = ConversationMetadata(conversation: TestHelpers.sampleConversation(title: "Current"))
        #expect(try !JSONDecoder().decode(ConversationMetadata.self, from: JSONEncoder().encode(current)).requiresBackfill)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A conversation received from the Watch gets a summary`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let updated = Recorder<UUID>()
        let manager = ConversationManager(
            store: TestHelpers.makeTestStore(directory: directory),
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupEnabled: false,
            conversationSummaryUpdateOperation: { updated.record($0.id) }
        )
        _ = await manager.loadingTask?.value
        let received = TestHelpers.sampleConversation(title: "From the Watch")

        // The Watch path saves first, then commits the conversation into the manager.
        #expect(await manager.persistProposedConversation(received).value == .saved)
        manager.commitPersistedConversation(received)

        #expect(updated.values.contains(received.id))
    }

    @Test
    func `Summaries of deleted conversations are dropped when the digest loads`() async {
        let kept = ConversationSummary(id: UUID(), title: "Kept")
        let deleted = ConversationSummary(id: UUID(), title: "Deleted while memory was off")
        let service = ConversationSummaryService(
            summaryLoader: {
                var digest = RecentConversationsDigest()
                digest.upsertSummary(kept)
                digest.upsertSummary(deleted)
                return digest
            },
            summarySaveOperation: { _ in },
            existingConversationIdsLoader: { [kept.id] }
        )

        await service.loadSummaries()

        #expect(service.digest.summaries.map(\.id) == [kept.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func `Every durable save refreshes the conversation's summary`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let updated = Recorder<String>()
        let manager = ConversationManager(
            store: TestHelpers.makeTestStore(directory: directory),
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupEnabled: false,
            conversationSummaryUpdateOperation: { updated.record($0.title) }
        )
        _ = await manager.loadingTask?.value

        var conversation = TestHelpers.sampleConversation(title: "Saved normally")
        manager.conversations.insert(conversation, at: 0)
        conversation.title = "Saved normally"
        manager.updateConversation(conversation)
        await manager.flushPendingSaves()

        #expect(updated.values.contains("Saved normally"))
    }
}

private struct InMemoryUserMemoryStore: UserMemoryStoreAdapter {
    func loadMemory() async throws -> UserMemoryStore {
        UserMemoryStore()
    }

    func saveMemory(_: UserMemoryStore) async throws {}
    func clearMemory() async throws {}
}

/// Holds a synchronous persistence operation until the test releases it.
private final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    let entered = FlightTestSignal()

    func hold() {
        entered.signal()
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !released, condition.wait(until: deadline) {}
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@Suite("Clear All Memory", .serialized)
@MainActor
struct ClearAllMemoryTests {
    @Test(.timeLimit(.minutes(1)))
    func `Saves during a clear do not bring summaries back`() async throws {
        let gate = BlockingGate()
        let summaryService = ConversationSummaryService(
            summaryLoader: { RecentConversationsDigest() },
            summarySaveOperation: { _ in },
            summaryClearOperation: { gate.hold() },
            existingConversationIdsLoader: nil
        )
        await summaryService.loadSummaries()
        let provider = MemoryContextProvider(
            memoryService: UserMemoryService(store: InMemoryUserMemoryStore()),
            metadataService: SessionMetadataService.shared,
            summaryService: summaryService,
            factExtractor: MemoryFactExtractor(generate: { _, _ in "[]" }, existingFacts: { [] }, storeFact: { _ in })
        )
        provider.setMemoryEnabled(true)
        defer { provider.setMemoryEnabled(false) }

        let clear = Task { try await provider.clearAllMemory() }
        await gate.entered.wait()
        provider.updateConversationSummary(TestHelpers.sampleConversation(title: "Saved mid-clear"))
        gate.release()
        try await clear.value

        #expect(summaryService.summaryCount == 0)
    }
}

@Suite("Conversation attachments", .serialized)
@MainActor
struct ConversationAttachmentCleanupTests {
    private func conversationWithFiles() -> Conversation {
        var conversation = TestHelpers.sampleConversation(title: "With files")
        conversation.addMessage(Message(
            role: .user,
            content: "Look",
            attachments: [Message.FileAttachment(fileName: "a.png", mimeType: "image/png", localPath: "a.png")]
        ))
        conversation.addMessage(Message(role: .assistant, content: "", mediaType: .image, imagePath: "generated.png"))
        return conversation
    }

    @Test(.timeLimit(.minutes(1)))
    func `Deleting a conversation that was never opened deletes its files`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let conversation = conversationWithFiles()
        try await store.save(conversation)
        let deleted = Recorder<[String]>()
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupEnabled: false,
            attachmentDeleteOperation: { deleted.record($0) }
        )
        _ = await manager.loadingTask?.value
        let placeholder = try #require(manager.conversations.first)
        #expect(manager.isMetadataOnlyConversation(placeholder.id))

        let deletion = manager.deleteConversation(placeholder)
        #expect(await deletion?.value == .deleted)

        #expect(deleted.values == [["a.png", "generated.png"]])
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed deletion keeps the files`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let deleted = Recorder<[String]>()
        let manager = ConversationManager(
            store: TestHelpers.makeTestStore(directory: directory),
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupEnabled: false,
            attachmentDeleteOperation: { deleted.record($0) },
            deleteOperation: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        _ = await manager.loadingTask?.value
        let conversation = conversationWithFiles()
        manager.conversations.insert(conversation, at: 0)

        _ = await manager.deleteConversation(conversation)?.value

        #expect(deleted.values.isEmpty)
    }
}

@Suite("Conversation export")
struct ConversationExportSelectionTests {
    @Test
    func `Multi-model turns export only the selected response`() {
        var conversation = Conversation(title: "Compare", model: "model-a")
        let question = Message(role: .user, content: "Which is faster?")
        let groupID = UUID()
        let chosen = Message(role: .assistant, content: "Chosen answer", model: "model-a", responseGroupId: groupID)
        let other = Message(role: .assistant, content: "Other answer", model: "model-b", responseGroupId: groupID)
        conversation.addMessage(question)
        conversation.addMessage(chosen)
        conversation.addMessage(other)
        conversation.responseGroups = [ResponseGroup(
            id: groupID,
            userMessageId: question.id,
            responses: [
                ResponseGroupEntry(id: chosen.id, modelName: "model-a", status: .selected),
                ResponseGroupEntry(id: other.id, modelName: "model-b", status: .completed)
            ],
            selectedResponseId: chosen.id
        )]

        let markdown = ConversationExporter.generateMarkdown(for: conversation)

        #expect(markdown.contains("Chosen answer"))
        #expect(!markdown.contains("Other answer"))
    }
}

@Suite("Memory fact extraction", .serialized)
@MainActor
struct MemoryFactExtractorTests {
    @Test
    func `Replies are parsed leniently and capped`() {
        #expect(MemoryFactExtractor.parseFacts("```json\n[\"Works as a nurse\", \"Lives in Oslo\"]\n```") == [
            "Works as a nurse", "Lives in Oslo"
        ])
        #expect(MemoryFactExtractor.parseFacts("[]").isEmpty)
        #expect(MemoryFactExtractor.parseFacts("No facts here").isEmpty)
        #expect(MemoryFactExtractor.parseFacts(#"["a", "b", "c", "d"]"#).count == MemoryFactExtractor.maximumFactsPerPass)
    }

    @Test
    func `New facts are stored once and messages are read once`() async {
        let prompts = Recorder<String>()
        let stored = Recorder<String>()
        let extractor = MemoryFactExtractor(
            idleDelay: .zero,
            generate: { prompt, _ in
                prompts.record(prompt)
                return #"["Prefers metric units", "Uses a standing desk"]"#
            },
            existingFacts: { [UserMemoryFact(content: "Uses a standing desk")] },
            storeFact: { stored.record($0) }
        )
        var conversation = Conversation(title: "Chat", model: "any-model")
        conversation.addMessage(Message(role: .user, content: "Please answer in metric units, always."))

        await extractor.extract(from: conversation)
        await extractor.extract(from: conversation)

        #expect(stored.values == ["Prefers metric units"])
        #expect(prompts.values.count == 1)
        #expect(prompts.values.first?.contains("Uses a standing desk") == true)
        #expect(prompts.values.first?.contains("metric units, always") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Cancelling during generation stores nothing`() async {
        let started = FlightTestSignal()
        let release = FlightTestSignal()
        let stored = Recorder<String>()
        let extractor = MemoryFactExtractor(
            idleDelay: .zero,
            generate: { _, _ in
                started.signal()
                await release.wait()
                return #"["Lives in Lisbon"]"#
            },
            existingFacts: { [] },
            storeFact: { stored.record($0) }
        )
        var conversation = Conversation(title: "Chat", model: "any-model")
        conversation.addMessage(Message(role: .user, content: "I live in Lisbon."))

        extractor.conversationDidSave(conversation)
        await started.wait()
        extractor.cancel(conversationId: conversation.id)
        release.signal()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(stored.values.isEmpty)
    }

    @Test
    func `Messages left out of a prompt are read in a later pass`() async {
        let prompts = Recorder<String>()
        let extractor = MemoryFactExtractor(
            generate: { prompt, _ in prompts.record(prompt); return "[]" },
            existingFacts: { [] },
            storeFact: { _ in }
        )
        var conversation = Conversation(title: "Chat", model: "any-model")
        conversation.addMessage(Message(role: .user, content: "older " + String(repeating: "a", count: 2000)))
        conversation.addMessage(Message(role: .user, content: "newer " + String(repeating: "b", count: 2000)))

        await extractor.extract(from: conversation)
        await extractor.extract(from: conversation)

        #expect(prompts.values.count == 2)
        #expect(prompts.values.first?.contains("newer ") == true)
        #expect(prompts.values.first?.contains("older ") == false)
        #expect(prompts.values.last?.contains("older ") == true)
    }

    @Test
    func `A long fact list does not overflow the prompt`() {
        let facts = (0 ..< 200).map { "Fact number \($0) " + String(repeating: "x", count: 150) }
        let message = Message(role: .user, content: "I moved to Porto.")

        let request = MemoryFactExtractor.prompt(userMessages: [message], existingFacts: facts)

        #expect(request.prompt.count < 6000)
        #expect(request.prompt.contains("I moved to Porto."))
        #expect(request.includedMessageIDs == [message.id])
    }

    @Test
    func `Facts stored while the model answered are not duplicated`() async {
        let facts = Recorder<String>()
        let extractor = MemoryFactExtractor(
            generate: { _, _ in
                facts.record("Lives in Lisbon") // Another pass stored it meanwhile
                return #"["Lives in Lisbon"]"#
            },
            existingFacts: { facts.values.map { UserMemoryFact(content: $0) } },
            storeFact: { facts.record($0) }
        )
        var conversation = Conversation(title: "Chat", model: "any-model")
        conversation.addMessage(Message(role: .user, content: "I live in Lisbon."))

        await extractor.extract(from: conversation)

        #expect(facts.values == ["Lives in Lisbon"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `Extraction waits for the conversation to go quiet`() async {
        let calls = Recorder<Int>()
        let extractor = MemoryFactExtractor(
            idleDelay: .seconds(1),
            generate: { _, _ in calls.record(1); return "[]" },
            existingFacts: { [] },
            storeFact: { _ in }
        )
        var conversation = Conversation(title: "Chat", model: "any-model")
        conversation.addMessage(Message(role: .user, content: "I live in Lisbon."))

        extractor.conversationDidSave(conversation)
        extractor.conversationDidSave(conversation)
        await Task.yield()
        #expect(calls.values.isEmpty)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while calls.values.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        // The first timer was replaced by the second save, so extraction ran once.
        #expect(calls.values.count == 1)
    }
}

// swiftlint:enable identifier_name
