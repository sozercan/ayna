@testable import Ayna
import Foundation
import Testing

#if !os(watchOS)
    @Suite("ToolContinuationPlan Tests", .tags(.fast))
    struct ToolContinuationPlanTests {
        @Test("Web search hides transcript tool message but synthesizes API tool result and citations")
        func webSearchHidesTranscriptToolButSynthesizesAPIResultAndCitations() throws {
            let user = Message(role: .user, content: "Search")
            let assistantWithToolCall = Message(role: .assistant, content: "")
            let citation = CitationReference(number: 1, title: "Result", url: "https://example.com")

            let plan = ToolContinuationPlan(
                existingMessages: [user, assistantWithToolCall],
                toolCallId: "call-1",
                toolName: "web_search",
                arguments: ["query": "swift"],
                result: "Search result",
                model: "gpt-test",
                citations: [citation],
                systemPrompt: "System"
            )

            #expect(plan.visibleToolMessage == nil)
            #expect(plan.continuationAssistantMessage.model == "gpt-test")
            #expect(plan.continuationAssistantMessage.citations == [citation])
            #expect(plan.requestMessages.count == 4)
            #expect(plan.requestMessages[0].role == .system)
            #expect(plan.requestMessages[1] == user)
            #expect(plan.requestMessages[2] == assistantWithToolCall)
            #expect(plan.requestMessages[3].role == .tool)
            #expect(plan.requestMessages[3].content == "Search result")
            #expect(plan.requestMessages[3].toolCalls?.first?.id == "call-1")
        }

        @Test("Non-web tool creates visible tool message and does not synthesize a duplicate")
        func nonWebToolCreatesVisibleToolMessageWithoutSyntheticDuplicate() throws {
            let user = Message(role: .user, content: "Use tool")
            let assistantWithToolCall = Message(role: .assistant, content: "")

            let plan = ToolContinuationPlan(
                existingMessages: [user, assistantWithToolCall],
                toolCallId: "call-2",
                toolName: "custom_tool",
                arguments: ["path": "/tmp/file"],
                result: "Tool result",
                model: "gpt-test",
                citations: nil,
                systemPrompt: nil
            )

            let visibleToolMessage = try #require(plan.visibleToolMessage)
            #expect(visibleToolMessage.role == .tool)
            #expect(visibleToolMessage.content == "Tool result")
            #expect(visibleToolMessage.toolCalls?.first?.toolName == "custom_tool")
            #expect(plan.continuationAssistantMessage.citations == nil)
            #expect(plan.requestMessages == [user, assistantWithToolCall, visibleToolMessage])
        }
    }
#endif
