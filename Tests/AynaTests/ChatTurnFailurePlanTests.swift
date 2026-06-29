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

    @Test("Plan can remove failed user message for retry policies that re-add it")
    func removesFailedUserForRetryPoliciesThatReaddIt() {
        let user = Message(role: .user, content: "Retry me")
        let assistant = Message(role: .assistant, content: "")

        let plan = ChatTurnFailurePlan(
            messages: [user, assistant],
            failedUserMessageId: user.id,
            assistantPlaceholderId: assistant.id,
            failedUserMessagePolicy: .removeForRetry
        )

        #expect(plan.messagesAfterFailure.isEmpty)
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

}
