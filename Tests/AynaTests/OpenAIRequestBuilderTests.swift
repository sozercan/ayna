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
}
