//
//  UserMemory.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation

/// A single fact stored in user memory.
/// Facts represent long-term information about the user that persists across conversations.
struct UserMemoryFact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: String
    var category: MemoryCategory
    var source: MemorySource
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        content: String,
        category: MemoryCategory = .other,
        source: MemorySource = .explicit,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
    }

    /// Categories for organizing memory facts.
    enum MemoryCategory: String, Codable, CaseIterable, Sendable {
        case personal // Name, age, location
        case professional // Job, company, skills
        case preferences // Likes, dislikes, communication style
        case projects // Current work, side projects
        case interests // Hobbies, learning goals
        case other

        var displayName: String {
            switch self {
            case .personal: "Personal"
            case .professional: "Professional"
            case .preferences: "Preferences"
            case .projects: "Projects"
            case .interests: "Interests"
            case .other: "Other"
            }
        }

        var icon: String {
            switch self {
            case .personal: "person.fill"
            case .professional: "briefcase.fill"
            case .preferences: "heart.fill"
            case .projects: "hammer.fill"
            case .interests: "star.fill"
            case .other: "tag.fill"
            }
        }
    }

    /// How this fact was added to memory.
    enum MemorySource: String, Codable, Sendable {
        case explicit // User said "remember this"
        case inferred // Model detected stable fact (opt-in)
        case imported // Bulk import

        var displayName: String {
            switch self {
            case .explicit: "Explicit"
            case .inferred: "Inferred"
            case .imported: "Imported"
            }
        }
    }
}

/// Container for all user memory facts with version tracking for migrations.
struct UserMemoryStore: Codable, Sendable {
    var facts: [UserMemoryFact]
    var lastUpdated: Date
    var version: Int

    static let currentVersion = 1

    init(
        facts: [UserMemoryFact] = [],
        lastUpdated: Date = Date(),
        version: Int = currentVersion
    ) {
        self.facts = facts
        self.lastUpdated = lastUpdated
        self.version = version
    }

    /// Returns only active facts
    var activeFacts: [UserMemoryFact] {
        facts.filter(\.isActive)
    }

    /// Returns facts filtered by category
    func facts(in category: UserMemoryFact.MemoryCategory) -> [UserMemoryFact] {
        facts.filter { $0.category == category && $0.isActive }
    }

    /// Merges another store using Last Write Wins strategy.
    /// Used for cross-device sync conflict resolution.
    func merged(with other: UserMemoryStore) -> UserMemoryStore {
        var merged: [UUID: UserMemoryFact] = [:]

        // Add all local facts
        for fact in facts {
            merged[fact.id] = fact
        }

        // Merge remote facts using LWW
        for remoteFact in other.facts {
            if let localFact = merged[remoteFact.id] {
                // Last Write Wins
                merged[remoteFact.id] = localFact.updatedAt > remoteFact.updatedAt ? localFact : remoteFact
            } else {
                merged[remoteFact.id] = remoteFact
            }
        }

        return UserMemoryStore(
            facts: Array(merged.values).sorted { $0.createdAt > $1.createdAt },
            lastUpdated: max(lastUpdated, other.lastUpdated),
            version: max(version, other.version)
        )
    }
}

// MARK: - Memory Command Detection

/// Patterns for detecting memory commands in user messages.
enum MemoryCommandPattern {
    /// Patterns that indicate the user wants to store a fact
    static let storePatterns: [String] = [
        "remember that",
        "remember this:",
        "store in memory",
        "save to memory",
        "add to memory",
        "keep in mind that",
        "note that",
        "don't forget that"
    ]

    /// Patterns that indicate the user wants to remove a fact
    static let removePatterns: [String] = [
        "forget that",
        "delete from memory",
        "remove from memory",
        "stop remembering",
        "clear memory about"
    ]

    /// Patterns that indicate the user wants to view their memory
    static let queryPatterns: [String] = [
        "what do you remember",
        "what do you know about me",
        "show my memory",
        "list my facts",
        "what's in my memory"
    ]

    /// Patterns that indicate the user wants to clear all memory
    static let clearPatterns: [String] = [
        "clear my memory",
        "forget everything",
        "delete all memory",
        "reset my memory"
    ]

    /// Detected command type
    enum CommandType: Sendable {
        case store(content: String)
        case remove(content: String)
        case query
        case clearAll
        case none
    }

    /// Detects memory commands in a user message.
    /// Returns the command type and extracted content if applicable.
    static func detect(in message: String) -> CommandType {
        let lowercased = message.lowercased()

        // Check store patterns
        for pattern in storePatterns where lowercased.contains(pattern) {
            let content = extractContent(from: message, after: pattern)
            if !content.isEmpty {
                return .store(content: content)
            }
        }

        // Check remove patterns
        for pattern in removePatterns where lowercased.contains(pattern) {
            let content = extractContent(from: message, after: pattern)
            if !content.isEmpty {
                return .remove(content: content)
            }
        }

        // Check query patterns
        for pattern in queryPatterns where lowercased.contains(pattern) {
            return .query
        }

        // Check clear patterns
        for pattern in clearPatterns where lowercased.contains(pattern) {
            return .clearAll
        }

        return .none
    }

    /// Extracts content following a pattern in the message.
    private static func extractContent(from message: String, after pattern: String) -> String {
        let lowercased = message.lowercased()
        guard let range = lowercased.range(of: pattern) else { return "" }

        let startIndex = message.index(message.startIndex, offsetBy: lowercased.distance(from: lowercased.startIndex, to: range.upperBound))
        var content = String(message[startIndex...])

        // Clean up the extracted content
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove leading punctuation/whitespace
        while let first = content.first, first.isPunctuation || first.isWhitespace {
            content.removeFirst()
        }

        // Remove trailing punctuation if it's common sentence-ending
        if let last = content.last, [".", "!", "?"].contains(String(last)) {
            content.removeLast()
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
