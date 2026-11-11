//
//  MemoryContextProvider.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation

/// Provides memory context for injection into AI requests.
/// Coordinates between UserMemoryService, SessionMetadataService, and ConversationSummaryService.
@MainActor
@Observable
final class MemoryContextProvider {
    static let shared = MemoryContextProvider()

    private let memoryService: UserMemoryService
    private let metadataService: SessionMetadataService
    private let summaryService: ConversationSummaryService
    private let factExtractor: MemoryFactExtractor

    /// Task for loading memory data (tracked to avoid fire-and-forget)
    @ObservationIgnored private nonisolated(unsafe) var loadTask: Task<Void, Never>?

    /// Source of full conversations for summary backfill; attached by the app.
    @ObservationIgnored private weak var conversationSource: ConversationManager?

    /// Summaries kept for recent conversations (the backfill target).
    static let backfillLimit = 10

    /// Whether memory features are enabled globally
    private(set) var isMemoryEnabled: Bool = false {
        didSet {
            AppPreferences.storage.set(isMemoryEnabled, forKey: "memoryEnabled")
            if isMemoryEnabled {
                scheduleMemoryLoadIfNeeded()
            } else {
                loadTask?.cancel()
                loadTask = nil
                factExtractor.cancelAll()
            }
        }
    }

    /// Whether automatic fact extraction is enabled (opt-in)
    private(set) var isAutoExtractionEnabled: Bool = false {
        didSet {
            AppPreferences.storage.set(isAutoExtractionEnabled, forKey: "memoryAutoExtraction")
        }
    }

    /// Sets whether memory is enabled
    func setMemoryEnabled(_ enabled: Bool) {
        guard isMemoryEnabled != enabled else {
            if enabled {
                scheduleMemoryLoadIfNeeded()
            }
            return
        }
        isMemoryEnabled = enabled
        NotificationCenter.default.post(name: .watchSyncContextDidChange, object: nil)
    }

    /// Sets whether auto extraction is enabled
    func setAutoExtractionEnabled(_ enabled: Bool) {
        isAutoExtractionEnabled = enabled
        if !enabled {
            factExtractor.cancelAll()
        }
    }

    init(
        memoryService: UserMemoryService = .shared,
        metadataService: SessionMetadataService = .shared,
        summaryService: ConversationSummaryService = .shared,
        factExtractor: MemoryFactExtractor = .shared
    ) {
        self.memoryService = memoryService
        self.metadataService = metadataService
        self.summaryService = summaryService
        self.factExtractor = factExtractor

        // Register defaults
        AppPreferences.storage.register(defaults: [
            "memoryEnabled": false, // Opt-in by default
            "memoryAutoExtraction": false // Disabled by default
        ])

        // Load stored values
        isMemoryEnabled = AppPreferences.storage.bool(forKey: "memoryEnabled")
        isAutoExtractionEnabled = AppPreferences.storage.bool(forKey: "memoryAutoExtraction")
        scheduleMemoryLoadIfNeeded()
    }

    deinit {
        loadTask?.cancel()
    }

    nonisolated static func requiresAuthoritativeLoad(
        isEnabled: Bool,
        hasAuthoritativeFacts: Bool
    ) -> Bool {
        isEnabled && !hasAuthoritativeFacts
    }

