@testable import Ayna
import Foundation
import Testing

@Suite("ConversationStats Tests", .tags(.fast))
struct ConversationStatsTests {
    // MARK: - Initialization Tests

    @Test("Init with all properties")
    func initWithAllProperties() {
        let stats = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        #expect(stats.totalMessages == 10)
        #expect(stats.userMessages == 5)
        #expect(stats.assistantMessages == 5)
        #expect(stats.wordCount == 100)
        #expect(stats.duration == 3600)
    }

    @Test("Init from empty messages array")
    func initFromEmptyMessages() {
        let stats = ConversationStats(from: [])

        #expect(stats.totalMessages == 0)
        #expect(stats.userMessages == 0)
        #expect(stats.assistantMessages == 0)
        #expect(stats.wordCount == 0)
        #expect(stats.duration == 0)
    }

    @Test("Init from messages with user and assistant roles")
    func initFromMessagesWithRoles() {
        let now = Date()
        let messages = [
            Message(role: .user, content: "Hello there"),
            Message(role: .assistant, content: "Hi! How can I help you today?"),
            Message(role: .user, content: "What is Swift?"),
            Message(role: .assistant, content: "Swift is a programming language by Apple."),
        ]

        let stats = ConversationStats(from: messages)

        #expect(stats.totalMessages == 4)
        #expect(stats.userMessages == 2)
        #expect(stats.assistantMessages == 2)
    }

    @Test("Init from messages counts words correctly")
    func initFromMessagesCountsWords() {
        let messages = [
            Message(role: .user, content: "one two three"),
            Message(role: .assistant, content: "four five"),
        ]

        let stats = ConversationStats(from: messages)

        #expect(stats.wordCount == 5)
    }

    @Test("Init from messages excludes system and tool messages from role counts")
    func initFromMessagesExcludesSystemAndTool() {
        let messages = [
            Message(role: .system, content: "You are a helpful assistant."),
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi there!"),
            Message(role: .tool, content: "Tool result here"),
        ]

        let stats = ConversationStats(from: messages)

        #expect(stats.totalMessages == 4)
        #expect(stats.userMessages == 1)
        #expect(stats.assistantMessages == 1)
        // System and tool words are still counted
        #expect(stats.wordCount == 10)
    }

    @Test("Init from messages calculates duration correctly")
    func initFromMessagesCalculatesDuration() {
        let now = Date()
        let hourAgo = now.addingTimeInterval(-3600)

        // Create messages with explicit timestamps
        let message1 = Message(
            id: UUID(),
            role: .user,
            content: "First message",
            timestamp: hourAgo,
            isLiked: false
        )
        let message2 = Message(
            id: UUID(),
            role: .assistant,
            content: "Last message",
            timestamp: now,
            isLiked: false
        )

        let stats = ConversationStats(from: [message1, message2])

        #expect(stats.duration == 3600)
    }

    @Test("Init from single message has zero duration")
    func initFromSingleMessageZeroDuration() {
        let message = Message(role: .user, content: "Just one message")

        let stats = ConversationStats(from: [message])

        #expect(stats.duration == 0)
    }

    // MARK: - Formatted Duration Tests

    @Test("Formatted duration for less than a minute")
    func formattedDurationLessThanMinute() {
        let stats = ConversationStats(
            totalMessages: 1,
            userMessages: 1,
            assistantMessages: 0,
            wordCount: 5,
            duration: 30
        )

        #expect(stats.formattedDuration == "Less than a minute")
    }

    @Test("Formatted duration for zero")
    func formattedDurationZero() {
        let stats = ConversationStats(
            totalMessages: 0,
            userMessages: 0,
            assistantMessages: 0,
            wordCount: 0,
            duration: 0
        )

        #expect(stats.formattedDuration == "Less than a minute")
    }

    @Test("Formatted duration for one hour")
    func formattedDurationOneHour() {
        let stats = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        #expect(stats.formattedDuration == "1h")
    }

    @Test("Formatted duration for hours and minutes")
    func formattedDurationHoursAndMinutes() {
        let stats = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 5400 // 1.5 hours
        )

        #expect(stats.formattedDuration == "1h 30m")
    }

    // MARK: - Equatable Tests

    @Test("Equality")
    func equality() {
        let stats1 = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        let stats2 = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        #expect(stats1 == stats2)
    }

    @Test("Inequality with different total messages")
    func inequalityDifferentTotalMessages() {
        let stats1 = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        let stats2 = ConversationStats(
            totalMessages: 20,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        #expect(stats1 != stats2)
    }

    @Test("Inequality with different word count")
    func inequalityDifferentWordCount() {
        let stats1 = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        let stats2 = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 200,
            duration: 3600
        )

        #expect(stats1 != stats2)
    }

    // MARK: - Sendable Conformance

    @Test("Sendable conformance allows passing across actors")
    func sendableConformance() async {
        let stats = ConversationStats(
            totalMessages: 10,
            userMessages: 5,
            assistantMessages: 5,
            wordCount: 100,
            duration: 3600
        )

        // This should compile without issues if Sendable is properly implemented
        let result = await Task.detached {
            stats.totalMessages
        }.value

        #expect(result == 10)
    }

    // MARK: - Word Counting Edge Cases

    @Test("Word count handles multiple whitespace")
    func wordCountMultipleWhitespace() {
        let messages = [
            Message(role: .user, content: "one   two    three"),
        ]

        let stats = ConversationStats(from: messages)

        #expect(stats.wordCount == 3)
    }

    @Test("Word count handles newlines")
    func wordCountNewlines() {
        let messages = [
            Message(role: .user, content: "one\ntwo\nthree"),
        ]

        let stats = ConversationStats(from: messages)

        #expect(stats.wordCount == 3)
    }

    @Test("Word count handles mixed whitespace and newlines")
    func wordCountMixedWhitespaceNewlines() {
        let messages = [
            Message(role: .user, content: "one  \n  two\n\n  three  "),
        ]

        let stats = ConversationStats(from: messages)

        #expect(stats.wordCount == 3)
    }

    @Test("Word count handles empty content")
    func wordCountEmptyContent() {
        let messages = [
            Message(role: .user, content: ""),
            Message(role: .assistant, content: "   "),
        ]

        let stats = ConversationStats(from: messages)

        #expect(stats.wordCount == 0)
    }
}
