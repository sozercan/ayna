@testable import Ayna
import Foundation
import Testing

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

    @Test("Responses input requires tool outputs to follow their call in the same round")
    func responsesInputRequiresOutputsInSameRound() {
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
