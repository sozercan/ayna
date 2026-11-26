import Foundation

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

    enum MemorySource: String, Codable, Sendable {
        case explicit
        case inferred
        case imported
    }
}

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

    var activeFacts: [UserMemoryFact] {
        facts.filter(\.isActive)
    }

    func merged(with other: UserMemoryStore) -> UserMemoryStore {
        var merged: [UUID: UserMemoryFact] = [:]

        for fact in facts {
            merged[fact.id] = fact
        }

        for remoteFact in other.facts {
            if let localFact = merged[remoteFact.id] {
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

enum MemoryCommandPattern {
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

    static let removePatterns: [String] = [
        "forget that",
        "delete from memory",
        "remove from memory",
        "stop remembering",
        "clear memory about"
    ]

    static let queryPatterns: [String] = [
        "what do you remember",
        "what do you know about me",
        "show my memory",
        "list my facts",
        "what's in my memory"
    ]

    static let clearPatterns: [String] = [
        "clear my memory",
        "forget everything",
        "delete all memory",
        "reset my memory"
    ]

    enum CommandType: Sendable {
        case store(content: String)
        case remove(content: String)
        case query
        case clearAll
        case none
    }

    static func detect(in message: String) -> CommandType {
        for pattern in storePatterns {
            guard let matchEnd = matchEndWithWordBoundary(message, pattern: pattern) else { continue }
            let content = extractContent(from: message, startingAt: matchEnd)
            if !content.isEmpty {
                return .store(content: content)
            }
        }

        for pattern in removePatterns {
            guard let matchEnd = matchEndWithWordBoundary(message, pattern: pattern) else { continue }
            let content = extractContent(from: message, startingAt: matchEnd)
            if !content.isEmpty {
                return .remove(content: content)
            }
        }

        for pattern in queryPatterns where matchEndWithWordBoundary(message, pattern: pattern) != nil {
            return .query
        }

        for pattern in clearPatterns where matchEndWithWordBoundary(message, pattern: pattern) != nil {
            return .clearAll
        }

        return .none
    }

    private static func matchEndWithWordBoundary(_ text: String, pattern: String) -> String.Index? {
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

    private static func extractContent(from message: String, startingAt startIndex: String.Index) -> String {
        var content = String(message[startIndex...])

        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        while let first = content.first, first.isPunctuation || first.isWhitespace {
            content.removeFirst()
        }

        if let last = content.last, [".", "!", "?"].contains(String(last)) {
            content.removeLast()
        }

        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizeFact(content)
    }

    private static func normalizeFact(_ content: String) -> String {
        var fact = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return fact }

        let conversions: [(pattern: String, replacement: String)] = [
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

        if let first = fact.first {
            fact = first.uppercased() + fact.dropFirst()
        }

        if !fact.isEmpty, let last = fact.last, !last.isPunctuation {
            fact += "."
        }

        return fact
    }
}