    private func scheduleMemoryLoadIfNeeded() {
        guard Self.requiresAuthoritativeLoad(
            isEnabled: isMemoryEnabled,
            hasAuthoritativeFacts: memoryService.hasAuthoritativeFacts
        ), loadTask == nil else {
            return
        }
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadAll()
            self.loadTask = nil
        }
    }

    /// Loads all memory data from storage.
    func loadAll() async {
        guard isMemoryEnabled else { return }

        async let memoryLoad: () = memoryService.loadFacts()
        async let summaryLoad: () = summaryService.loadSummaries()

        await memoryLoad
        await summaryLoad
        await backfillSummariesIfNeeded()
    }

    /// Lets summary backfill read recent conversations, then backfills if memory is ready.
    func attachConversationSource(_ manager: ConversationManager) {
        conversationSource = manager
        Task { await self.backfillSummariesIfNeeded() }
    }

    /// Summarizes recent conversations that have no summary yet, e.g. right after memory is
    /// turned on or for conversations from before summaries were saved reliably.
    func backfillSummariesIfNeeded() async {
        guard isMemoryEnabled, summaryService.isLoaded,
              summaryService.summaryCount < Self.backfillLimit,
              let conversationSource
        else {
            return
        }
        let recent = await conversationSource.recentConversationsWithHistory(limit: Self.backfillLimit)
        guard isMemoryEnabled, !recent.isEmpty else { return }
        summaryService.backfillSummaries(from: recent, limit: Self.backfillLimit)
    }

    /// Saves all memory data immediately.
    func saveAll() async {
        guard isMemoryEnabled else { return }

        await memoryService.saveImmediately()
        await summaryService.saveImmediately()
    }

    // MARK: - Context Building

    /// Token budget allocation based on model context window.
    struct ContextAllocation {
        let sessionMetadata: Int
        let userMemory: Int
        let conversationSummary: Int
        let conversationHistory: Int

        static let reservedForResponse = 4000

        /// Creates allocation based on available context tokens.
        init(availableTokens: Int) {
            let available = max(0, availableTokens - Self.reservedForResponse)

            // For small context models (< 8K), drop summaries entirely
            if available < 8000 {
                sessionMetadata = min(100, available / 20)
                userMemory = min(500, available / 8)
                conversationSummary = 0
                conversationHistory = available - 600
            }
            // For medium context (8K-32K), reduce allocations
            else if available < 32000 {
                sessionMetadata = 150
                userMemory = 750
                conversationSummary = 300
                conversationHistory = available - 1200
            }
            // Large context models get full allocations
            else {
                sessionMetadata = 200
                userMemory = 1000
                conversationSummary = 500
                conversationHistory = available - 1700
            }
        }
    }

    /// Builds complete memory context for injection.
    /// - Parameters:
    ///   - currentConversationId: ID of the current conversation (excluded from summaries)
    ///   - modelContextWindow: The model's total context window size
    /// - Returns: Memory context struct with formatted strings
    func buildContext(
        currentConversationId: UUID? = nil,
        modelContextWindow: Int = 128_000
    ) -> MemoryContext {
        guard isMemoryEnabled else {
            return MemoryContext()
        }

        let allocation = ContextAllocation(availableTokens: modelContextWindow)

        let sessionMetadata = metadataService.formattedForContext()
        let userMemory = memoryService.formattedForContext(tokenBudget: allocation.userMemory)
        let conversationSummaries = summaryService.formattedForContext(
            tokenBudget: allocation.conversationSummary,
            excludeConversationId: currentConversationId
        )

        return MemoryContext(
            sessionMetadata: sessionMetadata,
            userMemory: userMemory,
            conversationSummaries: conversationSummaries,
            allocation: allocation
        )
    }

    /// Processes a user message for memory commands.
    /// - Returns: Response text if a command was processed, nil otherwise.
    func processMemoryCommand(in message: String) -> String? {
        guard isMemoryEnabled else { return nil }

        let command = MemoryCommandPattern.detect(in: message)
        return memoryService.processCommand(command)
    }

    /// Updates conversation summary when a conversation changes, and schedules automatic fact
    /// extraction for it when that is turned on.
    func updateConversationSummary(_ conversation: Conversation) {
        guard isMemoryEnabled else { return }
        summaryService.updateSummary(for: conversation)
        if isAutoExtractionEnabled {
            factExtractor.conversationDidSave(conversation)
        }
    }

    /// Removes summary when a conversation is deleted.
    func removeConversationSummary(for conversationId: UUID) {
        guard isMemoryEnabled else { return }
        summaryService.removeSummary(for: conversationId)
    }

    func invalidateConversationSummariesForClear() -> ConversationSummaryClearSnapshot {
        summaryService.invalidateForConversationClear()
    }

    func restoreConversationSummariesAfterFailedClear(_ snapshot: ConversationSummaryClearSnapshot) async throws {
        try await summaryService.restoreAfterFailedConversationClear(snapshot)
    }

    func clearAllConversationSummaries(cleanupToken: String? = nil) async throws {
        try await summaryService.clearAllSummaries(
            preservingCurrentDigest: true,
            completingConversationClear: true,
            cleanupToken: cleanupToken
        )
    }

    // MARK: - Accessors

    var memoryFactCount: Int {
        memoryService.activeFacts().count
    }

    var summaryCount: Int {
        summaryService.summaryCount
    }

    var memorySummary: String {
        memoryService.memorySummary
    }
}

/// Container for memory context to inject into AI requests.
struct MemoryContext: Sendable {
    let sessionMetadata: String?
    let userMemory: String?
    let conversationSummaries: String?
    let allocation: MemoryContextProvider.ContextAllocation?

    init(
        sessionMetadata: String? = nil,
        userMemory: String? = nil,
        conversationSummaries: String? = nil,
        allocation: MemoryContextProvider.ContextAllocation? = nil
    ) {
        self.sessionMetadata = sessionMetadata
        self.userMemory = userMemory
        self.conversationSummaries = conversationSummaries
        self.allocation = allocation
    }

    /// Whether any memory context is available
    var hasContent: Bool {
        sessionMetadata != nil || userMemory != nil || conversationSummaries != nil
    }

    /// Estimated token count for the memory context
    var estimatedTokens: Int {
        var tokens = 0
        if let meta = sessionMetadata {
            tokens += meta.count / 4
        }
        if let memory = userMemory {
            tokens += memory.count / 4
        }
        if let summaries = conversationSummaries {
            tokens += summaries.count / 4
        }
        return tokens
    }
}

/// Make ContextAllocation Sendable
extension MemoryContextProvider.ContextAllocation: Sendable {}
