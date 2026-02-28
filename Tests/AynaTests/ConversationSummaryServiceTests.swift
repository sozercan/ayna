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

    @Test("Generate summary extracts title and timestamp")
    func generateSummaryExtractsTitleAndTimestamp() {
        let service = ConversationSummaryService()
        let conversation = TestHelpers.sampleConversation(title: "Test Conversation")

        let summary = service.generateSummary(for: conversation)

        #expect(summary.id == conversation.id)
        #expect(summary.title == "Test Conversation")
        #expect(summary.timestamp == conversation.updatedAt)
    }

    @Test("Generate summary extracts user message snippets")
    func generateSummaryExtractsUserMessageSnippets() {
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

    @Test("Generate summary limits snippet count")
    func generateSummaryLimitsSnippetCount() {
        let service = ConversationSummaryService()

        var conversation = Conversation(title: "Long Chat")
        for index in 1 ... 10 {
            conversation.addMessage(Message(role: .user, content: "User message \(index)"))
            conversation.addMessage(Message(role: .assistant, content: "Response \(index)"))
        }

        let summary = service.generateSummary(for: conversation)

        #expect(summary.userMessageSnippets.count <= ConversationSummary.maxSnippets)
    }

    @Test("Generate summary extracts topics from content")
    func generateSummaryExtractsTopics() {
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

    @Test("Update summary adds to digest")
    func updateSummaryAddsToDigest() {
        let service = ConversationSummaryService()
        let conversation = TestHelpers.sampleConversation(title: "New Chat")

        service.updateSummary(for: conversation)

        #expect(service.summaryCount == 1)
        #expect(service.digest.summaries.first?.title == "New Chat")
    }

    @Test("Update summary replaces existing summary for same conversation")
    func updateSummaryReplacesExisting() {
        let service = ConversationSummaryService()

        var conversation = TestHelpers.sampleConversation(title: "Original Title")
        service.updateSummary(for: conversation)

        // Update the same conversation with new title
        conversation.title = "Updated Title"
        service.updateSummary(for: conversation)

        #expect(service.summaryCount == 1)
        #expect(service.digest.summaries.first?.title == "Updated Title")
    }

    @Test("Remove summary deletes from digest")
    func removeSummaryDeletesFromDigest() {
        let service = ConversationSummaryService()
        let conversation = TestHelpers.sampleConversation()

        service.updateSummary(for: conversation)
        #expect(service.summaryCount == 1)

        service.removeSummary(for: conversation.id)
        #expect(service.summaryCount == 0)
    }

    @Test("Digest enforces max summaries limit")
    func digestEnforcesMaxSummariesLimit() {
        let service = ConversationSummaryService()

        // Add more than max summaries
        for index in 1 ... (RecentConversationsDigest.defaultMaxSummaries + 5) {
            let conversation = TestHelpers.sampleConversation(title: "Chat \(index)")
            service.updateSummary(for: conversation)
        }

        #expect(service.summaryCount <= RecentConversationsDigest.defaultMaxSummaries)
    }

    // MARK: - Context Formatting

    @Test("Formatted for context returns nil when empty")
    func formattedForContextReturnsNilWhenEmpty() {
        let service = ConversationSummaryService()

        let formatted = service.formattedForContext()

        #expect(formatted == nil)
    }

    @Test("Formatted for context includes summaries")
    func formattedForContextIncludesSummaries() {
        let service = ConversationSummaryService()

        let conversation = TestHelpers.sampleConversation(title: "Important Discussion")
        service.updateSummary(for: conversation)

        let formatted = service.formattedForContext()

        #expect(formatted != nil)
        #expect(formatted?.contains("Recent Conversations") == true)
        #expect(formatted?.contains("Important Discussion") == true)
    }

    @Test("Formatted for context excludes specified conversation")
    func formattedForContextExcludesSpecifiedConversation() {
        let service = ConversationSummaryService()

        let conversation1 = TestHelpers.sampleConversation(title: "First Chat")
        let conversation2 = TestHelpers.sampleConversation(title: "Second Chat")

        service.updateSummary(for: conversation1)
        service.updateSummary(for: conversation2)

        let formatted = service.formattedForContext(excludeConversationId: conversation1.id)

        #expect(formatted?.contains("First Chat") != true)
        #expect(formatted?.contains("Second Chat") == true)
    }

    @Test("Formatted for context respects token budget")
    func formattedForContextRespectsTokenBudget() {
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

    @Test("Backfill summaries creates summaries for existing conversations")
    func backfillSummariesCreatesForExistingConversations() {
        let service = ConversationSummaryService()

        let conversations = [
            TestHelpers.sampleConversation(title: "Chat 1"),
            TestHelpers.sampleConversation(title: "Chat 2"),
            TestHelpers.sampleConversation(title: "Chat 3")
        ]

        service.backfillSummaries(from: conversations)

        #expect(service.summaryCount == 3)
    }

    @Test("Backfill summaries respects limit")
    func backfillSummariesRespectsLimit() {
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
    @Test("Formatted for context includes date and title")
    func formattedForContextIncludesDateAndTitle() {
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
    @Test("Upsert summary adds new summary")
    func upsertSummaryAddsNewSummary() {
        var digest = RecentConversationsDigest()

        let summary = ConversationSummary(id: UUID(), title: "New Chat")
        digest.upsertSummary(summary)

        #expect(digest.summaries.count == 1)
        #expect(digest.summaries.first?.title == "New Chat")
    }

    @Test("Upsert summary updates existing summary")
    func upsertSummaryUpdatesExisting() {
        var digest = RecentConversationsDigest()

        let id = UUID()
        let original = ConversationSummary(id: id, title: "Original")
        digest.upsertSummary(original)

        let updated = ConversationSummary(id: id, title: "Updated")
        digest.upsertSummary(updated)

        #expect(digest.summaries.count == 1)
        #expect(digest.summaries.first?.title == "Updated")
    }

    @Test("Prune older removes old summaries")
    func pruneOlderRemovesOldSummaries() throws {
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
