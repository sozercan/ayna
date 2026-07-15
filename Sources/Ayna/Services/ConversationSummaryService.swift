//
//  ConversationSummaryService.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation
import os.log

private final class SummaryPersistenceErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.withLock { storedError }
    }

    func set(_ error: Error) {
        lock.withLock {
            storedError = error
        }
    }
}

private final class SummaryCleanupResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDigest: RecentConversationsDigest?
    private var storedError: Error?

    var digest: RecentConversationsDigest? {
        lock.withLock { storedDigest }
    }

    var error: Error? {
        lock.withLock { storedError }
    }

    func set(digest: RecentConversationsDigest) {
        lock.withLock { storedDigest = digest }
    }

    func set(error: Error) {
        lock.withLock { storedError = error }
    }
}

struct ConversationSummaryClearSnapshot: Sendable {
    let digest: RecentConversationsDigest
    let wasLoaded: Bool
    let generation: UInt64

    init(
        digest: RecentConversationsDigest,
        wasLoaded: Bool,
        generation: UInt64 = 0
    ) {
        self.digest = digest
        self.wasLoaded = wasLoaded
        self.generation = generation
    }
}

/// Service for managing conversation summaries.
/// Summaries are lightweight digests of recent conversations for context injection.
@MainActor
@Observable
final class ConversationSummaryService {
    static let shared = ConversationSummaryService()

    private(set) var digest: RecentConversationsDigest = .init()
    private(set) var isLoaded = false

    private let store: EncryptedMemoryStore
    private let summaryLoader: @Sendable () async throws -> RecentConversationsDigest
    private let summarySaveOperation: @Sendable (RecentConversationsDigest) async throws -> Void
    private let summaryClearOperation: @Sendable () throws -> Void
    private let summaryTransactionalCleanupOperation: @Sendable (
        RecentConversationsDigest,
        String,
        Set<UUID>?
    ) async throws -> RecentConversationsDigest
    private let survivingConversationIdsLoader: @Sendable () async throws -> Set<UUID>
    private let persistenceQueue = OrderedAsyncOperationQueue()
    private var storageGeneration: UInt64 = 0
    private var conversationClearGeneration: UInt64 = 0
    private var isConversationClearInProgress = false
    private var storedDigestWasDeferredForPendingCleanup = false
    private nonisolated(unsafe) var saveTask: Task<Void, Never>?
    private let saveDebounceDuration: Duration = .seconds(2)

    /// Conversations pending summarization (debounced)
    private var pendingSummarization: Set<UUID> = []
    private nonisolated(unsafe) var summarizationTask: Task<Void, Never>?
    private let summarizationDebounce: Duration = .seconds(300) // 5 minutes

    /// Token budget for summaries context (approximate)
    static let defaultTokenBudget = 500

    init(
        store: EncryptedMemoryStore = .shared,
        summaryLoader: (@Sendable () async throws -> RecentConversationsDigest)? = nil,
        summarySaveOperation: (@Sendable (RecentConversationsDigest) async throws -> Void)? = nil,
        summaryClearOperation: (@Sendable () throws -> Void)? = nil,
        summaryTransactionalCleanupOperation: (@Sendable (
            RecentConversationsDigest,
            String
        ) async throws -> RecentConversationsDigest)? = nil,
        survivingConversationIdsLoader: (@Sendable () async throws -> Set<UUID>)? = nil
    ) {
        self.store = store
        let resolvedLoader = summaryLoader ?? { try await store.loadSummaries() }
        let resolvedSave = summarySaveOperation ?? { try await store.saveSummaries($0) }
        let resolvedClear = summaryClearOperation ?? { try store.clearSummaries() }
        self.summaryLoader = resolvedLoader
        self.summarySaveOperation = resolvedSave
        self.summaryClearOperation = resolvedClear
        if let summaryTransactionalCleanupOperation {
            self.summaryTransactionalCleanupOperation = { digest, cleanupToken, _ in
                try await summaryTransactionalCleanupOperation(digest, cleanupToken)
            }
        } else if summaryClearOperation != nil || summarySaveOperation != nil {
            self.summaryTransactionalCleanupOperation = { digest, _, _ in
                try resolvedClear()
                if !digest.summaries.isEmpty {
                    try await resolvedSave(digest)
                }
                return digest
            }
        } else {
            self.summaryTransactionalCleanupOperation = { digest, cleanupToken, survivingConversationIds in
                try await store.replaceSummariesAfterCleanup(
                    preserving: digest,
                    cleanupToken: cleanupToken,
                    survivingConversationIds: survivingConversationIds
                )
            }
        }
        self.survivingConversationIdsLoader = survivingConversationIdsLoader ?? {
            try await Set(EncryptedConversationStore.shared.loadConversationMetadata().map(\.id))
        }
    }

