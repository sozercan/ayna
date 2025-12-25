import Foundation
import Testing

@testable import Ayna

@Suite("ConversationTimelineGrouper Tests")
struct ConversationTimelineGrouperTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("Timeline titles")
    func timelineTitles() {
        let now = date(year: 2025, month: 11, day: 18)
        let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!
        let nineDaysAgo = calendar.date(byAdding: .day, value: -9, to: now)!
        let fortyDaysAgo = calendar.date(byAdding: .day, value: -40, to: now)!
        let fourHundredDaysAgo = calendar.date(byAdding: .day, value: -400, to: now)!

        #expect(ConversationTimelineGrouper.title(for: now, calendar: calendar, now: now) == "Today")
        #expect(ConversationTimelineGrouper.title(for: oneDayAgo, calendar: calendar, now: now) == "Yesterday")
        #expect(ConversationTimelineGrouper.title(for: twoDaysAgo, calendar: calendar, now: now) == "2 days ago")
        #expect(ConversationTimelineGrouper.title(for: nineDaysAgo, calendar: calendar, now: now) == "1 week ago")
        #expect(ConversationTimelineGrouper.title(for: fortyDaysAgo, calendar: calendar, now: now) == "1 month ago")
        #expect(ConversationTimelineGrouper.title(for: fourHundredDaysAgo, calendar: calendar, now: now) == "1 year ago")
    }

    @Test("Sections are grouped and sorted")
    func sectionsAreGroupedAndSorted() {
        let now = date(year: 2025, month: 11, day: 18)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!

        let conversations = [
            Conversation(title: "Today A", updatedAt: now, model: "gpt-4o"),
            Conversation(title: "Two Days", updatedAt: twoDaysAgo, model: "gpt-4o"),
            Conversation(title: "Yesterday", updatedAt: yesterday, model: "gpt-4o"),
            Conversation(title: "Today B", updatedAt: now.addingTimeInterval(-60), model: "gpt-4o")
        ]

        let sections = ConversationTimelineGrouper.sections(from: conversations, calendar: calendar, now: now)

        #expect(sections.count == 3)
        #expect(sections[0].title == "Today")
        #expect(sections[0].conversations.map(\.title) == ["Today A", "Today B"])
        #expect(sections[1].title == "Yesterday")
        #expect(sections[1].conversations.first?.title == "Yesterday")
        #expect(sections[2].title == "2 days ago")
        #expect(sections[2].conversations.first?.title == "Two Days")
    }
}
