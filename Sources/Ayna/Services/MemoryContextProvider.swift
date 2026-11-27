import Foundation

@MainActor
@Observable
final class MemoryContextProvider {
    static let shared = MemoryContextProvider()

    private let memoryService: UserMemoryService
    private let metadataService: SessionMetadataService
    private let summaryService: ConversationSummaryService
    private let factExtractor: MemoryFactExtractor
    private let preferencesStorageProvider: () -> UserDefaults

    @ObservationIgnored private nonisolated(unsafe) var loadTask: Task<Void, Never>?

    @ObservationIgnored private weak var conversationSource: ConversationManager?

    static let backfillLimit = 10

    private var memoryClearGeneration: UInt64 = 0
    private var activeMemoryClears = 0

    private(set) var isMemoryEnabled: Bool = false {
        didSet {
            preferencesStorageProvider().set(isMemoryEnabled, forKey: "memoryEnabled")
            if isMemoryEnabled {
                scheduleMemoryLoadIfNeeded()
            } else {
                loadTask?.cancel()
                loadTask = nil
                factExtractor.cancelAll()
            }
        }
    }

    private(set) var isAutoExtractionEnabled: Bool = false {
        didSet {
            preferencesStorageProvider().set(isAutoExtractionEnabled, forKey: "memoryAutoExtraction")
        }
    }

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
        factExtractor: MemoryFactExtractor = .shared,
        preferencesStorageProvider: @escaping () -> UserDefaults = { AppPreferences.storage }
    ) {
        self.memoryService = memoryService
        self.metadataService = metadataService
        self.summaryService = summaryService
        self.factExtractor = factExtractor
        self.preferencesStorageProvider = preferencesStorageProvider

        let storage = preferencesStorageProvider()
        storage.register(defaults: [
            "memoryEnabled": false,
            "memoryAutoExtraction": false
        ])

        isMemoryEnabled = storage.bool(forKey: "memoryEnabled")
        isAutoExtractionEnabled = storage.bool(forKey: "memoryAutoExtraction")
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

    func loadAll() async {
        guard isMemoryEnabled else { return }

        async let memoryLoad: () = memoryService.loadFacts()
        async let summaryLoad: () = summaryService.loadSummaries()

        await memoryLoad
        await summaryLoad
        await backfillSummariesIfNeeded()
    }

    func attachConversationSource(_ manager: ConversationManager) {
        conversationSource = manager
        Task { await self.backfillSummariesIfNeeded() }
    }

    func backfillSummariesIfNeeded() async {
        guard isMemoryEnabled, summaryService.isLoaded,
              summaryService.summaryCount < Self.backfillLimit,
              let conversationSource
        else {
            return
        }
        let generation = memoryClearGeneration
        let loaded = await conversationSource.recentConversationsWithHistory(limit: Self.backfillLimit)
        guard memoryClearGeneration == generation else { return }
        let currentIds = Set(conversationSource.conversations.map(\.id))
        let recent = loaded.filter { currentIds.contains($0.id) }
        guard isMemoryEnabled, !recent.isEmpty else { return }
        summaryService.backfillSummaries(from: recent, limit: Self.backfillLimit)
    }

    func saveAll() async {
        guard isMemoryEnabled else { return }

        await memoryService.saveImmediately()
        await summaryService.saveImmediately()
    }

    struct ContextAllocation {
        let sessionMetadata: Int
        let userMemory: Int
        let conversationSummary: Int
        let conversationHistory: Int

        static let reservedForResponse = 4000

        init(availableTokens: Int) {
            let available = max(0, availableTokens - Self.reservedForResponse)

            if available < 8000 {
                sessionMetadata = min(100, available / 20)
                userMemory = min(500, available / 8)
                conversationSummary = 0
                conversationHistory = available - 600
            } else if available < 32000 {
                sessionMetadata = 150
                userMemory = 750
                conversationSummary = 300
                conversationHistory = available - 1200
            } else {
                sessionMetadata = 200
                userMemory = 1000
                conversationSummary = 500
                conversationHistory = available - 1700
            }
        }
    }

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

    func processMemoryCommand(in message: String) -> String? {
        guard isMemoryEnabled else { return nil }

        let command = MemoryCommandPattern.detect(in: message)
        return memoryService.processCommand(command)
    }

    func updateConversationSummary(_ conversation: Conversation) {
        guard isMemoryEnabled, activeMemoryClears == 0 else { return }
        summaryService.updateSummary(for: conversation)
        if isAutoExtractionEnabled {
            factExtractor.conversationDidSave(conversation)
        }
    }

    func removeConversationSummary(for conversationId: UUID) {
        factExtractor.cancel(conversationId: conversationId)
        guard isMemoryEnabled else { return }
        summaryService.removeSummary(for: conversationId)
    }

    func clearAllMemory() async throws {
        memoryClearGeneration &+= 1
        activeMemoryClears += 1
        defer { activeMemoryClears -= 1 }
        factExtractor.cancelAll()
        await memoryService.clearAllFacts()
        try await summaryService.clearAllSummaries()
    }

    func invalidateConversationSummariesForClear() -> ConversationSummaryClearSnapshot {
        factExtractor.cancelAll()
        return summaryService.invalidateForConversationClear()
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

    var hasContent: Bool {
        sessionMetadata != nil || userMemory != nil || conversationSummaries != nil
    }

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

extension MemoryContextProvider.ContextAllocation: Sendable {}
