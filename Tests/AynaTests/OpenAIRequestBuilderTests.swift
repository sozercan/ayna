@testable import Ayna
import Foundation
import Testing

// swiftformat:disable swiftTestingTestCaseNames

@Suite("OpenAIRequestBuilder Tests")
@MainActor
struct OpenAIRequestBuilderTests {
    @Test
    func `responses body promotes one system prompt to instructions`() throws {
        let messages = [
            Message(role: .system, content: "You are a helpful assistant."),
            Message(role: .user, content: "What is the weather?")
        ]

        let body = OpenAIRequestBuilder.buildResponsesBody(
            model: "gpt-5",
            messages: messages
        )

        #expect(body["instructions"] as? String == "You are a helpful assistant.")

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")

        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "What is the weather?")
    }

    @Test
    func `responses body concatenates system and memory blocks in order`() throws {
        var messages = OpenAIRequestBuilder.buildMessagesWithMemory(
            systemPrompt: "Conversation system prompt",
            memoryContext: MemoryContext(
                sessionMetadata: "Session metadata",
                userMemory: "User memory",
                conversationSummaries: "Conversation summaries"
            ),
            conversationHistory: [
                Message(role: .user, content: "Current user input")
            ]
        )
        messages.insert(Message(role: .system, content: ""), at: 1)

        let body = OpenAIRequestBuilder.buildResponsesBody(
            model: "gpt-5",
            messages: messages
        )

        #expect(
            body["instructions"] as? String ==
                "Conversation system prompt\n\nSession metadata\n\nUser memory\n\nConversation summaries"
        )

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input.allSatisfy { $0["role"] as? String != "system" })
        #expect(input[0]["role"] as? String == "user")

        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content[0]["text"] as? String == "Current user input")
    }

    @Test
    func `responses body omits instructions when system content is empty`() throws {
        let messages = [
            Message(role: .system, content: ""),
            Message(role: .system, content: "  \n  "),
            Message(role: .user, content: "Current user input")
        ]

        let body = OpenAIRequestBuilder.buildResponsesBody(
            model: "gpt-5",
            messages: messages
        )

        #expect(body["instructions"] == nil)

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
    }

    @Test("Responses body omits reasoning and verbosity without a supported configuration")
    func responsesBodyOmitsReasoningAndVerbosityWithoutSupportedConfiguration() {
        let body = OpenAIRequestBuilder.buildResponsesBody(
            model: "gpt-4.1",
            messages: [Message(role: .user, content: "Hello")]
        )

        #expect(body["reasoning"] == nil)
        #expect(body["text"] == nil)
    }

    @Test("Responses body emits only explicitly resolved reasoning controls")
    func responsesBodyEmitsOnlyExplicitlyResolvedReasoningControls() throws {
        let reasoning = ResolvedReasoningConfiguration(
            dialect: .openAIResponses,
            effort: .max,
            openAIMode: .pro,
            openAIContext: .allTurns,
            summary: .automatic,
            anthropicDisplay: .summarized,
            legacyBudgetTokens: 4096
        )

        let body = OpenAIRequestBuilder.buildResponsesBody(
            model: "gpt-5.6-sol",
            messages: [Message(role: .user, content: "Solve this")],
            reasoning: reasoning
        )
        let wire = try #require(body["reasoning"] as? [String: Any])

        #expect(wire["effort"] as? String == "max")
        #expect(wire["summary"] as? String == "auto")
        #expect(wire["context"] as? String == "all_turns")
        #expect(wire["mode"] as? String == "pro")
        #expect(body["text"] == nil)
    }

    @Test("Chat Completions emits effort only for its reasoning dialect")
    func chatCompletionsEmitsEffortOnlyForItsReasoningDialect() {
        let chatReasoning = ResolvedReasoningConfiguration(
            dialect: .openAIChat,
            effort: .high,
            openAIMode: nil,
            openAIContext: .automatic,
            summary: .none,
            anthropicDisplay: .summarized,
            legacyBudgetTokens: 4096
        )
        let responsesReasoning = ResolvedReasoningConfiguration(
            dialect: .openAIResponses,
            effort: .high,
            openAIMode: nil,
            openAIContext: .automatic,
            summary: .automatic,
            anthropicDisplay: .summarized,
            legacyBudgetTokens: 4096
        )

        let emitted = OpenAIRequestBuilder.buildChatCompletionsBody(
            messages: [Message(role: .user, content: "Hello")],
            model: "gpt-5.5",
            stream: false,
            reasoning: chatReasoning
        )
        let omitted = OpenAIRequestBuilder.buildChatCompletionsBody(
            messages: [Message(role: .user, content: "Hello")],
            model: "gpt-5.5",
            stream: false,
            reasoning: responsesReasoning
        )

        #expect(emitted["reasoning_effort"] as? String == "high")
        #expect(omitted["reasoning_effort"] == nil)
    }

    @Test
    func `GPT-5.6 Chat Completions forces none when tools are present`() {
        let reasoning = ResolvedReasoningConfiguration(
            dialect: .openAIChat,
            effort: .high,
            openAIMode: nil,
            openAIContext: .automatic,
            summary: .none,
            anthropicDisplay: .providerDefault,
            legacyBudgetTokens: 4096
        )
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "lookup",
                "parameters": ["type": "object"]
            ]
        ]]

        let body = OpenAIRequestBuilder.buildChatCompletionsBody(
            messages: [Message(role: .user, content: "Hello")],
            model: "gpt-5.6-sol",
            stream: false,
            tools: tools,
            reasoning: reasoning
        )

        #expect(body["reasoning_effort"] as? String == "none")
    }

    @Test
    func `GPT-5.6 Chat Completions forces none for tools at provider default`() {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "lookup",
                "parameters": ["type": "object"]
            ]
        ]]

        let body = OpenAIRequestBuilder.buildChatCompletionsBody(
            messages: [Message(role: .user, content: "Hello")],
            model: "gpt-5.6-sol",
            stream: false,
            tools: tools
        )

        #expect(body["reasoning_effort"] as? String == "none")
    }

    @Test("Earlier reasoning models keep their configured effort with Chat tools")
    func earlierReasoningModelsKeepTheirConfiguredEffortWithChatTools() {
        let reasoning = ResolvedReasoningConfiguration(
            dialect: .openAIChat,
            effort: .high,
            openAIMode: nil,
            openAIContext: .automatic,
            summary: .none,
            anthropicDisplay: .providerDefault,
            legacyBudgetTokens: 4096
        )
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "lookup",
                "parameters": ["type": "object"]
            ]
        ]]

        let body = OpenAIRequestBuilder.buildChatCompletionsBody(
            messages: [Message(role: .user, content: "Hello")],
            model: "gpt-5.5",
            stream: false,
            tools: tools,
            reasoning: reasoning
        )

        #expect(body["reasoning_effort"] as? String == "high")
    }

    @Test
    func `responses request serializes instructions and non-system input`() throws {
        let url = try #require(URL(string: "https://api.openai.com/v1/responses"))
        let request = try #require(OpenAIRequestBuilder.createResponsesRequest(
            url: url,
            messages: [
                Message(role: .system, content: "System prompt"),
                Message(role: .system, content: "Memory block"),
                Message(role: .user, content: "Current user input")
            ],
            model: "gpt-5",
            apiKey: "test-api-key",
            isAzure: false
        ))
        let bodyData = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )

        #expect(body["instructions"] as? String == "System prompt\n\nMemory block")

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
        #expect(input[0]["type"] as? String == "message")

        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "Current user input")
    }

    @Test("Responses input strips orphaned tool calls while preserving assistant text")
    func responsesInputStripsOrphanedToolCallsWhilePreservingAssistantText() throws {
        var assistant = Message(role: .assistant, content: "Partial answer")
        assistant.toolCalls = [
            MCPToolCall(
                id: "orphan",
                toolName: "web_search",
                arguments: ["query": AnyCodable("weather")]
            )
        ]
        var orphanedResult = Message(role: .tool, content: "orphan result")
        orphanedResult.toolCalls = [
            MCPToolCall(id: "other", toolName: "web_search", arguments: [:], result: "orphan result")
        ]

        let input = OpenAIRequestBuilder.buildResponsesInput(from: [assistant, orphanedResult])

        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "assistant")
        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Partial answer")
        #expect(!input.contains(where: { $0["type"] as? String == "function_call" }))
        #expect(!input.contains(where: { $0["type"] as? String == "function_call_output" }))
    }

    @Test("Responses input keeps paired tool calls and outputs")
    func responsesInputKeepsPairedToolCallsAndOutputs() {
        let call = MCPToolCall(
            id: "paired",
            toolName: "web_search",
            arguments: ["query": AnyCodable("weather")]
        )
        var assistant = Message(role: .assistant, content: "")
        assistant.toolCalls = [call]
        var result = Message(role: .tool, content: "Sunny")
        result.toolCalls = [
            MCPToolCall(
                id: call.id,
                toolName: call.toolName,
                arguments: call.arguments,
                result: "Sunny"
            )
        ]

        let input = OpenAIRequestBuilder.buildResponsesInput(from: [assistant, result])

        #expect(input.map { $0["type"] as? String } == ["function_call", "function_call_output"])
        #expect(input[0]["call_id"] as? String == call.id)
        #expect(input[1]["call_id"] as? String == call.id)
    }

    @Test("Responses input replays opaque output items unchanged before tool results")
    func responsesInputReplaysOpaqueOutputItemsUnchangedBeforeToolResults() {
        let reasoningItem: [String: Any] = [
            "type": "reasoning",
            "id": "rs_123",
            "encrypted_content": "opaque-token",
            "summary": [["type": "summary_text", "text": "Checked constraints"]]
        ]
        let callItem: [String: Any] = [
            "type": "function_call",
            "id": "fc_123",
            "call_id": "call_123",
            "name": "web_search",
            "arguments": "{\"query\":\"weather\"}"
        ]
        var assistant = Message(role: .assistant, content: "")
        assistant.model = "gpt-5.6"
        assistant.toolCalls = [
            MCPToolCall(
                id: "call_123",
                toolName: "web_search",
                arguments: ["query": AnyCodable("weather")]
            )
        ]
        assistant.reasoningContinuation = ReasoningContinuationState(
            format: .openAIResponses,
            items: [AnyCodable(reasoningItem), AnyCodable(callItem)],
            model: "gpt-5.6"
        )
        var result = Message(role: .tool, content: "Sunny")
        result.toolCalls = [
            MCPToolCall(
                id: "call_123",
                toolName: "web_search",
                arguments: [:],
                result: "Sunny"
            )
        ]

        let input = OpenAIRequestBuilder.buildResponsesInput(
            from: [assistant, result],
            model: "gpt-5.6"
        )

        #expect(input.map { $0["type"] as? String } == [
            "reasoning", "function_call", "function_call_output"
        ])
        #expect(input[0]["encrypted_content"] as? String == "opaque-token")
        #expect(input[1]["id"] as? String == "fc_123")
        #expect(input[2]["call_id"] as? String == "call_123")
        #expect(input[2]["output"] as? String == "Sunny")
    }

    @Test("Responses input does not replay opaque state across model changes")
    func responsesInputDoesNotReplayOpaqueStateAcrossModelChanges() {
        var assistant = Message(role: .assistant, content: "Final answer", model: "gpt-5.5")
        assistant.reasoningContinuation = ReasoningContinuationState(
            format: .openAIResponses,
            items: [AnyCodable(["type": "reasoning", "id": "rs_old"])],
            model: "gpt-5.5"
        )

        let input = OpenAIRequestBuilder.buildResponsesInput(
            from: [assistant],
            model: "gpt-5.6"
        )

        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "assistant")
    }

    @Test("Responses output preserves every opaque item while delivering summaries and tools")
    func responsesOutputPreservesEveryOpaqueItemWhileDeliveringSummariesAndTools() throws {
        let output: [[String: Any]] = [
            [
                "type": "reasoning",
                "id": "rs_123",
                "encrypted_content": "opaque-token",
                "summary": [["type": "summary_text", "text": "Checked constraints"]]
            ],
            [
                "type": "function_call",
                "id": "fc_123",
                "call_id": "call_123",
                "name": "web_search",
                "arguments": "{\"query\":\"weather\"}"
            ]
        ]
        var deliveredReasoning = ""
        var deliveredContinuation: ReasoningContinuationState?
        var deliveredToolName: String?

        let result = OpenAIRequestBuilder.deliverResponsesOutput(
            output,
            onChunk: { _ in },
            onReasoning: { deliveredReasoning += $0 },
            onReasoningContinuation: { deliveredContinuation = $0 },
            onToolCallRequested: { _, name, _ in deliveredToolName = name }
        )

        #expect(deliveredReasoning == "Checked constraints")
        #expect(deliveredToolName == "web_search")
        #expect(result.hasToolCalls)
        #expect(result.reasoningContinuation == deliveredContinuation)
        let replayed = try #require(deliveredContinuation?.items.first?.value as? [String: Any])
        #expect(replayed["encrypted_content"] as? String == "opaque-token")
    }

    @Test("Responses input requires tool outputs to follow their call in the same round")
    func responsesInputRequiresToolOutputsToFollowTheirCallInTheSameRound() {
        let call = MCPToolCall(id: "reused", toolName: "web_search", arguments: [:])
        var assistant = Message(role: .assistant, content: "Keep this text")
        assistant.toolCalls = [call]
        var result = Message(role: .tool, content: "Result")
        result.toolCalls = [
            MCPToolCall(id: call.id, toolName: call.toolName, arguments: [:], result: "Result")
        ]

        let outputBeforeCall = OpenAIRequestBuilder.buildResponsesInput(from: [result, assistant])
        #expect(outputBeforeCall.map { $0["type"] as? String } == ["message"])

        let separatedByUser = OpenAIRequestBuilder.buildResponsesInput(from: [
            assistant,
            Message(role: .user, content: "New turn"),
            result
        ])
        #expect(separatedByUser.map { $0["type"] as? String } == ["message", "message"])
        #expect(!separatedByUser.contains(where: { $0["type"] as? String == "function_call" }))
        #expect(!separatedByUser.contains(where: { $0["type"] as? String == "function_call_output" }))
    }

    @Test("Serialized requests omit empty assistant placeholders")
    func serializedRequestsOmitEmptyAssistantPlaceholders() throws {
        let messages = [
            Message(role: .user, content: "Question"),
            Message(
                role: .assistant,
                content: "",
                responseGroupId: UUID(),
                isSelectedResponse: false
            ),
        ]
        let chatURL = try #require(URL(string: "https://api.openai.com/v1/chat/completions"))
        let chatRequest = try #require(OpenAIRequestBuilder.createChatCompletionsRequest(
            url: chatURL,
            messages: messages,
            model: "gpt-4o",
            stream: false,
            apiKey: "test-key",
            isAzure: false
        ))
        let chatBodyData = try #require(chatRequest.httpBody)
        let chatBodyObject = try JSONSerialization.jsonObject(with: chatBodyData)
        let chatBody = try #require(chatBodyObject as? [String: Any])
        let chatMessages = try #require(chatBody["messages"] as? [[String: Any]])
        #expect(chatMessages.count == 1)
        #expect(chatMessages[0]["role"] as? String == "user")

        let responsesURL = try #require(URL(string: "https://api.openai.com/v1/responses"))
        let responsesRequest = try #require(OpenAIRequestBuilder.createResponsesRequest(
            url: responsesURL,
            messages: messages,
            model: "gpt-5",
            apiKey: "test-key",
            isAzure: false
        ))
        let responsesBodyData = try #require(responsesRequest.httpBody)
        let responsesBodyObject = try JSONSerialization.jsonObject(with: responsesBodyData)
        let responsesBody = try #require(responsesBodyObject as? [String: Any])
        let input = try #require(responsesBody["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
    }
}
