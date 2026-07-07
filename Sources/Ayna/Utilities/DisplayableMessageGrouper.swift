import Foundation

/// Groups already-visible chat messages into display rows.
///
/// Response-group rows are emitted at the first visible response's position and collect every
/// later response with the same group id. This matches the chat views' previous display behavior
/// without re-scanning the whole message list for every group.
enum DisplayableMessageGrouper {
    enum Item: Identifiable {
        case message(Message)
        case responseGroup(groupId: UUID, responses: [Message])

        var id: String {
            switch self {
            case let .message(message):
                message.id.uuidString
            case let .responseGroup(groupId, _):
                "group-\(groupId.uuidString)"
            }
        }
    }

    private struct Slot {
        var message: Message?
        var groupId: UUID?
        var responses: [Message]

        static func message(_ message: Message) -> Slot {
            Slot(message: message, groupId: nil, responses: [])
        }

        static func responseGroup(groupId: UUID, firstResponse: Message) -> Slot {
            Slot(message: nil, groupId: groupId, responses: [firstResponse])
        }
    }

    nonisolated static func items(from visibleMessages: [Message]) -> [Item] {
        var slots: [Slot] = []
        slots.reserveCapacity(visibleMessages.count)

        var groupSlotIndexes: [UUID: Int] = [:]
        groupSlotIndexes.reserveCapacity(visibleMessages.count / 2)

        for message in visibleMessages {
            guard let groupId = message.responseGroupId else {
                slots.append(.message(message))
                continue
            }

            if let slotIndex = groupSlotIndexes[groupId] {
                slots[slotIndex].responses.append(message)
            } else {
                groupSlotIndexes[groupId] = slots.count
                slots.append(.responseGroup(groupId: groupId, firstResponse: message))
            }
        }

        return slots.map { slot in
            if let groupId = slot.groupId {
                return .responseGroup(groupId: groupId, responses: slot.responses)
            }
            guard let message = slot.message else {
                preconditionFailure("DisplayableMessageGrouper slot missing message and group id")
            }
            return .message(message)
        }
    }

    nonisolated static func displayableItems<DisplayItem>(
        from visibleMessages: [Message],
        makeMessage: (Message) -> DisplayItem,
        makeResponseGroup: (UUID, [Message]) -> DisplayItem
    ) -> [DisplayItem] {
        items(from: visibleMessages).map { item in
            switch item {
            case let .message(message):
                makeMessage(message)
            case let .responseGroup(groupId, responses):
                makeResponseGroup(groupId, responses)
            }
        }
    }
}
