@testable import Ayna
import Foundation
import Testing

@Suite("ChatTranscriptPlan Tests", .tags(.fast))
struct ChatTranscriptPlanTests {
    @Test("Plan hides system and empty tool messages but shows non-empty tools")
    func hidesSystemAndEmptyToolMessages() {
        let system = Message(role: .system, content: "Hidden")
        let emptyTool = Message(role: .tool, content: "  \n")
        let tool = Message(role: .tool, content: "Search result")
        let conversation = Conversation(messages: [system, emptyTool, tool])

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.visibleMessages.map(\.id) == [tool.id])
        #expect(plan.items == [.message(ChatTranscriptMessage(message: tool, displayKind: .toolResult))])
    }

    @Test("Plan hides empty assistant tool-call placeholders")
    func hidesEmptyAssistantToolCallPlaceholders() {
        #if !os(watchOS)
            var placeholder = Message(role: .assistant, content: "")
            placeholder.toolCalls = [MCPToolCall(toolName: "web_search", arguments: [:])]
            let visible = Message(role: .assistant, content: "Done")
            let conversation = Conversation(messages: [placeholder, visible])

            let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: true)

            #expect(plan.visibleMessages.map(\.id) == [visible.id])
            #expect(plan.items == [.message(ChatTranscriptMessage(message: visible, displayKind: .text))])
        #endif
    }

    @Test("Plan shows citations-only assistant messages")
    func showsCitationsOnlyAssistantMessages() {
        let message = Message(
            role: .assistant,
            content: "",
            citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
        )
        let conversation = Conversation(messages: [message])

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.visibleMessages == [ChatTranscriptMessage(message: message, displayKind: .citationsOnly)])
        #expect(plan.items == [.message(ChatTranscriptMessage(message: message, displayKind: .citationsOnly))])
    }


    @Test("Plan treats last empty cited assistant as typing while generating")
    func treatsLastEmptyCitedAssistantAsTypingWhileGenerating() {
        let message = Message(
            role: .assistant,
            content: "",
            citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
        )
        let conversation = Conversation(messages: [message])

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: true)

        #expect(plan.visibleMessages == [ChatTranscriptMessage(message: message, displayKind: .typingPlaceholder)])
        #expect(plan.items == [.message(ChatTranscriptMessage(message: message, displayKind: .typingPlaceholder))])
    }

    @Test("Plan keeps empty response-group placeholders visible and grouped")
    func keepsEmptyResponseGroupPlaceholdersVisibleAndGrouped() {
        let groupId = UUID()
        let first = Message(role: .assistant, content: "", model: "gpt-a", responseGroupId: groupId)
        let second = Message(role: .assistant, content: "", model: "gpt-b", responseGroupId: groupId)
        let group = ResponseGroup(
            id: groupId,
            userMessageId: UUID(),
            responses: [
                ResponseGroup.ResponseEntry(id: first.id, modelName: "gpt-a", status: .streaming),
                ResponseGroup.ResponseEntry(id: second.id, modelName: "gpt-b", status: .streaming)
            ]
        )
        let conversation = Conversation(messages: [first, second], responseGroups: [group])
        let expectedResponses = [
            ChatTranscriptMessage(message: first, displayKind: .typingPlaceholder),
            ChatTranscriptMessage(message: second, displayKind: .typingPlaceholder)
        ]

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.visibleMessages == expectedResponses)
        #expect(plan.items == [.responseGroup(ChatTranscriptResponseGroup(
            id: groupId,
            responses: expectedResponses,
            selectedResponseId: nil,
            defaultCandidateId: first.id
        ))])
    }

    @Test("Plan shows active image placeholders and completed image messages")
    func showsActiveImagePlaceholdersAndCompletedImageMessages() {
        let placeholder = Message(role: .assistant, content: "", mediaType: .image)
        let imagePath = Message(role: .assistant, content: "", imagePath: "images/generated.png")
        let imageData = Message(role: .assistant, content: "", imageData: Data([1, 2, 3]))
        let activeConversation = Conversation(messages: [imagePath, imageData, placeholder])
        let idleConversation = Conversation(messages: [placeholder, imagePath, imageData])

        let activePlan = ChatTranscriptPlan(conversation: activeConversation, isGenerating: true)
        let idlePlan = ChatTranscriptPlan(conversation: idleConversation, isGenerating: false)

        #expect(activePlan.visibleMessages == [
            ChatTranscriptMessage(message: imagePath, displayKind: .image),
            ChatTranscriptMessage(message: imageData, displayKind: .image),
            ChatTranscriptMessage(message: placeholder, displayKind: .image)
        ])
        #expect(idlePlan.visibleMessages == [
            ChatTranscriptMessage(message: imagePath, displayKind: .image),
            ChatTranscriptMessage(message: imageData, displayKind: .image)
        ])
    }

    @Test("Plan shows only the last empty assistant while generating")
    func showsOnlyLastEmptyAssistantWhileGenerating() {
        let hidden = Message(role: .assistant, content: "")
        let visible = Message(role: .assistant, content: "")
        let conversation = Conversation(messages: [hidden, visible])

        let generatingPlan = ChatTranscriptPlan(conversation: conversation, isGenerating: true)
        let idlePlan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(generatingPlan.visibleMessages == [ChatTranscriptMessage(message: visible, displayKind: .typingPlaceholder)])
        #expect(idlePlan.visibleMessages.isEmpty)
    }

    @Test("Plan preserves response-group first occurrence order")
    func preservesResponseGroupFirstOccurrenceOrder() {
        let groupId = UUID()
        let user = Message(role: .user, content: "Question")
        let groupedFirst = Message(role: .assistant, content: "A", model: "gpt-a", responseGroupId: groupId)
        let standalone = Message(role: .assistant, content: "Interlude")
        let groupedSecond = Message(role: .assistant, content: "B", model: "gpt-b", responseGroupId: groupId)
        let group = ResponseGroup(
            id: groupId,
            userMessageId: user.id,
            responses: [
                ResponseGroup.ResponseEntry(id: groupedFirst.id, modelName: "gpt-a", status: .completed),
                ResponseGroup.ResponseEntry(id: groupedSecond.id, modelName: "gpt-b", status: .completed)
            ]
        )
        let conversation = Conversation(
            messages: [user, groupedFirst, standalone, groupedSecond],
            responseGroups: [group]
        )

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.items.map(\.id) == [
            user.id.uuidString,
            "group-\(groupId.uuidString)",
            standalone.id.uuidString
        ])
    }

    @Test("Default candidate prefers completed conversation model and falls back to first completed response")
    func defaultCandidatePrefersCompletedConversationModelAndFallsBackToFirstCompletedResponse() {
        let first = Message(role: .assistant, content: "A", model: "gpt-a")
        let second = Message(role: .assistant, content: "B", model: "gpt-b")
        let group = ResponseGroup(
            userMessageId: UUID(),
            responses: [
                ResponseGroup.ResponseEntry(id: first.id, modelName: "gpt-a", status: .completed),
                ResponseGroup.ResponseEntry(id: second.id, modelName: "gpt-b", status: .completed)
            ]
        )
        let matchingConversation = Conversation(messages: [first, second], model: "gpt-b")
        let fallbackConversation = Conversation(messages: [first, second], model: "missing")

        #expect(ChatTranscriptPlan.defaultCandidateId(for: [first, second], in: matchingConversation, responseGroup: group) == second.id)
        #expect(ChatTranscriptPlan.defaultCandidateId(for: [first, second], in: fallbackConversation, responseGroup: group) == first.id)
    }

    @Test("Default candidate skips failed and streaming responses")
    func defaultCandidateSkipsFailedAndStreamingResponses() {
        let failed = Message(role: .assistant, content: "A", model: "gpt-a")
        let streaming = Message(role: .assistant, content: "B", model: "gpt-b")
        let completed = Message(role: .assistant, content: "C", model: "gpt-c")
        let group = ResponseGroup(
            userMessageId: UUID(),
            responses: [
                ResponseGroup.ResponseEntry(id: failed.id, modelName: "gpt-a", status: .failed),
                ResponseGroup.ResponseEntry(id: streaming.id, modelName: "gpt-b", status: .streaming),
                ResponseGroup.ResponseEntry(id: completed.id, modelName: "gpt-c", status: .completed)
            ]
        )
        let conversation = Conversation(messages: [failed, streaming, completed], model: "gpt-a")

        #expect(ChatTranscriptPlan.defaultCandidateId(
            for: [failed, streaming, completed],
            in: conversation,
            responseGroup: group
        ) == completed.id)
    }


    @Test("Default candidate falls back to original ordering when every response is unselectable")
    func defaultCandidateFallsBackToOriginalOrderingWhenEveryResponseIsUnselectable() {
        let failed = Message(role: .assistant, content: "A", model: "gpt-a")
        let streaming = Message(role: .assistant, content: "B", model: "gpt-b")
        let group = ResponseGroup(
            userMessageId: UUID(),
            responses: [
                ResponseGroup.ResponseEntry(id: failed.id, modelName: "gpt-a", status: .failed),
                ResponseGroup.ResponseEntry(id: streaming.id, modelName: "gpt-b", status: .streaming)
            ]
        )
        let conversation = Conversation(messages: [failed, streaming], model: "missing")

        #expect(ChatTranscriptPlan.defaultCandidateId(
            for: [failed, streaming],
            in: conversation,
            responseGroup: group
        ) == failed.id)
    }

    @Test("Response-group item includes selected and default response metadata")
    func responseGroupItemIncludesSelectedAndDefaultResponseMetadata() throws {
        let groupId = UUID()
        let user = Message(role: .user, content: "Compare")
        let first = Message(role: .assistant, content: "A", model: "gpt-a", responseGroupId: groupId)
        let second = Message(role: .assistant, content: "B", model: "gpt-b", responseGroupId: groupId)
        let group = ResponseGroup(
            id: groupId,
            userMessageId: user.id,
            responses: [
                ResponseGroup.ResponseEntry(id: first.id, modelName: "gpt-a", status: .completed),
                ResponseGroup.ResponseEntry(id: second.id, modelName: "gpt-b", status: .completed)
            ],
            selectedResponseId: first.id
        )
        let conversation = Conversation(
            messages: [user, first, second],
            model: "gpt-b",
            responseGroups: [group]
        )

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)
        guard case let .responseGroup(groupItem) = plan.items[1] else {
            Issue.record("Expected second transcript item to be a response group")
            return
        }

        #expect(groupItem.selectedResponseId == first.id)
        #expect(groupItem.defaultCandidateId == second.id)
    }

    @Test("Auto-selection candidate uses last unselected selectable response group")
    func autoSelectionCandidateUsesLastUnselectedSelectableResponseGroup() {
        let groupId = UUID()
        let user = Message(role: .user, content: "Compare")
        let first = Message(role: .assistant, content: "A", model: "gpt-a", responseGroupId: groupId)
        let second = Message(role: .assistant, content: "B", model: "gpt-b", responseGroupId: groupId)
        let group = ResponseGroup(
            id: groupId,
            userMessageId: user.id,
            responses: [
                ResponseGroup.ResponseEntry(id: first.id, modelName: "gpt-a", status: .completed),
                ResponseGroup.ResponseEntry(id: second.id, modelName: "gpt-b", status: .completed)
            ]
        )
        let conversation = Conversation(
            messages: [user, first, second],
            model: "gpt-b",
            responseGroups: [group]
        )

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.pendingAutoSelection == ChatTranscriptResponseSelection(groupId: groupId, messageId: second.id))
        #expect(ChatTranscriptPlan.autoSelectionCandidate(in: conversation) == ChatTranscriptResponseSelection(groupId: groupId, messageId: second.id))
    }

    @Test("Auto-selection returns nil for selected groups but falls back for unselectable groups")
    func autoSelectionReturnsNilForSelectedGroupsButFallsBackForUnselectableGroups() {
        let selectedGroupId = UUID()
        let selectedResponse = Message(role: .assistant, content: "Selected", model: "gpt-a", responseGroupId: selectedGroupId)
        let selectedGroup = ResponseGroup(
            id: selectedGroupId,
            userMessageId: UUID(),
            responses: [ResponseGroup.ResponseEntry(id: selectedResponse.id, modelName: "gpt-a", status: .completed)],
            selectedResponseId: selectedResponse.id
        )
        let selectedConversation = Conversation(messages: [selectedResponse], responseGroups: [selectedGroup])

        let failedGroupId = UUID()
        let failedResponse = Message(role: .assistant, content: "Failed", model: "gpt-a", responseGroupId: failedGroupId)
        let streamingResponse = Message(role: .assistant, content: "", model: "gpt-b", responseGroupId: failedGroupId)
        let unselectableGroup = ResponseGroup(
            id: failedGroupId,
            userMessageId: UUID(),
            responses: [
                ResponseGroup.ResponseEntry(id: failedResponse.id, modelName: "gpt-a", status: .failed),
                ResponseGroup.ResponseEntry(id: streamingResponse.id, modelName: "gpt-b", status: .streaming)
            ]
        )
        let unselectableConversation = Conversation(
            messages: [failedResponse, streamingResponse],
            responseGroups: [unselectableGroup]
        )

        #expect(ChatTranscriptPlan.autoSelectionCandidate(in: selectedConversation) == nil)
        #expect(ChatTranscriptPlan.autoSelectionCandidate(in: unselectableConversation) == ChatTranscriptResponseSelection(
            groupId: failedGroupId,
            messageId: failedResponse.id
        ))
    }
}
