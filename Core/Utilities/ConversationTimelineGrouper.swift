import Foundation

struct ConversationTimelineSection: Identifiable, Equatable {
    let title: String
    var conversations: [Conversation]

    var id: String {
        title
    }
}

enum ConversationTimelineGrouper {
    static func sections(
        from conversations: [Conversation],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [ConversationTimelineSection] {
        let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }
        var sections: [ConversationTimelineSection] = []

        for conversation in sorted {
            let sectionTitle = title(for: conversation.updatedAt, calendar: calendar, now: now)

            if sections.last?.title == sectionTitle {
                sections[sections.count - 1].conversations.append(conversation)
            } else {
                sections.append(ConversationTimelineSection(title: sectionTitle, conversations: [conversation]))
            }
        }

        return sections
    }

    static func title(
        for date: Date,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> String {
        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)

        guard let dayDifference = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day else {
            return "Earlier"
        }

        switch dayDifference {
        case Int.min ..< 0:
            return "Upcoming"
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2:
            return "2 days ago"
        case 3 ... 6:
            return "\(dayDifference) days ago"
        case 7 ... 13:
            return "1 week ago"
        case 14 ... 20:
            return "2 weeks ago"
        case 21 ... 27:
            return "3 weeks ago"
        case 28 ... 59:
            return "1 month ago"
        case 60 ... 364:
            let months = max(2, dayDifference / 30)
            return "\(months) months ago"
        case 365 ... 729:
            return "1 year ago"
        default:
            let years = max(2, dayDifference / 365)
            return "\(years) years ago"
        }
    }
}
