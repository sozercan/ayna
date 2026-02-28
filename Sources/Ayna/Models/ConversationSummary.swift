//
//  ConversationSummary.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation

/// A lightweight summary of a conversation for context injection.
/// Only stores key user messages, not full conversation history.
struct ConversationSummary: Identifiable, Codable, Sendable {
    let id: UUID // Matches conversation ID
    var title: String
    var timestamp: Date
    var userMessageSnippets: [String] // Key user messages (not assistant)
    var topics: [String] // Extracted topics/keywords

    init(
        id: UUID,
        title: String,
        timestamp: Date = Date(),
        userMessageSnippets: [String] = [],
        topics: [String] = []
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.userMessageSnippets = userMessageSnippets
        self.topics = topics
    }

    /// Maximum number of snippets to store per conversation
    static let maxSnippets = 3

    /// Maximum length of each snippet
    static let maxSnippetLength = 100

    /// Formats the summary for display in the context.
    /// Uses ChatGPT-style |||| delimiters for user messages.
    func formattedForContext() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        var lines = ["\(dateFormatter.string(from: timestamp)): \(title)"]

        for snippet in userMessageSnippets {
            lines.append("   |||| \(snippet) ||||")
        }

        return lines.joined(separator: "\n")
    }
}

/// Container for recent conversation summaries.
struct RecentConversationsDigest: Codable, Sendable {
    var summaries: [ConversationSummary]
    var lastComputed: Date
    var maxSummaries: Int

    /// Default maximum number of summaries to keep (matches ChatGPT's ~15)
    static let defaultMaxSummaries = 15

    init(
        summaries: [ConversationSummary] = [],
        lastComputed: Date = Date(),
        maxSummaries: Int = defaultMaxSummaries
    ) {
        self.summaries = summaries
        self.lastComputed = lastComputed
        self.maxSummaries = maxSummaries
    }

    /// Adds or updates a summary, maintaining the max limit.
    mutating func upsertSummary(_ summary: ConversationSummary) {
        // Remove existing summary for the same conversation
        summaries.removeAll { $0.id == summary.id }

        // Add the new summary
        summaries.insert(summary, at: 0)

        // Sort by timestamp descending
        summaries.sort { $0.timestamp > $1.timestamp }

        // Prune to max
        if summaries.count > maxSummaries {
            summaries = Array(summaries.prefix(maxSummaries))
        }

        lastComputed = Date()
    }

    /// Removes a summary by conversation ID.
    mutating func removeSummary(for conversationId: UUID) {
        summaries.removeAll { $0.id == conversationId }
        lastComputed = Date()
    }

    /// Formats all summaries for context injection.
    func formattedForContext() -> String {
        guard !summaries.isEmpty else { return "" }

        var lines = ["Recent Conversations:"]

        for (index, summary) in summaries.enumerated() {
            let formatted = summary.formattedForContext()
            lines.append("\(index + 1). \(formatted)")
        }

        return lines.joined(separator: "\n")
    }

    /// Prunes summaries older than the specified days.
    mutating func pruneOlder(than days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        summaries.removeAll { $0.timestamp < cutoff }
        lastComputed = Date()
    }
}
