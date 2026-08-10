@testable import Ayna
import Foundation
import Testing

@Suite("ChatTranscriptPlan Tests", .tags(.fast))
struct ChatTranscriptPlanTests {
    @Test
    func `plan hides system, web-search, and empty tool messages`() {
        let system = Message(role: .system, content: "Hidden")
        let emptyTool = Message(role: .tool, content: "  \n")
        var webSearch = Message(role: .tool, content: "Search result")
        webSearch.toolCalls = [MCPToolCall(toolName: WebSearchCoordinator.toolName, arguments: [:])]
        let tool = Message(role: .tool, content: "Tool result")
        let conversation = Conversation(messages: [system, emptyTool, webSearch, tool])

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.visibleMessages.map(\.id) == [tool.id])
        #expect(plan.items == [.message(ChatTranscriptMessage(message: tool, displayKind: .toolResult))])
    }

    @Test
    func `plan hides empty assistant tool-call placeholders`() {
        #if !os(watchOS)
            var placeholder = Message(role: .assistant, content: "")
            placeholder.toolCalls = [MCPToolCall(toolName: "web_search", arguments: [:])]
            let visible = Message(role: .assistant, content: "Done")
            let conversation = Conversation(messages: [placeholder, visible])

            let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: true)

            #expect(plan.visibleMessages.map(\.id) == [visible.id])
        #endif
    }

    @Test
    func `plan shows reasoning-only assistant messages`() {
        let message = Message(role: .assistant, content: "", reasoning: "Thinking through this")
        let conversation = Conversation(messages: [message])

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        let expected = ChatTranscriptMessage(message: message, displayKind: .text)
        #expect(plan.visibleMessages == [expected])
        #expect(plan.items == [.message(expected)])
    }

    @Test
    func `plan shows citations-only assistant messages`() {
        let message = Message(
            role: .assistant,
            content: "",
            citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
        )
        let conversation = Conversation(messages: [message])

        let idlePlan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)
        let generatingPlan = ChatTranscriptPlan(conversation: conversation, isGenerating: true)

        #expect(idlePlan.visibleMessages == [ChatTranscriptMessage(message: message, displayKind: .citationsOnly)])
        #expect(generatingPlan.visibleMessages == [ChatTranscriptMessage(message: message, displayKind: .typingPlaceholder)])
    }

    @Test
    func `plan keeps empty response-group placeholders visible and grouped`() {
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

        #expect(plan.items == [.responseGroup(ChatTranscriptResponseGroup(
            id: groupId,
            responses: expectedResponses,
            selectedResponseId: nil,
            defaultCandidateId: first.id
        ))])
    }

    @Test
    func `plan shows active image placeholders and completed images`() {
        let placeholder = Message(role: .assistant, content: "", mediaType: .image)
        let imagePath = Message(role: .assistant, content: "", imagePath: "images/generated.png")
        let imageData = Message(role: .assistant, content: "", imageData: Data([1, 2, 3]))
        let activeConversation = Conversation(messages: [imagePath, imageData, placeholder])
        let idleConversation = Conversation(messages: [placeholder, imagePath, imageData])

        let activePlan = ChatTranscriptPlan(conversation: activeConversation, isGenerating: true)
        let idlePlan = ChatTranscriptPlan(conversation: idleConversation, isGenerating: false)

        #expect(activePlan.visibleMessages.map(\.displayKind) == [.image, .image, .image])
        #expect(idlePlan.visibleMessages.map(\.id) == [imagePath.id, imageData.id])
    }

    @Test
    func `plan keeps non-empty standalone image messages visible`() {
        let failedAssistant = Message(role: .assistant, content: "Image generation failed", mediaType: .image)
        let userImage = Message(role: .user, content: "Uploaded image context", mediaType: .image)
        let oldPlaceholder = Message(role: .assistant, content: "", mediaType: .image)
        let conversation = Conversation(messages: [failedAssistant, userImage, oldPlaceholder])

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.visibleMessages == [
            ChatTranscriptMessage(message: failedAssistant, displayKind: .text),
            ChatTranscriptMessage(message: userImage, displayKind: .text)
        ])
    }

    @Test
    func `plan shows only the last empty assistant while generating`() {
        let hidden = Message(role: .assistant, content: "")
        let visible = Message(role: .assistant, content: "")
        let conversation = Conversation(messages: [hidden, visible])

        #expect(ChatTranscriptPlan(conversation: conversation, isGenerating: true).visibleMessages == [
            ChatTranscriptMessage(message: visible, displayKind: .typingPlaceholder)
        ])
        #expect(ChatTranscriptPlan(conversation: conversation, isGenerating: false).visibleMessages.isEmpty)
    }

    @Test
    func `plan preserves response-group first occurrence order`() {
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
        let conversation = Conversation(messages: [user, groupedFirst, standalone, groupedSecond], responseGroups: [group])

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(plan.items.map(\.id) == [
            user.id.uuidString,
            "group-\(groupId.uuidString)",
            standalone.id.uuidString
        ])
    }

    @Test
    func `default candidate prefers completed conversation model`() {
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

    @Test
    func `default candidate prefers meaningful content over an empty preferred-model response`() {
        let groupId = UUID()
        let user = Message(role: .user, content: "Compare")
        let emptyPreferred = Message(
            role: .assistant,
            content: "",
            model: "gpt-a",
            responseGroupId: groupId
        )
        let meaningful = Message(
            role: .assistant,
            content: "Useful answer",
            model: "gpt-b",
            responseGroupId: groupId
        )
        let group = ResponseGroup(
            id: groupId,
            userMessageId: user.id,
            responses: [
                ResponseGroup.ResponseEntry(id: emptyPreferred.id, modelName: "gpt-a", status: .completed),
                ResponseGroup.ResponseEntry(id: meaningful.id, modelName: "gpt-b", status: .completed)
            ]
        )
        let conversation = Conversation(
            messages: [user, emptyPreferred, meaningful],
            model: "gpt-a",
            responseGroups: [group]
        )

        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        #expect(ChatTranscriptPlan.defaultCandidateId(
            for: [emptyPreferred, meaningful],
            in: conversation,
            responseGroup: group
        ) == meaningful.id)
        #expect(plan.pendingAutoSelection?.messageId == meaningful.id)
        #expect(conversation.getEffectiveHistory().map(\.id) == [user.id, meaningful.id])
    }

    @Test
    func `default candidate falls back to original ordering when every response is unavailable`() {
        let failed = Message(role: .assistant, content: "A", model: "gpt-a")
        let streaming = Message(role: .assistant, content: "B", model: "gpt-b")
        let group = ResponseGroup(
            userMessageId: UUID(),
            responses: [
                ResponseGroup.ResponseEntry(id: failed.id, modelName: "gpt-a", status: .failed),
                ResponseGroup.ResponseEntry(id: streaming.id, modelName: "gpt-b", status: .streaming)
            ]
        )

        #expect(ChatTranscriptPlan.defaultCandidateId(
            for: [failed, streaming],
            in: Conversation(messages: [failed, streaming], model: "missing"),
            responseGroup: group
        ) == failed.id)
    }

    @Test
    func `response-group item includes selected and default metadata`() {
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
        let conversation = Conversation(messages: [user, first, second], model: "gpt-b", responseGroups: [group])
        let plan = ChatTranscriptPlan(conversation: conversation, isGenerating: false)

        guard case let .responseGroup(groupItem) = plan.items[1] else {
            Issue.record("Expected response group")
            return
        }
        #expect(groupItem.selectedResponseId == first.id)
        #expect(groupItem.defaultCandidateId == second.id)
    }

    @Test
    func `auto-selection uses the last unselected response group`() {
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
        let conversation = Conversation(messages: [user, first, second], model: "gpt-b", responseGroups: [group])

        #expect(ChatTranscriptPlan.autoSelectionCandidate(in: conversation) == ChatTranscriptResponseSelection(
            groupId: groupId,
            messageId: second.id
        ))
    }
}
