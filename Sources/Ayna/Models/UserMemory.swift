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
    var source: MemorySource
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        content: String,
        source: MemorySource = .explicit,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
    }

    /// How this fact was added to memory.
    enum MemorySource: String, Codable, Sendable {
        case explicit // User said "remember this"
        case inferred // Model detected stable fact (opt-in)
        case imported // Bulk import
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
        // Check store patterns (using word boundaries to avoid false positives)
        for pattern in storePatterns {
            guard let matchEnd = matchEndWithWordBoundary(message, pattern: pattern) else { continue }
            let content = extractContent(from: message, startingAt: matchEnd)
            if !content.isEmpty {
                return .store(content: content)
            }
        }

        // Check remove patterns
        for pattern in removePatterns {
            guard let matchEnd = matchEndWithWordBoundary(message, pattern: pattern) else { continue }
            let content = extractContent(from: message, startingAt: matchEnd)
            if !content.isEmpty {
                return .remove(content: content)
            }
        }

        // Check query patterns
        for pattern in queryPatterns where matchEndWithWordBoundary(message, pattern: pattern) != nil {
            return .query
        }

        // Check clear patterns
        for pattern in clearPatterns where matchEndWithWordBoundary(message, pattern: pattern) != nil {
            return .clearAll
        }

        return .none
    }

    /// Finds the pattern at a word boundary to avoid false positives and returns the index just past it.
    /// e.g., "remember that" matches "Remember that I like tea" but not "I can't remember that password"
    private static func matchEndWithWordBoundary(_ text: String, pattern: String) -> String.Index? {
        // For patterns that should match at the start of a sentence or after common prefixes
        // We check: start of string, after punctuation, or after "please"
        let regexPattern = "(^|[.!?]\\s*|please\\s+)\(NSRegularExpression.escapedPattern(for: pattern))"
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text)
        else {
            return nil
        }
        return matchRange.upperBound
    }

    /// Extracts the content that follows a matched command pattern.
    private static func extractContent(from message: String, startingAt startIndex: String.Index) -> String {
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

        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize into a clean fact
        return normalizeFact(content)
    }

    /// Normalizes extracted content into a clean, third-person fact.
    /// Examples:
    /// - "i like tea" → "Likes tea."
    /// - "my name is John" → "Name is John."
    /// - "I'm a software engineer" → "Is a software engineer."
    /// - "I prefer dark mode" → "Prefers dark mode."
    private static func normalizeFact(_ content: String) -> String {
        var fact = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return fact }

        // First-person to third-person conversions
        let conversions: [(pattern: String, replacement: String)] = [
            // "i like X" → "Likes X"
            ("^i like ", "Likes "),
            ("^i really like ", "Really likes "),
            ("^i love ", "Loves "),
            ("^i hate ", "Dislikes "),
            ("^i dislike ", "Dislikes "),
            ("^i prefer ", "Prefers "),
            ("^i want ", "Wants "),
            ("^i need ", "Needs "),
            ("^i have ", "Has "),
            ("^i am ", "Is "),
            ("^i'm ", "Is "),
            ("^im ", "Is "),
            ("^i work ", "Works "),
            ("^i live ", "Lives "),
            ("^i use ", "Uses "),
            ("^i speak ", "Speaks "),
            ("^i know ", "Knows "),
            ("^i can ", "Can "),
            // "my X is Y" → "X is Y"
            ("^my name is ", "Name is "),
            ("^my job is ", "Job is "),
            ("^my favorite ", "Favorite "),
            ("^my ", ""),
        ]

        for (pattern, replacement) in conversions {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(fact.startIndex..., in: fact)
                if regex.firstMatch(in: fact, range: range) != nil {
                    fact = regex.stringByReplacingMatches(
                        in: fact,
                        range: range,
                        withTemplate: replacement
                    )
                    break
                }
            }
        }

        // Capitalize first letter
        if let first = fact.first {
            fact = first.uppercased() + fact.dropFirst()
        }

        // Ensure ends with period
        if !fact.isEmpty, let last = fact.last, !last.isPunctuation {
            fact += "."
        }

        return fact
    }
}
