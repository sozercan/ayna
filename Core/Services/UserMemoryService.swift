//
//  UserMemoryService.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation
import os.log

/// Service for managing user memory facts.
/// Provides CRUD operations and formatting for context injection.
@MainActor
@Observable
final class UserMemoryService {
    static let shared = UserMemoryService()

    private(set) var facts: [UserMemoryFact] = []
    private(set) var isLoaded = false

    private let store: EncryptedMemoryStore
    private var saveTask: Task<Void, Never>?
    private let saveDebounceDuration: Duration = .milliseconds(500)

    /// Maximum number of facts to store
    static let maxFacts = 100

    /// Token budget for memory context (approximate)
    static let defaultTokenBudget = 1000

    init(store: EncryptedMemoryStore = .shared) {
        self.store = store
    }

    // MARK: - Loading

    /// Loads facts from encrypted storage.
    func loadFacts() async {
        do {
            let memoryStore = try await store.loadMemory()
            facts = memoryStore.facts
            isLoaded = true

            DiagnosticsLogger.log(
                .conversationManager,
                level: .info,
                message: "✅ Loaded user memory",
                metadata: ["factCount": "\(facts.count)"]
            )
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "❌ Failed to load user memory",
                metadata: ["error": error.localizedDescription]
            )
            facts = []
            isLoaded = true
        }
    }

    // MARK: - CRUD Operations

    /// Adds a new fact to memory.
    @discardableResult
    func addFact(
        _ content: String,
        category: UserMemoryFact.MemoryCategory = .other,
        source: UserMemoryFact.MemorySource = .explicit
    ) -> UserMemoryFact {
        let fact = UserMemoryFact(
            content: content,
            category: category,
            source: source
        )

        facts.insert(fact, at: 0)

        // Enforce max limit
        if facts.count > Self.maxFacts {
            // Remove oldest inactive facts first, then oldest active
            let inactiveFacts = facts.filter { !$0.isActive }
            if !inactiveFacts.isEmpty, let oldest = inactiveFacts.last {
                facts.removeAll { $0.id == oldest.id }
            } else {
                facts.removeLast()
            }
        }

        scheduleSave()

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "➕ Added memory fact",
            metadata: ["category": category.rawValue, "source": source.rawValue]
        )

        return fact
    }

    /// Updates an existing fact's content.
    func updateFact(_ id: UUID, content: String) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }

        facts[index].content = content
        facts[index].updatedAt = Date()
        scheduleSave()
    }

    /// Updates an existing fact's category.
    func updateFact(_ id: UUID, category: UserMemoryFact.MemoryCategory) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }

        facts[index].category = category
        facts[index].updatedAt = Date()
        scheduleSave()
    }

    /// Deletes a fact (hard delete).
    func deleteFact(_ id: UUID) {
        facts.removeAll { $0.id == id }
        scheduleSave()

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "🗑️ Deleted memory fact"
        )
    }

    /// Toggles a fact's active state (soft delete/restore).
    func toggleFact(_ id: UUID, active: Bool) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }

        facts[index].isActive = active
        facts[index].updatedAt = Date()
        scheduleSave()
    }

    /// Clears all facts.
    func clearAllFacts() {
        facts.removeAll()
        saveTask?.cancel()

        Task {
            do {
                try store.clearMemory()
            } catch {
                DiagnosticsLogger.log(
                    .conversationManager,
                    level: .error,
                    message: "❌ Failed to clear memory store",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }

        DiagnosticsLogger.log(
            .conversationManager,
            level: .info,
            message: "🧹 Cleared all memory facts"
        )
    }

    // MARK: - Query

    /// Returns only active facts.
    func activeFacts() -> [UserMemoryFact] {
        facts.filter(\.isActive)
    }

    /// Returns facts in a specific category.
    func facts(in category: UserMemoryFact.MemoryCategory) -> [UserMemoryFact] {
        facts.filter { $0.category == category && $0.isActive }
    }

    /// Searches facts for a query string.
    func searchFacts(query: String) -> [UserMemoryFact] {
        guard !query.isEmpty else { return activeFacts() }
        let lowercased = query.lowercased()
        return facts.filter {
            $0.isActive && $0.content.lowercased().contains(lowercased)
        }
    }

    /// Finds facts similar to the given content (for deduplication).
    func findSimilarFacts(to content: String) -> [UserMemoryFact] {
        let words = Set(content.lowercased().components(separatedBy: .whitespacesAndNewlines))
        return facts.filter { fact in
            let factWords = Set(fact.content.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let intersection = words.intersection(factWords)
            // Consider similar if >50% of words overlap
            let similarity = Double(intersection.count) / Double(max(words.count, factWords.count))
            return similarity > 0.5
        }
    }

    // MARK: - Context Formatting

    /// Formats active facts for injection into AI context.
    /// - Parameter tokenBudget: Approximate token budget (4 chars ≈ 1 token)
    /// - Returns: Formatted string for context injection, or nil if no facts.
    func formattedForContext(tokenBudget: Int = defaultTokenBudget) -> String? {
        let active = activeFacts()
        guard !active.isEmpty else { return nil }

        let charBudget = tokenBudget * 4 // Rough token-to-char ratio

        var lines = ["User Facts:"]
        var totalChars = lines[0].count

        // Group by category for better organization
        let grouped = Dictionary(grouping: active) { $0.category }

        for category in UserMemoryFact.MemoryCategory.allCases {
            guard let categoryFacts = grouped[category], !categoryFacts.isEmpty else { continue }

            for fact in categoryFacts {
                let line = "- \(fact.content)"
                if totalChars + line.count + 1 > charBudget {
                    // Budget exceeded
                    break
                }
                lines.append(line)
                totalChars += line.count + 1
            }
        }

        // Only return if we have actual facts (not just header)
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    /// Returns a summary of memory for display (e.g., "5 facts stored").
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

    // MARK: - Memory Command Processing

    /// Processes a memory command detected in a user message.
    /// - Returns: A response message if the command was handled, nil otherwise.
    func processCommand(_ command: MemoryCommandPattern.CommandType) -> String? {
        switch command {
        case let .store(content):
            let fact = addFact(content)
            return "I'll remember that: \"\(fact.content)\""

        case let .remove(content):
            // Find and remove matching fact
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
            // Don't actually clear - require confirmation in UI
            return "To clear all memory, please go to Settings → Memory and use the 'Clear All Memory' option."

        case .none:
            return nil
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.saveDebounceDuration ?? .milliseconds(500))
            } catch {
                return // Cancelled
            }

            await self?.saveNow()
        }
    }

    private func saveNow() async {
        let memoryStore = UserMemoryStore(
            facts: facts,
            lastUpdated: Date(),
            version: UserMemoryStore.currentVersion
        )

        do {
            try await store.saveMemory(memoryStore)
        } catch {
            DiagnosticsLogger.log(
                .conversationManager,
                level: .error,
                message: "❌ Failed to save user memory",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    /// Forces an immediate save (e.g., before app termination).
    func saveImmediately() async {
        saveTask?.cancel()
        await saveNow()
    }
}