    deinit {
        saveTask?.cancel()
        summarizationTask?.cancel()
    }

    // MARK: - Loading

    /// Loads summaries from encrypted storage.
    func loadSummaries() async {
        guard !isConversationClearInProgress else {
            isLoaded = true
            return
        }
        do {
            let markerSnapshot = try EncryptedConversationStore.shared
                .pendingPrivacyCleanupMarkerSnapshotThrowing()
            if !markerSnapshot.isEmpty,
               !EncryptedConversationStore.shared.isSummaryCleanupCompleted(for: markerSnapshot)
            {
                digest = RecentConversationsDigest()
                storedDigestWasDeferredForPendingCleanup = true
                isLoaded = true
                return
            }
        } catch {
            digest = RecentConversationsDigest()
            isLoaded = true
            return
        }
        let generation = storageGeneration
        do {
            let loadedDigest = try await summaryLoader()
            guard storageGeneration == generation, !isConversationClearInProgress else { return }
            digest = loadedDigest
            storedDigestWasDeferredForPendingCleanup = false
            isLoaded = true

            DiagnosticsLogger.log(
                .conversationManager,
                level: .info,
                message: "✅ Loaded conversation summaries",
                metadata: ["count": "\(digest.summaries.count)"]
            )
        } catch {
            guard storageGeneration == generation, !isConversationClearInProgress else { return }
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

    /// Hides existing summaries immediately while the authoritative conversation clear runs.
    func invalidateForConversationClear() -> ConversationSummaryClearSnapshot {
        storageGeneration &+= 1
        conversationClearGeneration &+= 1
        isConversationClearInProgress = true
        let snapshot = ConversationSummaryClearSnapshot(
            digest: digest,
            wasLoaded: isLoaded,
            generation: conversationClearGeneration
        )
        saveTask?.cancel()
        saveTask = nil
        summarizationTask?.cancel()
        summarizationTask = nil
        pendingSummarization.removeAll()
        digest = RecentConversationsDigest()
        isLoaded = true
        return snapshot
    }

    /// Restores the in-memory digest when the authoritative conversation clear rolls back.
    func restoreAfterFailedConversationClear(_ snapshot: ConversationSummaryClearSnapshot) async throws {
        let clearGeneration = snapshot.generation
        storageGeneration &+= 1
        let persistedDigest = if snapshot.wasLoaded {
            snapshot.digest
        } else {
            try await summaryLoader()
        }
        guard conversationClearGeneration == clearGeneration else {
            throw CancellationError()
        }
        var restoredDigest = persistedDigest
        if !snapshot.wasLoaded {
            for summary in snapshot.digest.summaries {
                restoredDigest.upsertSummary(summary)
            }
        }
        for summary in digest.summaries {
            restoredDigest.upsertSummary(summary)
        }
        digest = restoredDigest
        isLoaded = true
        try await saveImmediatelyThrowing()
        if conversationClearGeneration == clearGeneration {
            isConversationClearInProgress = false
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
        let stopWords: Set = [
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
        storageGeneration &+= 1
        let summary = generateSummary(for: conversation)
        digest.upsertSummary(summary)
        scheduleSave()
    }

    /// Removes a summary when a conversation is deleted.
    func removeSummary(for conversationId: UUID) {
        storageGeneration &+= 1
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
        storageGeneration &+= 1
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
    var summaryCount: Int {
        digest.summaries.count
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.saveDebounceDuration ?? .seconds(2))
                try Task.checkCancellation()
            } catch {
                return
            }

            await self?.saveNow()
        }
    }

    private func saveNowThrowing() async throws {
        let digestSnapshot = digest
        let saveOperation = summarySaveOperation
        let errorBox = SummaryPersistenceErrorBox()
        let task = persistenceQueue.enqueue {
            do {
                try await saveOperation(digestSnapshot)
            } catch {
                errorBox.set(error)
            }
        }
        await task.value
        if let error = errorBox.error {
            throw error
        }
    }

    private func saveNow() async {
        do {
            try await saveNowThrowing()
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "❌ Failed to save conversation summaries",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func cancelPendingSave() async {
        let activeSaveTask = saveTask
        saveTask = nil
        activeSaveTask?.cancel()
        await activeSaveTask?.value
    }

    /// Forces an immediate save.
    func saveImmediately() async {
        await cancelPendingSave()
        await saveNow()
    }

    private func saveImmediatelyThrowing() async throws {
        await cancelPendingSave()
        try await saveNowThrowing()
    }

    /// Clears all summaries.
    func clearAllSummaries(
        preservingCurrentDigest: Bool = false,
        completingConversationClear: Bool = false,
        cleanupToken: String? = nil
    ) async throws {
        let completesConversationClear = completingConversationClear
            && isConversationClearInProgress
        let supersedesConversationClear = !completingConversationClear
            && isConversationClearInProgress
        if supersedesConversationClear {
            conversationClearGeneration &+= 1
        }
        let clearGeneration = conversationClearGeneration
        storageGeneration &+= 1
        let activeSaveTask = saveTask
        saveTask = nil
        activeSaveTask?.cancel()

        let activeSummarizationTask = summarizationTask
        summarizationTask = nil
        activeSummarizationTask?.cancel()
        pendingSummarization.removeAll()

        if !preservingCurrentDigest {
            digest = RecentConversationsDigest()
        }
        isLoaded = true

        if let cleanupToken {
            await activeSaveTask?.value
            await activeSummarizationTask?.value

            let digestAtCleanup = preservingCurrentDigest
                ? digest
                : RecentConversationsDigest()
            let survivingConversationIds: Set<UUID>? = if preservingCurrentDigest,
                                                          storedDigestWasDeferredForPendingCleanup
            {
                try await survivingConversationIdsLoader()
            } else {
                nil
            }
            let resultBox = SummaryCleanupResultBox()
            let cleanupOperation = summaryTransactionalCleanupOperation
            let cleanupTask = persistenceQueue.enqueue {
                do {
                    let storedDigest = try await cleanupOperation(
                        digestAtCleanup,
                        cleanupToken,
                        survivingConversationIds
                    )
                    resultBox.set(digest: storedDigest)
                } catch {
                    resultBox.set(error: error)
                }
            }
            await cleanupTask.value

            if let error = resultBox.error {
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .error,
                    message: "❌ Failed to transactionally clear summaries store",
                    metadata: ["error": error.localizedDescription]
                )
                throw error
            }

            var mergedDigest = resultBox.digest ?? digestAtCleanup
            if preservingCurrentDigest {
                for summary in digest.summaries {
                    mergedDigest.upsertSummary(summary)
                }
            }
            digest = mergedDigest
            storedDigestWasDeferredForPendingCleanup = false
            if preservingCurrentDigest, !digest.summaries.isEmpty {
                try await saveNowThrowing()
            }
            if completesConversationClear || supersedesConversationClear,
               conversationClearGeneration == clearGeneration
            {
                isConversationClearInProgress = false
            }
            DiagnosticsLogger.log(
                .conversationManager,
                level: .info,
                message: "🧹 Transactionally cleared conversation summaries"
            )
            return
        }

        let errorBox = SummaryPersistenceErrorBox()
        let clearOperation = summaryClearOperation
        let clearTask = persistenceQueue.enqueue {
            do {
                try clearOperation()
            } catch {
                errorBox.set(error)
            }
        }

        await activeSaveTask?.value
        await activeSummarizationTask?.value
        await clearTask.value

        if let error = errorBox.error {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "❌ Failed to clear summaries store",
                metadata: ["error": error.localizedDescription]
            )
            throw error
        }

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "🧹 Cleared all conversation summaries"
        )

        if preservingCurrentDigest, !digest.summaries.isEmpty {
            try await saveNowThrowing()
        }
        if completesConversationClear || supersedesConversationClear,
           conversationClearGeneration == clearGeneration
        {
            isConversationClearInProgress = false
        }
    }
}
