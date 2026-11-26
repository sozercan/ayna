import Foundation
import os.log

protocol UserMemoryStoreAdapter: Sendable {
    func loadMemory() async throws -> UserMemoryStore
    func saveMemory(_ store: UserMemoryStore) async throws
    func clearMemory() async throws
}

extension EncryptedMemoryStore: UserMemoryStoreAdapter {}

@MainActor
@Observable
final class UserMemoryService {
    private enum InitialLoadMutation {
        case upsert(UserMemoryFact)
        case delete(UUID)
        case clear
    }

    static let shared = UserMemoryService()

    private(set) var facts: [UserMemoryFact] = []
    private(set) var isLoaded = false
    private(set) var hasAuthoritativeFacts = false

    private let store: any UserMemoryStoreAdapter
    private let notificationCenter: NotificationCenter
    private let saveDebounceDuration: Duration
    @ObservationIgnored private nonisolated(unsafe) var saveTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var initialLoadTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var persistenceTask: Task<Void, Never>?
    private var factsGeneration: UInt64 = 0
    private var durableGeneration: UInt64?
    private var hasInMemoryAuthority = false
    private var hasReconciledStoredFacts = false
    private var initialLoadID: UUID?
    private var initialLoadMutations: [InitialLoadMutation] = []
    private var initialLoadWasSuperseded = false

    static let maxFacts = 100

    static let defaultTokenBudget = 1000

    init(
        store: any UserMemoryStoreAdapter = EncryptedMemoryStore.shared,
        saveDebounceDuration: Duration = .milliseconds(500),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.saveDebounceDuration = saveDebounceDuration
        self.notificationCenter = notificationCenter
    }

    deinit {
        saveTask?.cancel()
        initialLoadTask?.cancel()
        persistenceTask?.cancel()
    }

