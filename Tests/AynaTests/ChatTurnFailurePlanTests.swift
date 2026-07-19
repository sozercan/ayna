@testable import Ayna
import Foundation
import Testing

@Suite("ChatTurnFailurePlan Tests", .tags(.fast))
struct ChatTurnFailurePlanTests {
    @Test("Plan preserves failed user message and removes matching empty assistant placeholder")
    func preservesUserAndRemovesMatchingAssistantPlaceholder() throws {
        let user = Message(role: .user, content: "Try this")
        let assistant = Message(role: .assistant, content: "")
        let otherAssistant = Message(role: .assistant, content: "Earlier")

        let plan = ChatTurnFailurePlan(
            messages: [otherAssistant, user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .preserve
        )

        #expect(plan.messagesAfterFailure == [otherAssistant, user])
        #expect(plan.retryPrompt == nil)
    }

    @Test("Plan preserves failed user message and offers retry text")
    func preservesFailedUserAndOffersRetryText() {
        let user = Message(role: .user, content: "Retry me")
        let assistant = Message(role: .assistant, content: "")

        let plan = ChatTurnFailurePlan(
            messages: [user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == "Retry me")
    }

    @Test("Preserve policy does not remove non-empty assistant responses with matching id")
    func preservePolicyDoesNotRemoveNonEmptyAssistantResponsesWithMatchingId() {
        let user = Message(role: .user, content: "Hello")
        let assistant = Message(role: .assistant, content: "Partial response")

        let plan = ChatTurnFailurePlan(
            messages: [user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .preserve
        )

        #expect(plan.messagesAfterFailure == [user, assistant])
        #expect(plan.retryPrompt == nil)
    }

    @Test("Remove-for-retry policy preserves partial assistant with failed user")
    func removeForRetryPolicyPreservesPartialAssistantWithFailedUser() {
        let user = Message(role: .user, content: "Hello")
        let assistant = Message(role: .assistant, content: "Partial response")

        let plan = ChatTurnFailurePlan(
            messages: [user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user, assistant])
        #expect(plan.retryPrompt == nil)
    }

    @Test("Plan ignores placeholder id when it belongs to a user message")
    func ignoresPlaceholderIdWhenItBelongsToUserMessage() {
        let user = Message(role: .user, content: "Do not remove")

        let plan = ChatTurnFailurePlan(
            messages: [user],
            failedUserMessageId: user.id,
            assistantPlaceholderId: user.id,
            failedUserMessagePolicy: .preserve
        )

        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == nil)
    }

    @Test("Remove-for-retry preserves attachment user messages and suppresses text-only retry")
    func removeForRetryPreservesAttachmentUserMessagesAndSuppressesTextOnlyRetry() {
        var user = Message(role: .user, content: "See attached")
        user.attachments = [Message.FileAttachment(
            fileName: "notes.txt",
            mimeType: "text/plain",
            data: Data([1, 2, 3])
        )]
        let assistant = Message(role: .assistant, content: "")

        let plan = ChatTurnFailurePlan(
            messages: [user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == nil)
    }

    @Test("Remove-for-retry preserves attachment user and partial assistant together")
    func removeForRetryPreservesAttachmentUserAndPartialAssistantTogether() {
        var user = Message(role: .user, content: "See attached")
        user.attachments = [Message.FileAttachment(
            fileName: "notes.txt",
            mimeType: "text/plain",
            data: Data([1, 2, 3])
        )]
        let assistant = Message(role: .assistant, content: "Partial response")

        let plan = ChatTurnFailurePlan(
            messages: [user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user, assistant])
        #expect(plan.retryPrompt == nil)
    }

    @Test("Remove-for-retry preserves user when assistant placeholder is missing")
    func removeForRetryPreservesUserWhenAssistantPlaceholderIsMissing() {
        let user = Message(role: .user, content: "Retry me")

        let plan = ChatTurnFailurePlan(
            messages: [user],
            failedUserMessageId: user.id,
            assistantPlaceholderId: UUID(),
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure == [user])
        #expect(plan.retryPrompt == nil)
    }

    @Test("Plan preserves empty assistant messages with reasoning or citations")
    func preservesEmptyAssistantMessagesWithReasoningOrCitations() {
        let user = Message(role: .user, content: "Hello")
        let reasoningAssistant = Message(role: .assistant, content: "", reasoning: "Thinking")
        let citedAssistant = Message(
            role: .assistant,
            content: "",
            citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
        )

        let reasoningPlan = ChatTurnFailurePlan(
            messages: [user, reasoningAssistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: reasoningAssistant.id,
            failedUserMessagePolicy: .removeForRetry
        )
        let citationPlan = ChatTurnFailurePlan(
            messages: [user, citedAssistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: citedAssistant.id,
            failedUserMessagePolicy: .preserve
        )

        #expect(reasoningPlan.messagesAfterFailure == [user, reasoningAssistant])
        #expect(reasoningPlan.retryPrompt == nil)
        #expect(citationPlan.messagesAfterFailure == [user, citedAssistant])
        #expect(citationPlan.retryPrompt == nil)
    }

    @Test("Plan preserves empty assistant messages with tool metadata")
    func preservesEmptyAssistantMessagesWithToolMetadata() {
        #if !os(watchOS)
            let user = Message(role: .user, content: "Hello")
            var assistant = Message(role: .assistant, content: "")
            assistant.toolCalls = [MCPToolCall(toolName: "web_search", arguments: [:])]

            let plan = ChatTurnFailurePlan(
                messages: [user, assistant],
                failedUserMessageId: user.id,
                assistantPlaceholderId: assistant.id,
                failedUserMessagePolicy: .removeForRetry
            )

            #expect(plan.messagesAfterFailure == [user, assistant])
            #expect(plan.retryPrompt == nil)
        #endif
    }

}
