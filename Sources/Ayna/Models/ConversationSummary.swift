import Foundation

struct ConversationSummary: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var timestamp: Date
    var userMessageSnippets: [String]
    var topics: [String]

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

    static let maxSnippets = 3

    static let maxSnippetLength = 100

    private static let contextDateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)

    func formattedForContext() -> String {
        var lines = ["\(timestamp.formatted(Self.contextDateStyle)): \(title)"]

        for snippet in userMessageSnippets {
            lines.append("   |||| \(snippet) ||||")
        }

        return lines.joined(separator: "\n")
    }
}

struct RecentConversationsDigest: Codable, Sendable {
    var summaries: [ConversationSummary]
    var lastComputed: Date
    var maxSummaries: Int

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

    mutating func upsertSummary(_ summary: ConversationSummary) {
        summaries.removeAll { $0.id == summary.id }

        summaries.insert(summary, at: 0)

        summaries.sort { $0.timestamp > $1.timestamp }

        if summaries.count > maxSummaries {
            summaries = Array(summaries.prefix(maxSummaries))
        }

        lastComputed = Date()
    }

    mutating func removeSummary(for conversationId: UUID) {
        summaries.removeAll { $0.id == conversationId }
        lastComputed = Date()
    }

    func formattedForContext() -> String {
        guard !summaries.isEmpty else { return "" }

        var lines = ["Recent Conversations:"]

        for (index, summary) in summaries.enumerated() {
            let formatted = summary.formattedForContext()
            lines.append("\(index + 1). \(formatted)")
        }

        return lines.joined(separator: "\n")
    }

    mutating func pruneOlder(than days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        summaries.removeAll { $0.timestamp < cutoff }
        lastComputed = Date()
    }
}
