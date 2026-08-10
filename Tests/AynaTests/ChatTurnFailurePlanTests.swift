@testable import Ayna
import Foundation
import Testing

@Suite("ChatTurnFailurePlan Tests", .tags(.fast))
struct ChatTurnFailurePlanTests {
    @Test
    func `preserves the failed user and removes only its empty assistant placeholder`() {
        let earlier = Message(role: .assistant, content: "Earlier")
        let user = Message(role: .user, content: "Try this")
        let placeholder = Message(role: .assistant, content: "")

        let plan = ChatTurnFailurePlan(
            messages: [earlier, user, placeholder],
            failedUserMessageId: user.id,
            assistantPlaceholderId: placeholder.id,
            failedUserMessagePolicy: .preserve
        )

        #expect(plan.messagesAfterFailure == [earlier, user])
        #expect(plan.retryPrompt == nil)
    }

    @Test
    func `offers retry for a text-only user turn with no assistant output`() {
        let user = Message(role: .user, content: "Retry me")
        let placeholder = Message(role: .assistant, content: "")

        let plan = ChatTurnFailurePlan(
            messages: [user, placeholder],
            failedUserMessageId: user.id,
            assistantPlaceholderId: placeholder.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == user.content)
    }

    @Test
    func `immediate failure remains retryable after empty placeholder finalization`() {
        let user = Message(role: .user, content: "Retry me")
        let placeholder = Message(role: .assistant, content: "")
        var conversation = Conversation(messages: [user, placeholder])

        let finalization = ChatGenerationFinalizer.finalize(
            conversation: &conversation,
            activeAssistantMessageID: placeholder.id,
            activeResponseGroupID: nil
        )

        let plan = ChatTurnFailurePlan(
            messages: conversation.messages,
            failedUserMessageId: user.id,
            assistantPlaceholderId: placeholder.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(finalization.removedAssistantMessageID == placeholder.id)
        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == user.content)
    }

    @Test
    func `retry truncates the complete failed turn including tool continuations`() {
        let earlier = Message(role: .assistant, content: "Earlier")
        let user = Message(role: .user, content: "Search")
        var toolRequest = Message(role: .assistant, content: "")
        let toolResult = Message(role: .tool, content: "Result")
        let continuation = Message(role: .assistant, content: "")
        toolRequest.toolCalls = [MCPToolCall(toolName: "web_search", arguments: [:])]

        let plan = ChatTurnFailurePlan(
            messages: [earlier, user, toolRequest, toolResult, continuation],
            failedUserMessageId: user.id,
            assistantPlaceholderId: continuation.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.retryPrompt == user.content)
        #expect(ChatTurnFailurePlan.messagesBeforeFailedTurn(
            in: plan.messagesAfterFailure,
            failedUserMessageId: user.id
        ) == [earlier])
    }

    @Test
    func `preserves partial text, reasoning, citations, and tool metadata`() {
        let user = Message(role: .user, content: "Hello")
        var toolAssistant = Message(role: .assistant, content: "")
        toolAssistant.toolCalls = [MCPToolCall(toolName: "web_search", arguments: [:])]
        let assistants = [
            Message(role: .assistant, content: "Partial response"),
            Message(role: .assistant, content: "", reasoning: "Thinking"),
            Message(
                role: .assistant,
                content: "",
                citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
            ),
            toolAssistant,
        ]

        for assistant in assistants {
            let plan = ChatTurnFailurePlan(
                messages: [user, assistant],
                failedUserMessageId: user.id,
                assistantPlaceholderId: assistant.id,
                failedUserMessagePolicy: .preserve
            )
            #expect(plan.messagesAfterFailure == [user, assistant])
        }
    }

    @Test
    func `treats whitespace-only content and reasoning as an empty placeholder`() {
        let user = Message(role: .user, content: "Retry me")
        let assistant = Message(role: .assistant, content: " \n ", reasoning: "\t")

        let plan = ChatTurnFailurePlan(
            messages: [user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == user.content)
    }

    @Test
    func `does not offer text-only retry for attachment prompts`() {
        var user = Message(role: .user, content: "See attached")
        user.attachments = [Message.FileAttachment(
            fileName: "notes.txt",
            mimeType: "text/plain",
            data: Data([1, 2, 3])
        )]
        let placeholder = Message(role: .assistant, content: "")

        let plan = ChatTurnFailurePlan(
            messages: [user, placeholder],
            failedUserMessageId: user.id,
            assistantPlaceholderId: placeholder.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == nil)
    }
}
