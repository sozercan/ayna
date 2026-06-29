@testable import Ayna
import Foundation
import Testing

@Suite("ChatTurnRequestPlan Tests", .tags(.fast))
struct ChatTurnRequestPlanTests {
    @Test("Plan prepends non-empty system prompt")
    func prependsNonEmptySystemPrompt() throws {
        let user = Message(role: .user, content: "Hello")

        let plan = ChatTurnRequestPlan(history: [user], systemPrompt: "Be concise")

        #expect(plan.messages.count == 2)
        #expect(plan.messages[0].role == .system)
        #expect(plan.messages[0].content == "Be concise")
        #expect(plan.messages[1] == user)
    }

    @Test("Plan ignores empty system prompt")
    func ignoresEmptySystemPrompt() {
        let user = Message(role: .user, content: "Hello")

        let plan = ChatTurnRequestPlan(history: [user], systemPrompt: "")

        #expect(plan.messages == [user])
    }

    @Test("Plan excludes trailing assistant placeholder")
    func excludesTrailingAssistantPlaceholder() {
        let user = Message(role: .user, content: "Hello")
        let placeholder = Message(role: .assistant, content: "")
        let conversation = Conversation(messages: [user, placeholder])

        let plan = ChatTurnRequestPlan(
            conversation: conversation,
            systemPrompt: nil,
            excludingTrailingPlaceholder: true
        )

        #expect(plan.messages == [user])
    }

    @Test("Effective messages can exclude an in-flight response group")
    func effectiveMessagesCanExcludeInFlightResponseGroup() {
        let groupId = UUID()
        let user = Message(role: .user, content: "Compare")
        let grouped = Message(role: .assistant, content: "A", model: "gpt-a", responseGroupId: groupId)
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

    #if !os(watchOS)
        @Test("Tool continuation drops UI placeholder and appends synthetic tool result for web search")
        func toolContinuationDropsPlaceholderAndAppendsSyntheticToolResult() throws {
            let user = Message(role: .user, content: "Search")
            let assistantToolCall = Message(role: .assistant, content: "")
            let continuationPlaceholder = Message(role: .assistant, content: "")
            let toolResult = ChatTurnRequestPlan.ToolResult(
                toolCallId: "call-1",
                toolName: "web_search",
                arguments: ["query": AnyCodable("swift")],
                result: "Search result",
                shouldSynthesizeToolMessage: true
            )

            let messages = ChatTurnRequestPlan.toolContinuationMessages(
                conversationMessages: [user, assistantToolCall, continuationPlaceholder],
                toolResult: toolResult,
                systemPrompt: "System"
            )

            #expect(messages.count == 4)
            #expect(messages[0].role == .system)
            #expect(messages[1] == user)
            #expect(messages[2] == assistantToolCall)
            #expect(messages[3].role == .tool)
            #expect(messages[3].content == "Search result")
            #expect(messages[3].toolCalls?.first?.id == "call-1")
            #expect(messages[3].toolCalls?.first?.toolName == "web_search")
        }

        @Test("Tool continuation keeps stored tool messages for non-synthetic tools")
        func toolContinuationKeepsStoredToolMessagesForNonSyntheticTools() {
            let user = Message(role: .user, content: "Use tool")
            let storedTool = Message(role: .tool, content: "Tool result")
            let continuationPlaceholder = Message(role: .assistant, content: "")
            let toolResult = ChatTurnRequestPlan.ToolResult(
                toolCallId: "call-2",
                toolName: "custom_tool",
                arguments: [:],
                result: "Tool result",
                shouldSynthesizeToolMessage: false
            )

            let messages = ChatTurnRequestPlan.toolContinuationMessages(
                conversationMessages: [user, storedTool, continuationPlaceholder],
                toolResult: toolResult,
                systemPrompt: nil
            )

            #expect(messages == [user, storedTool])
        }
    #endif
}
