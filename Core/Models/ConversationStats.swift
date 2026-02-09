//
//  ConversationStats.swift
//  ayna
//
//  Statistics for a conversation including message counts, word count, and duration.
//

import Foundation

/// Statistics computed from a conversation's messages.
struct ConversationStats: Sendable, Equatable {
    /// Total number of messages in the conversation
    let totalMessages: Int

    /// Number of messages from the user
    let userMessages: Int

    /// Number of messages from the assistant
    let assistantMessages: Int

    /// Total word count across all messages
    let wordCount: Int

    /// Duration of the conversation (from first to last message)
    let duration: TimeInterval

    // MARK: - Initialization

    init(
        totalMessages: Int,
        userMessages: Int,
        assistantMessages: Int,
        wordCount: Int,
        duration: TimeInterval
    ) {
        self.totalMessages = totalMessages
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
        self.wordCount = wordCount
        self.duration = duration
    }

    /// Creates statistics from an array of messages.
    /// - Parameter messages: The messages to analyze
    /// - Returns: Computed statistics for the messages
    init(from messages: [Message]) {
        var userCount = 0
        var assistantCount = 0
        var totalWords = 0
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        for message in messages {
            // Count by role
            switch message.role {
            case .user:
                userCount += 1
            case .assistant:
                assistantCount += 1
            case .system, .tool:
                break
            }

            // Count words in content
            let words = message.content.split { $0.isWhitespace || $0.isNewline }
            totalWords += words.count

            // Track timestamps for duration
            if firstTimestamp == nil || message.timestamp < firstTimestamp! {
                firstTimestamp = message.timestamp
            }
            if lastTimestamp == nil || message.timestamp > lastTimestamp! {
                lastTimestamp = message.timestamp
            }
        }

        // Calculate duration
        let calculatedDuration: TimeInterval
        if let first = firstTimestamp, let last = lastTimestamp {
            calculatedDuration = last.timeIntervalSince(first)
        } else {
            calculatedDuration = 0
        }

        self.totalMessages = messages.count
        self.userMessages = userCount
        self.assistantMessages = assistantCount
        self.wordCount = totalWords
        self.duration = calculatedDuration
    }

    // MARK: - Formatted Output

    /// Returns a human-readable string for the conversation duration.
    var formattedDuration: String {
        if duration < 60 {
            return "Less than a minute"
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2

        return formatter.string(from: duration) ?? "Unknown"
    }
}
