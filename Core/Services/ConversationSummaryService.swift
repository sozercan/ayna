//
//  ConversationSummaryService.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation
import os.log

/// Service for managing conversation summaries.
/// Summaries are lightweight digests of recent conversations for context injection.
@MainActor
@Observable
final class ConversationSummaryService {
    static let shared = ConversationSummaryService()

    private(set) var digest: RecentConversationsDigest = .init()
    private(set) var isLoaded = false

    private let store: EncryptedMemoryStore
    private nonisolated(unsafe) var saveTask: Task<Void, Never>?
    private let saveDebounceDuration: Duration = .seconds(2)

    /// Conversations pending summarization (debounced)
    private var pendingSummarization: Set<UUID> = []
    private nonisolated(unsafe) var summarizationTask: Task<Void, Never>?
    private let summarizationDebounce: Duration = .seconds(300) // 5 minutes

    /// Token budget for summaries context (approximate)
    static let defaultTokenBudget = 500

    init(store: EncryptedMemoryStore = .shared) {
        self.store = store
    }

    deinit {
        saveTask?.cancel()
        summarizationTask?.cancel()
    }

    // MARK: - Loading

    /// Loads summaries from encrypted storage.
    func loadSummaries() async {
        do {
            digest = try await store.loadSummaries()
            isLoaded = true

            DiagnosticsLogger.log(
                .conversationManager,
                level: .info,
                message: "✅ Loaded conversation summaries",
                metadata: ["count": "\(digest.summaries.count)"]
            )
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "❌ Failed to load conversation summaries",
                metadata: ["error": error.localizedDescription]
            )
            digest = RecentConversationsDigest()
            isLoaded = true
        }
    }

    // MARK: - Summary Generation

    /// Generates a summary for a conversation.
    /// Uses simple extraction (not AI) for efficiency.
    func generateSummary(for conversation: Conversation) -> ConversationSummary {
        // Extract key user messages
        let userMessages = conversation.messages
            .filter { $0.role == .user }
            .map(\.content)

        // Take first few messages as snippets
        let snippets = userMessages
            .prefix(ConversationSummary.maxSnippets)
            .map { String($0.prefix(ConversationSummary.maxSnippetLength)) }

        // Extract simple topics from content (keywords)
        let topics = extractTopics(from: userMessages)

        return ConversationSummary(
            id: conversation.id,
            title: conversation.title,
            timestamp: conversation.updatedAt,
            userMessageSnippets: Array(snippets),
            topics: topics
        )
    }

    /// Extracts simple topics/keywords from messages.
    private func extractTopics(from messages: [String]) -> [String] {
        // Common words to ignore
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "must", "shall", "can", "need", "dare",
            "ought", "used", "to", "of", "in", "for", "on", "with", "at", "by",
            "from", "as", "into", "through", "during", "before", "after", "above",
            "below", "between", "under", "again", "further", "then", "once", "here",
            "there", "when", "where", "why", "how", "all", "each", "few", "more",
            "most", "other", "some", "such", "no", "nor", "not", "only", "own",
            "same", "so", "than", "too", "very", "just", "and", "but", "or", "if",
            "this", "that", "these", "those", "what", "which", "who", "whom",
            "i", "me", "my", "we", "our", "you", "your", "he", "him", "his",
            "she", "her", "it", "its", "they", "them", "their", "please", "help",
            "want", "like", "know", "think", "make", "get", "go", "see", "come"
        ]

        // Combine all messages and extract words
        let allText = messages.joined(separator: " ")
        let words = allText
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }

        // Count word frequency
        var wordCounts: [String: Int] = [:]
        for word in words {
            wordCounts[word, default: 0] += 1
        }

        // Return top 5 most frequent words
        return wordCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
    }

    /// Updates the digest with a new summary.
    func updateSummary(for conversation: Conversation) {
        let summary = generateSummary(for: conversation)
        digest.upsertSummary(summary)
        scheduleSave()
    }

    /// Removes a summary when a conversation is deleted.
    func removeSummary(for conversationId: UUID) {
        digest.removeSummary(for: conversationId)
        scheduleSave()
    }

    /// Marks a conversation as needing summarization (debounced).
    func markNeedsSummary(_ conversationId: UUID) {
        pendingSummarization.insert(conversationId)
        scheduleSummarization()
    }

    /// Processes pending summarizations.
    private func scheduleSummarization() {
        summarizationTask?.cancel()
        summarizationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.summarizationDebounce ?? .seconds(300))
            } catch {
                return // Cancelled
            }

            await self?.processPendingSummarizations()
        }
    }

    private func processPendingSummarizations() async {
        // This would need access to ConversationManager
        // For now, summaries are generated on-demand when conversations change
        pendingSummarization.removeAll()
    }

    // MARK: - Backfill

    /// Backfills summaries for existing conversations when memory is first enabled.
    func backfillSummaries(from conversations: [Conversation], limit: Int = 10) {
        let recent = conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)

        for conversation in recent {
            let summary = generateSummary(for: conversation)
            digest.upsertSummary(summary)
        }

        scheduleSave()

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "✅ Backfilled conversation summaries",
            metadata: ["count": "\(recent.count)"]
        )
    }

    // MARK: - Context Formatting

    /// Formats summaries for injection into AI context.
    /// - Parameter tokenBudget: Approximate token budget
    /// - Parameter excludeConversationId: Exclude the current conversation
    /// - Returns: Formatted string for context injection, or nil if no summaries.
    func formattedForContext(
        tokenBudget: Int = defaultTokenBudget,
        excludeConversationId: UUID? = nil
    ) -> String? {
        var summaries = digest.summaries
        if let excludeId = excludeConversationId {
            summaries.removeAll { $0.id == excludeId }
        }

        guard !summaries.isEmpty else { return nil }

        let charBudget = tokenBudget * 4

        var result = "Recent Conversations:\n"

        for (index, summary) in summaries.enumerated() {
            let formatted = "\(index + 1). \(summary.formattedForContext())\n"
            if result.count + formatted.count > charBudget {
                break
            }
            result += formatted
        }

        return result.count > "Recent Conversations:\n".count ? result : nil
    }

    /// Returns the number of stored summaries.
    var summaryCount: Int { digest.summaries.count }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.saveDebounceDuration ?? .seconds(2))
            } catch {
                return
            }

            await self?.saveNow()
        }
    }

    private func saveNow() async {
        do {
            try await store.saveSummaries(digest)
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "❌ Failed to save conversation summaries",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    /// Forces an immediate save.
    func saveImmediately() async {
        saveTask?.cancel()
        await saveNow()
    }

    /// Clears all summaries.
    func clearAllSummaries() async {
        digest = RecentConversationsDigest()
        saveTask?.cancel()

        do {
            try store.clearSummaries()
            DiagnosticsLogger.log(
                .conversationManager,
                level: .info,
                message: "🧹 Cleared all conversation summaries"
            )
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "❌ Failed to clear summaries store",
                metadata: ["error": error.localizedDescription]
            )
        }
    }
}
