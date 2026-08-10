@testable import Ayna
import Foundation
import Testing

@Suite("ChatTurnRequestPlan Tests", .tags(.fast))
struct ChatTurnRequestPlanTests {
    @Test
    func `prepends a non-empty system prompt`() {
        let user = Message(role: .user, content: "Hello")

        let plan = ChatTurnRequestPlan(history: [user], systemPrompt: "Be concise")

        #expect(plan.messages.count == 2)
        #expect(plan.messages[0].role == .system)
        #expect(plan.messages[0].content == "Be concise")
        #expect(plan.messages[1] == user)
    }

    @Test
    func `ignores empty and whitespace-only system prompts`() {
        let user = Message(role: .user, content: "Hello")

        #expect(ChatTurnRequestPlan(history: [user], systemPrompt: "").messages == [user])
        #expect(ChatTurnRequestPlan(history: [user], systemPrompt: "  \n ").messages == [user])
    }

    @Test
    func `excludes only the matching assistant placeholder`() {
        let user = Message(role: .user, content: "Hello")
        let earlierAssistant = Message(role: .assistant, content: "Earlier")
        let placeholder = Message(role: .assistant, content: "")
        let conversation = Conversation(messages: [user, earlierAssistant, placeholder])

        let plan = ChatTurnRequestPlan(
            conversation: conversation,
            systemPrompt: nil,
            excludingAssistantPlaceholderId: placeholder.id
        )

        #expect(plan.messages == [user, earlierAssistant])
    }

    @Test
    func `does not drop a user message when given the wrong placeholder identity`() {
        let assistant = Message(role: .assistant, content: "Response")
        let user = Message(role: .user, content: "Follow up")
        let conversation = Conversation(messages: [assistant, user])

        let plan = ChatTurnRequestPlan(
            conversation: conversation,
            systemPrompt: nil,
            excludingAssistantPlaceholderId: user.id
        )

        #expect(plan.messages == [assistant, user])
    }

    @Test
    func `uses effective history for selected multi-model responses`() {
        let groupId = UUID()
        let user = Message(role: .user, content: "Compare")
        let unselected = Message(
            role: .assistant,
            content: "First response",
            model: "model-a",
            responseGroupId: groupId
        )
        let selected = Message(
            role: .assistant,
            content: "Selected response",
            model: "model-b",
            responseGroupId: groupId
        )
        let followUp = Message(role: .user, content: "Continue")
        let placeholder = Message(role: .assistant, content: "")
        let responseGroup = ResponseGroup(
            id: groupId,
            userMessageId: user.id,
            responses: [
                .init(id: unselected.id, modelName: "model-a", status: .completed),
                .init(id: selected.id, modelName: "model-b", status: .selected),
            ],
            selectedResponseId: selected.id
        )
        let conversation = Conversation(
            messages: [user, unselected, selected, followUp, placeholder],
            responseGroups: [responseGroup]
        )

        let plan = ChatTurnRequestPlan(
            conversation: conversation,
            systemPrompt: nil,
            excludingAssistantPlaceholderId: placeholder.id
        )

        #expect(plan.messages == [user, selected, followUp])
    }

    @Test
    func `can exclude an in-flight response group`() {
        let groupId = UUID()
        let user = Message(role: .user, content: "Compare")
        let grouped = Message(
            role: .assistant,
            content: "A",
            model: "model-a",
            responseGroupId: groupId
        )
        let conversation = Conversation(messages: [user, grouped])

        let messages = ChatTurnRequestPlan.effectiveMessages(
            from: conversation,
            systemPrompt: "System",
            excludingResponseGroupId: groupId
        )

        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        #expect(messages[1] == user)
    }
}
