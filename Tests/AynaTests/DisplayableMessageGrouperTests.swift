@testable import Ayna
import Foundation
import Testing

@Suite("DisplayableMessageGrouper Tests", .tags(.fast))
struct DisplayableMessageGrouperTests {
    @Test("Groups responses at first response position and preserves row order")
    func groupsResponsesAtFirstResponsePositionAndPreservesRowOrder() {
        let firstGroupId = UUID()
        let secondGroupId = UUID()
        let prompt = message(role: .user, content: "Prompt")
        let firstResponse = message(content: "First model", groupId: firstGroupId)
        let interleavedPrompt = message(role: .user, content: "Interleaved prompt")
        let secondGroupFirstResponse = message(content: "Other first", groupId: secondGroupId)
        let firstGroupLaterResponse = message(content: "Second model", groupId: firstGroupId)
        let secondGroupLaterResponse = message(content: "Other second", groupId: secondGroupId)

        let items = DisplayableMessageGrouper.items(from: [
            prompt,
            firstResponse,
            interleavedPrompt,
            secondGroupFirstResponse,
            firstGroupLaterResponse,
            secondGroupLaterResponse,
        ])

        #expect(items.count == 4)

        guard case let .message(firstItem) = items[0] else {
            Issue.record("Expected the prompt to remain the first display item")
            return
        }
        #expect(firstItem.id == prompt.id)

        guard case let .responseGroup(groupId, responses) = items[1] else {
            Issue.record("Expected first response group at first response position")
            return
        }
        #expect(groupId == firstGroupId)
        #expect(responses.map(\.id) == [firstResponse.id, firstGroupLaterResponse.id])

        guard case let .message(thirdItem) = items[2] else {
            Issue.record("Expected interleaved prompt after first group")
            return
        }
        #expect(thirdItem.id == interleavedPrompt.id)

        guard case let .responseGroup(secondGroup, secondResponses) = items[3] else {
            Issue.record("Expected second response group at its first response position")
            return
        }
        #expect(secondGroup == secondGroupId)
        #expect(secondResponses.map(\.id) == [secondGroupFirstResponse.id, secondGroupLaterResponse.id])
    }

    @Test("Groups ten thousand visible messages", .timeLimit(.minutes(1)))
    func groupsTenThousandVisibleMessages() {
        let exchangeCount = 2500
        var messages: [Message] = []
        messages.reserveCapacity(exchangeCount * 4)

        for index in 0 ..< exchangeCount {
            messages.append(message(role: .user, content: "Prompt \(index)"))
            let groupId = UUID()
            messages.append(message(content: "Model A \(index)", groupId: groupId))
            messages.append(message(content: "Model B \(index)", groupId: groupId))
            messages.append(message(content: "Model C \(index)", groupId: groupId))
        }

        let start = CFAbsoluteTimeGetCurrent()
        let items = DisplayableMessageGrouper.items(from: messages)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let groupedResponseCount = items.reduce(into: 0) { count, item in
            if case let .responseGroup(_, responses) = item {
                count += responses.count
            }
        }

        print("BENCH display-grouping.messages.10k seconds=\(elapsed) items=\(items.count)")
        #expect(messages.count == 10000)
        #expect(items.count == exchangeCount * 2)
        #expect(groupedResponseCount == exchangeCount * 3)
    }

    private func message(
        role: Message.Role = .assistant,
        content: String,
        groupId: UUID? = nil
    ) -> Message {
        Message(role: role, content: content, responseGroupId: groupId)
    }
}
