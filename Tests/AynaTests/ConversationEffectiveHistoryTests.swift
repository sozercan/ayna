@testable import Ayna
import Foundation
import Testing

@Suite("Conversation Effective History Tests", .tags(.fast))
struct ConversationEffectiveHistoryTests {
    @Test("Selected response linearizes a group and excludes every other status")
    func selectedResponseLinearizesGroup() {
        let groupID = UUID()
        let user = Message(role: .user, content: "Question")
        let failed = Message(id: UUID(), role: .assistant, content: "Failure text", responseGroupId: groupID)
        let streaming = Message(id: UUID(), role: .assistant, content: "Partial text", responseGroupId: groupID)
        let completed = Message(id: UUID(), role: .assistant, content: "Completed fallback", responseGroupId: groupID)
        let selected = Message(id: UUID(), role: .assistant, content: "Chosen answer", responseGroupId: groupID)
        let unselected = Message(id: UUID(), role: .assistant, content: "Other answer", responseGroupId: groupID)
        let nextUser = Message(role: .user, content: "Follow-up")
        let group = ResponseGroup(
            id: groupID,
            userMessageId: user.id,
            responses: [
                .init(id: failed.id, modelName: "failed", status: .failed),
                .init(id: streaming.id, modelName: "streaming", status: .streaming),
                .init(id: completed.id, modelName: "completed", status: .completed),
                .init(id: selected.id, modelName: "selected", status: .selected),
                .init(id: unselected.id, modelName: "unselected", status: .completed),
            ],
            selectedResponseId: selected.id
        )
        let conversation = Conversation(
            messages: [user, failed, streaming, completed, selected, unselected, nextUser],
            responseGroups: [group]
        )

        #expect(conversation.getEffectiveHistory().map(\.id) == [user.id, selected.id, nextUser.id])
    }

    @Test("Fallback uses response entry order and skips incomplete or empty responses")
    func deterministicCompletedNonemptyFallback() {
        let groupID = UUID()
        let user = Message(role: .user, content: "Question")
        let laterCompleted = Message(
            id: UUID(),
            role: .assistant,
            content: "Later in response metadata",
            responseGroupId: groupID
        )
        let emptySelected = Message(
            id: UUID(),
            role: .assistant,
            content: "",
            responseGroupId: groupID
        )
        let preferredCompleted = Message(
            id: UUID(),
            role: .assistant,
            content: "Preferred deterministic fallback",
            responseGroupId: groupID
        )
        let partial = Message(
            id: UUID(),
            role: .assistant,
            content: "Streaming partial",
            responseGroupId: groupID
        )
        let group = ResponseGroup(
            id: groupID,
            userMessageId: user.id,
            responses: [
                .init(id: emptySelected.id, modelName: "selected-empty", status: .selected),
                .init(id: partial.id, modelName: "partial", status: .streaming),
                .init(id: preferredCompleted.id, modelName: "preferred", status: .completed),
                .init(id: laterCompleted.id, modelName: "later", status: .completed),
            ],
            selectedResponseId: emptySelected.id
        )
        let conversation = Conversation(
            messages: [user, laterCompleted, emptySelected, preferredCompleted, partial],
            responseGroups: [group]
        )

        #expect(conversation.getEffectiveHistory().map(\.id) == [user.id, preferredCompleted.id])
    }

    @Test("Unselected groups prefer the conversation model shown as the UI default")
    func unselectedGroupPrefersConversationModel() {
        let groupID = UUID()
        let user = Message(role: .user, content: "Question")
        let arbitraryFirst = Message(
            id: UUID(),
            role: .assistant,
            content: "First set entry",
            model: "model-b",
            responseGroupId: groupID
        )
        let displayedDefault = Message(
            id: UUID(),
            role: .assistant,
            content: "Displayed default",
            model: "model-a",
            responseGroupId: groupID
        )
        let group = ResponseGroup(
            id: groupID,
            userMessageId: user.id,
            responses: [
                .init(id: arbitraryFirst.id, modelName: "model-b", status: .completed),
                .init(id: displayedDefault.id, modelName: "model-a", status: .completed),
            ]
        )
        let conversation = Conversation(
            messages: [user, arbitraryFirst, displayedDefault],
            model: "model-a",
            responseGroups: [group]
        )

        #expect(conversation.getEffectiveHistory().map(\.id) == [user.id, displayedDefault.id])
    }

    @Test("Meaningful metadata survives history filtering while empty assistants do not")
    func meaningfulMetadataSurvives() {
        let groupID = UUID()
        let user = Message(role: .user, content: "Question")
        let emptyPlaceholder = Message(role: .assistant, content: "", mediaType: .image)
        let reasoning = Message(
            id: UUID(),
            role: .assistant,
            content: "",
            responseGroupId: groupID,
            reasoning: "Completed reasoning"
        )
        let text = Message(
            id: UUID(),
            role: .assistant,
            content: "Text fallback",
            responseGroupId: groupID
        )
        let group = ResponseGroup(
            id: groupID,
            userMessageId: user.id,
            responses: [
                .init(id: reasoning.id, modelName: "reasoning", status: .completed),
                .init(id: text.id, modelName: "text", status: .completed),
            ]
        )
        let conversation = Conversation(
            messages: [user, emptyPlaceholder, reasoning, text],
            responseGroups: [group]
        )

        #expect(conversation.getEffectiveHistory().map(\.id) == [user.id, reasoning.id])
    }
}
