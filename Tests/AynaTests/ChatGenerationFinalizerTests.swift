@testable import Ayna
import Foundation
import Testing

@Suite("Chat Generation Finalizer Tests")
struct ChatGenerationFinalizerTests {
    @Test
    func `cancellation flushes pending text and preserves the partial response`() {
        let assistantID = UUID()
        var conversation = Conversation(messages: [
            Message(id: assistantID, role: .assistant, content: "partial")
        ])

        let result = ChatGenerationFinalizer.finalize(
            conversation: &conversation,
            activeAssistantMessageID: assistantID,
            pendingText: " response",
            activeResponseGroupID: nil
        )

        #expect(result.appendedCharacterCount == 9)
        #expect(result.removedAssistantMessageID == nil)
        #expect(conversation.messages.first?.content == "partial response")
    }

    @Test
    func `cancellation removes only the empty active text placeholder`() {
        let unrelatedID = UUID()
        let activeID = UUID()
        var conversation = Conversation(messages: [
            Message(id: unrelatedID, role: .assistant, content: ""),
            Message(id: activeID, role: .assistant, content: "")
        ])

        let result = ChatGenerationFinalizer.finalize(
            conversation: &conversation,
            activeAssistantMessageID: activeID,
            activeResponseGroupID: nil
        )

        #expect(result.removedAssistantMessageID == activeID)
        #expect(conversation.messages.map(\.id) == [unrelatedID])
    }

    @Test
    func `cancellation terminalizes active multi-model entries without deleting responses`() {
        let groupID = UUID()
        let partialID = UUID()
        let emptyID = UUID()
        let completedID = UUID()
        let userID = UUID()
        var conversation = Conversation(
            messages: [
                Message(id: partialID, role: .assistant, content: "partial", responseGroupId: groupID),
                Message(id: emptyID, role: .assistant, content: "", responseGroupId: groupID),
                Message(id: completedID, role: .assistant, content: "done", responseGroupId: groupID)
            ],
            responseGroups: [
                ResponseGroup(
                    id: groupID,
                    userMessageId: userID,
                    responses: [
                        .init(id: partialID, modelName: "one", status: .streaming),
                        .init(id: emptyID, modelName: "two", status: .streaming),
                        .init(id: completedID, modelName: "three", status: .completed)
                    ]
                )
            ]
        )

        let result = ChatGenerationFinalizer.finalize(
            conversation: &conversation,
            activeAssistantMessageID: nil,
            activeResponseGroupID: groupID
        )

        #expect(result.terminalizedResponseCount == 2)
        #expect(conversation.messages.map(\.id) == [partialID, emptyID, completedID])
        #expect(conversation.responseGroups[0].responses.map(\.status) == [.failed, .failed, .completed])
    }

    @Test
    func `reasoning-only assistant output is preserved`() {
        let assistantID = UUID()
        var conversation = Conversation(messages: [
            Message(id: assistantID, role: .assistant, content: "", reasoning: "thinking")
        ])

        ChatGenerationFinalizer.finalize(
            conversation: &conversation,
            activeAssistantMessageID: assistantID,
            activeResponseGroupID: nil
        )

        #expect(conversation.messages.map(\.id) == [assistantID])
    }
    @Test("Citation-only assistant output is preserved")
    func preservesCitationOnlyOutput() {
        let assistantID = UUID()
        var conversation = Conversation(messages: [
            Message(
                id: assistantID,
                role: .assistant,
                content: "",
                citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
            )
        ])

        ChatGenerationFinalizer.finalize(
            conversation: &conversation,
            activeAssistantMessageID: assistantID,
            activeResponseGroupID: nil
        )

        #expect(conversation.messages.map(\.id) == [assistantID])
        #expect(conversation.messages.first?.citations?.first?.title == "Source")
    }

}
