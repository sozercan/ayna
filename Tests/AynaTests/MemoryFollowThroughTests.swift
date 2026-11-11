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
        try? await Task.sleep(for: .milliseconds(50))
        extractor.conversationDidSave(conversation)
        try? await Task.sleep(for: .milliseconds(100))
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
