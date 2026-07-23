#if os(macOS)

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("Tool Call Handler Tests", .tags(.fast))
    @MainActor
    struct ToolCallHandlerTests {
        @Test
        func `tool call batch drains every queued call exactly once`() throws {
            let state = MacToolCallBatchState()
            state.enqueue(MacQueuedToolCall(id: "call-1", name: "first", arguments: [:]))
            state.enqueue(MacQueuedToolCall(id: "call-2", name: "second", arguments: [:]))
            state.enqueue(MacQueuedToolCall(id: "call-1", name: "duplicate", arguments: [:]))

            let batch = try #require(state.beginProcessing())

            #expect(batch.map(\.id) == ["call-1", "call-2"])
            #expect(state.hasPendingToolCall)
            #expect(state.beginProcessing() == nil)

            state.finishProcessing()
            #expect(!state.hasPendingToolCall)
        }

        @Test
        func `tool call batch exposes in-flight calls for synchronous cancellation`() throws {
            let state = MacToolCallBatchState()
            state.enqueue(MacQueuedToolCall(id: "call-1", name: "first", arguments: [:]))

            let processing = try #require(state.beginProcessing())
            let terminal = state.takeAllToolCalls()

            #expect(processing.map(\.id) == ["call-1"])
            #expect(terminal.map(\.id) == ["call-1"])
            #expect(!state.hasPendingToolCall)
            state.finishProcessing()
            #expect(!state.hasPendingToolCall)
        }

        @Test
        func `reused tool call ids are deduplicated only within their assistant turn`() {
            let reusedCall = MacQueuedToolCall(id: "reused", name: "write_file", arguments: [:])
            var firstAssistant = Message(role: .assistant, content: "")
            firstAssistant.toolCalls = [ToolCallHandler.createToolCall(
                id: reusedCall.id,
                toolName: reusedCall.name,
                arguments: reusedCall.arguments
            )]
            var secondAssistant = Message(role: .assistant, content: "")
            secondAssistant.toolCalls = firstAssistant.toolCalls
            var conversation = Conversation(title: "Reused IDs")
            conversation.messages = [
                firstAssistant,
                ToolCallHandler.createToolMessage(
                    toolCallId: reusedCall.id,
                    toolName: reusedCall.name,
                    arguments: reusedCall.arguments,
                    result: "first result"
                ),
                Message(role: .user, content: "Run it again"),
                secondAssistant,
            ]

            #expect(ToolCallHandler.insertToolResult(
                MacCompletedToolCall(
                    toolCall: reusedCall,
                    result: "second result",
                    citations: nil
                ),
                into: &conversation
            ))

            let matchingResults = conversation.messages.filter { message in
                message.role == .tool && message.toolCalls?.first?.id == reusedCall.id
            }
            #expect(matchingResults.map(\.content) == ["first result", "second result"])
        }

        @Test
        func `batch continuation includes one result for every queued tool call`() {
            let firstCall = MacQueuedToolCall(
                id: "call-1",
                name: "read_file",
                arguments: ["path": "README.md"]
            )
            let secondCall = MacQueuedToolCall(
                id: "call-2",
                name: "web_search",
                arguments: ["query": "Swift concurrency"]
            )
            var assistant = Message(role: .assistant, content: "")
            assistant.toolCalls = [
                ToolCallHandler.createToolCall(
                    id: firstCall.id,
                    toolName: firstCall.name,
                    arguments: firstCall.arguments
                ),
                ToolCallHandler.createToolCall(
                    id: secondCall.id,
                    toolName: secondCall.name,
                    arguments: secondCall.arguments
                ),
            ]
            let completedToolCalls = [
                MacCompletedToolCall(
                    toolCall: firstCall,
                    result: "file contents",
                    citations: nil
                ),
                MacCompletedToolCall(
                    toolCall: secondCall,
                    result: "search results",
                    citations: nil
                ),
            ]
            var conversation = Conversation(title: "Tools")
            conversation.messages = [
                Message(role: .user, content: "Use both tools"),
                assistant,
            ]
            for completedToolCall in completedToolCalls {
                #expect(ToolCallHandler.insertToolResult(completedToolCall, into: &conversation))
            }
            conversation.messages.append(Message(role: .assistant, content: ""))

            let messages = ToolCallHandler.buildContinuationMessages(
                conversationMessages: conversation.messages,
                completedToolCalls: completedToolCalls,
                systemPrompt: "System"
            )

            #expect(messages.first?.role == .system)
            let toolResultIds = messages
                .filter { $0.role == .tool }
                .compactMap { $0.toolCalls?.first?.id }
            #expect(toolResultIds == ["call-1", "call-2"])
            #expect(messages.last?.content == "search results")
        }

        @Test
        func `compatibility continuation preserves a synthetic web search result`() {
            let toolCallId = "search-call"
            var assistant = Message(role: .assistant, content: "")
            assistant.toolCalls = [ToolCallHandler.createToolCall(
                id: toolCallId,
                toolName: "web_search",
                arguments: ["query": "Swift concurrency"]
            )]

            let messages = ToolCallHandler.buildContinuationMessages(
                conversationMessages: [
                    Message(role: .user, content: "Search"),
                    assistant,
                    Message(role: .assistant, content: ""),
                ],
                toolCallId: toolCallId,
                toolName: "web_search",
                arguments: ["query": "Swift concurrency"],
                result: "search results",
                isWebSearch: true,
                systemPrompt: nil
            )

            let resultMessage = messages.last
            #expect(resultMessage?.role == .tool)
            #expect(resultMessage?.content == "search results")
            #expect(resultMessage?.toolCalls?.first?.id == toolCallId)
        }

        @Test
        func `compatibility continuation scopes reused web search ids to the current turn`() {
            let toolCallId = "reused-search-call"
            var oldAssistant = Message(role: .assistant, content: "")
            oldAssistant.toolCalls = [ToolCallHandler.createToolCall(
                id: toolCallId,
                toolName: "web_search",
                arguments: ["query": "old"]
            )]
            var currentAssistant = Message(role: .assistant, content: "")
            currentAssistant.toolCalls = [ToolCallHandler.createToolCall(
                id: toolCallId,
                toolName: "web_search",
                arguments: ["query": "current"]
            )]

            let messages = ToolCallHandler.buildContinuationMessages(
                conversationMessages: [
                    oldAssistant,
                    ToolCallHandler.createToolMessage(
                        toolCallId: toolCallId,
                        toolName: "web_search",
                        arguments: ["query": "old"],
                        result: "old result"
                    ),
                    Message(role: .user, content: "Search again"),
                    currentAssistant,
                    Message(role: .assistant, content: ""),
                ],
                toolCallId: toolCallId,
                toolName: "web_search",
                arguments: ["query": "current"],
                result: "current result",
                isWebSearch: true,
                systemPrompt: nil
            )

            #expect(messages.last?.role == .tool)
            #expect(messages.last?.content == "current result")
        }
    }

#endif
