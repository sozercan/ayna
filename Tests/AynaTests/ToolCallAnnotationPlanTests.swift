@testable import Ayna
import Testing

#if !os(watchOS)
    @Suite("ToolCallAnnotationPlan Tests", .tags(.fast))
    struct ToolCallAnnotationPlanTests {
        @Test("Append policy preserves existing tool calls")
        func appendPolicyPreservesExistingToolCalls() {
            let existing = MCPToolCall(
                id: "existing",
                toolName: "first_tool",
                arguments: [:]
            )

            let plan = ToolCallAnnotationPlan(
                existingToolCalls: [existing],
                toolCallId: "next",
                toolName: "second_tool",
                arguments: ["query": "swift"],
                mergePolicy: .append
            )

            #expect(plan.toolCalls.count == 2)
            #expect(plan.toolCalls.first == existing)
            #expect(plan.toolCalls.last?.id == "next")
            #expect(plan.toolCalls.last?.toolName == "second_tool")
            #expect(plan.toolCalls.last?.arguments["query"]?.value as? String == "swift")
        }

        @Test("Replace policy discards existing tool calls")
        func replacePolicyDiscardsExistingToolCalls() {
            let existing = MCPToolCall(
                id: "existing",
                toolName: "first_tool",
                arguments: [:]
            )

            let plan = ToolCallAnnotationPlan(
                existingToolCalls: [existing],
                toolCallId: "replacement",
                toolName: "next_tool",
                arguments: [:],
                mergePolicy: .replace
            )

            #expect(plan.toolCalls.count == 1)
            #expect(plan.toolCalls.first?.id == "replacement")
            #expect(plan.toolCalls.first?.toolName == "next_tool")
        }
    }
#endif