    func loadFacts() async {
        if let initialLoadTask {
            await initialLoadTask.value
            return
        }

        if isLoaded, hasInMemoryAuthority, hasReconciledStoredFacts {
            if !hasAuthoritativeFacts {
                await saveImmediately()
            }
            return
        }

        let loadID = UUID()
        let store = store
        initialLoadID = loadID
        initialLoadWasSuperseded = false

        let operation = Task { @MainActor [weak self] in
            do {
                let memoryStore = try await store.loadMemory()
                self?.finishInitialLoad(memoryStore, loadID: loadID)
            } catch {
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .error,
                    message: "❌ Failed to load user memory",
                    metadata: ["error": error.localizedDescription]
                )
                self?.finishInitialLoadFailure(loadID: loadID)
            }
        }
        initialLoadTask = operation
        await operation.value
    }

    func loadFactsFromSync(_ syncedFacts: [UserMemoryFact]) {
        supersedeInitialLoad()
        facts = Array(syncedFacts.prefix(Self.maxFacts))
        isLoaded = true
        hasReconciledStoredFacts = true
        scheduleSave()

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "✅ Loaded user memory from sync",
            metadata: ["factCount": "\(facts.count)"]
        )
    }

    @discardableResult
    func addFact(
        _ content: String,
        source: UserMemoryFact.MemorySource = .explicit
    ) -> UserMemoryFact {
        let fact = UserMemoryFact(
            content: content,
            source: source
        )

        facts.insert(fact, at: 0)
        Self.enforceFactLimit(&facts)

        scheduleSave(initialLoadMutation: .upsert(fact))

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "➕ Added memory fact",
            metadata: ["source": source.rawValue]
        )

        return fact
    }

    func updateFact(_ id: UUID, content: String) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }

        facts[index].content = content
        facts[index].updatedAt = Date()
        scheduleSave(initialLoadMutation: .upsert(facts[index]))
    }

    func deleteFact(_ id: UUID) {
        facts.removeAll { $0.id == id }
        scheduleSave(initialLoadMutation: .delete(id))

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "🗑️ Deleted memory fact"
        )
    }

    func toggleFact(_ id: UUID, active: Bool) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }

        facts[index].isActive = active
        facts[index].updatedAt = Date()
        scheduleSave(initialLoadMutation: .upsert(facts[index]))
    }

    func clearAllFacts() async {
        saveTask?.cancel()
        saveTask = nil
        supersedeInitialLoad()
        facts.removeAll()
        isLoaded = true
        hasReconciledStoredFacts = true
        let generation = recordFactsChange()

        let operation = enqueueClear(generation: generation)
        await operation.value
    }

    func activeFacts() -> [UserMemoryFact] {
        facts.filter(\.isActive)
    }

    func searchFacts(query: String) -> [UserMemoryFact] {
        guard !query.isEmpty else { return activeFacts() }
        let lowercased = query.lowercased()
        return facts.filter {
            $0.isActive && $0.content.lowercased().contains(lowercased)
        }
    }

    func findSimilarFacts(to content: String) -> [UserMemoryFact] {
        let words = Set(content.lowercased().components(separatedBy: .whitespacesAndNewlines))
        return facts.filter { fact in
            let factWords = Set(fact.content.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let intersection = words.intersection(factWords)
            let similarity = Double(intersection.count) / Double(max(words.count, factWords.count))
            return similarity > 0.5
        }
    }

    func formattedForContext(tokenBudget: Int = defaultTokenBudget) -> String? {
        let active = activeFacts()
        guard !active.isEmpty else { return nil }

        let charBudget = tokenBudget * 4

        var lines = ["User Facts:"]
        var totalChars = lines[0].count

        for fact in active {
            let line = "- \(fact.content)"
            if totalChars + line.count + 1 > charBudget {
                break
            }
            lines.append(line)
            totalChars += line.count + 1
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    var memorySummary: String {
        let activeCount = activeFacts().count
        if activeCount == 0 {
            return "No facts stored"
        } else if activeCount == 1 {
            return "1 fact stored"
        } else {
            return "\(activeCount) facts stored"
        }
    }

    func processCommand(_ command: MemoryCommandPattern.CommandType) -> String? {
        switch command {
        case let .store(content):
            let fact = addFact(content)
            return "I'll remember that: \"\(fact.content)\""

        case let .remove(content):
            let similar = findSimilarFacts(to: content)
            if let match = similar.first {
                deleteFact(match.id)
                return "I've forgotten: \"\(match.content)\""
            } else {
                return "I couldn't find a matching memory to remove."
            }

        case .query:
            let active = activeFacts()
            if active.isEmpty {
                return "I don't have any memories stored about you yet."
            } else {
                var response = "Here's what I remember about you:\n"
                for fact in active.prefix(10) {
                    response += "• \(fact.content)\n"
                }
                if active.count > 10 {
                    response += "\n...and \(active.count - 10) more facts."
                }
                return response
            }

        case .clearAll:
            return "To clear all memory, please go to Settings → Memory and use the 'Clear All Memory' option."

        case .none:
            return nil
        }
    }

    private func scheduleSave(initialLoadMutation: InitialLoadMutation? = nil) {
        recordFactsChange(initialLoadMutation: initialLoadMutation)
        let debounceDuration = saveDebounceDuration
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }

            guard let self else { return }
            guard await self.waitForInitialLoad() else { return }
            guard !Task.isCancelled else { return }

            let operation = self.enqueueSave(self.facts, generation: self.factsGeneration)
            await operation.value
        }
    }

    @discardableResult
    private func recordFactsChange(initialLoadMutation: InitialLoadMutation? = nil) -> UInt64 {
        factsGeneration &+= 1
        hasInMemoryAuthority = true
        hasAuthoritativeFacts = false

        if let initialLoadMutation,
           initialLoadID != nil || !hasReconciledStoredFacts,
           !initialLoadWasSuperseded
        {
            initialLoadMutations.append(initialLoadMutation)
        }

        return factsGeneration
    }

    private func waitForInitialLoad() async -> Bool {
        if hasReconciledStoredFacts {
            return true
        }
        if let initialLoadTask {
            await initialLoadTask.value
        } else {
            await loadFacts()
        }
        return hasReconciledStoredFacts
    }

    private func finishInitialLoad(
        _ memoryStore: UserMemoryStore,
        loadID: UUID
    ) {
        guard initialLoadID == loadID else { return }

        let mutations = initialLoadMutations
        let wasSuperseded = initialLoadWasSuperseded
        resetInitialLoad(loadID: loadID)
        guard !wasSuperseded else { return }

        isLoaded = true
        hasInMemoryAuthority = true
        hasReconciledStoredFacts = true

        if mutations.isEmpty {
            facts = memoryStore.facts
            durableGeneration = factsGeneration
            hasAuthoritativeFacts = true
            publishDurableFacts()
        } else {
            facts = Self.applying(mutations, to: memoryStore.facts)
            hasAuthoritativeFacts = false
        }

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "✅ Loaded user memory",
            metadata: ["factCount": "\(facts.count)"]
        )
    }

    private func finishInitialLoadFailure(loadID: UUID) {
        guard initialLoadID == loadID else { return }

        let hadLocalMutations = !initialLoadMutations.isEmpty
        let wasSuperseded = initialLoadWasSuperseded
        resetInitialLoad(
            loadID: loadID,
            preserveMutations: hadLocalMutations && !wasSuperseded
        )
        guard !wasSuperseded else { return }

        if !hadLocalMutations {
            facts = []
            hasInMemoryAuthority = false
        }
        isLoaded = true
        hasAuthoritativeFacts = false
    }

    private func supersedeInitialLoad() {
        if initialLoadID != nil {
            initialLoadWasSuperseded = true
        }
        initialLoadMutations.removeAll()
    }

    private func resetInitialLoad(
        loadID: UUID,
        preserveMutations: Bool = false
    ) {
        guard initialLoadID == loadID else { return }
        initialLoadID = nil
        if !preserveMutations {
            initialLoadMutations.removeAll()
        }
        initialLoadWasSuperseded = false
        initialLoadTask = nil
    }

    private static func applying(
        _ mutations: [InitialLoadMutation],
        to storedFacts: [UserMemoryFact]
    ) -> [UserMemoryFact] {
        var mergedFacts = storedFacts

        for mutation in mutations {
            switch mutation {
            case let .upsert(fact):
                if let index = mergedFacts.firstIndex(where: { $0.id == fact.id }) {
                    mergedFacts[index] = fact
                } else {
                    mergedFacts.insert(fact, at: 0)
                }
                enforceFactLimit(&mergedFacts)

            case let .delete(id):
                mergedFacts.removeAll { $0.id == id }

            case .clear:
                mergedFacts.removeAll()
            }
        }

        return mergedFacts
    }

    private static func enforceFactLimit(_ facts: inout [UserMemoryFact]) {
        guard facts.count > maxFacts else { return }

        if let oldestInactiveIndex = facts.lastIndex(where: { !$0.isActive }) {
            facts.remove(at: oldestInactiveIndex)
        } else {
            facts.removeLast()
        }
    }

    @discardableResult
    private func enqueueSave(
        _ factsSnapshot: [UserMemoryFact],
        generation: UInt64
    ) -> Task<Void, Never> {
        let memoryStore = UserMemoryStore(
            facts: factsSnapshot,
            lastUpdated: Date(),
            version: UserMemoryStore.currentVersion
        )
        let previousOperation = persistenceTask
        let store = store

        let operation = Task { @MainActor [weak self] in
            await previousOperation?.value

            do {
                try await store.saveMemory(memoryStore)
                self?.finishPersistence(
                    factsSnapshot: factsSnapshot,
                    generation: generation
                )
            } catch {
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .error,
                    message: "❌ Failed to save user memory",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
        persistenceTask = operation
        return operation
    }

    @discardableResult
    private func enqueueClear(generation: UInt64) -> Task<Void, Never> {
        let previousOperation = persistenceTask
        let store = store

        let operation = Task { @MainActor [weak self] in
            await previousOperation?.value

            do {
                try await store.clearMemory()
                self?.hasReconciledStoredFacts = true
                self?.isLoaded = true
                self?.initialLoadMutations.removeAll()
                self?.finishPersistence(factsSnapshot: [], generation: generation)
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .info,
                    message: "🧹 Cleared all memory facts"
                )
            } catch {
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .error,
                    message: "❌ Failed to clear memory store",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
        persistenceTask = operation
        return operation
    }

    private func finishPersistence(
        factsSnapshot: [UserMemoryFact],
        generation: UInt64
    ) {
        guard factsGeneration == generation, facts == factsSnapshot else { return }

        hasInMemoryAuthority = true
        guard durableGeneration != generation || !hasAuthoritativeFacts else { return }

        durableGeneration = generation
        hasAuthoritativeFacts = true
        publishDurableFacts()
    }

    private func publishDurableFacts() {
        notificationCenter.post(name: .watchSyncContextDidChange, object: nil)
    }

    func saveImmediately() async {
        saveTask?.cancel()
        saveTask = nil
        guard await waitForInitialLoad() else { return }
        let operation = enqueueSave(facts, generation: factsGeneration)
        await operation.value
    }
}
