@testable import Ayna
import Foundation
import Testing

@Suite("Tool Execution Result Tests")
@MainActor
struct ToolExecutionResultTests {
    @Test("Persisted tool message retains the matching call and output")
    func persistedToolMessageRetainsMatchingCallAndOutput() {
        let result = ToolExecutionResult(
            callID: "call-1",
            toolName: "web_search",
            arguments: ["query": AnyCodable("Swift concurrency")],
            output: "Search result"
        )

        let message = result.makeMessage()

        #expect(message.role == .tool)
        #expect(message.content == "Search result")
        #expect(message.toolCalls?.count == 1)
        #expect(message.toolCalls?.first?.id == "call-1")
        #expect(message.toolCalls?.first?.toolName == "web_search")
        #expect(message.toolCalls?.first?.result == "Search result")
    }

    @Test("Combined citations preserve tool order and receive stable numbering")
    func combinedCitationsPreserveToolOrderAndStableNumbering() {
        let first = ToolExecutionResult(
            callID: "first",
            toolName: "web_search",
            arguments: [:],
            output: "one",
            citations: [CitationReference(number: 9, title: "First", url: "https://first.example")]
        )
        let second = ToolExecutionResult(
            callID: "second",
            toolName: "web_search",
            arguments: [:],
            output: "two",
            citations: [CitationReference(number: 3, title: "Second", url: "https://second.example")]
        )

        let citations = ToolExecutionResult.combinedCitations(from: [first, second])

        #expect(citations.map(\.number) == [1, 2])
        #expect(citations.map(\.title) == ["First", "Second"])
    }
    @Test("Watch message round trip preserves tool metadata")
    func watchMessageRoundTripPreservesToolMetadata() throws {
        let result = ToolExecutionResult(
            callID: "watch-call",
            toolName: "web_search",
            arguments: ["query": AnyCodable("weather")],
            output: "Sunny",
            citations: [CitationReference(number: 1, title: "Forecast", url: "https://weather.example")]
        )
        var original = result.makeMessage()
        original.citations = result.citations

        let data = try JSONEncoder().encode(WatchMessage(from: original))
        let decoded = try JSONDecoder().decode(WatchMessage.self, from: data).toMessage()

        #expect(decoded.toolCalls?.first?.id == "watch-call")
        #expect(decoded.toolCalls?.first?.toolName == "web_search")
        #expect(decoded.toolCalls?.first?.arguments["query"] == AnyCodable("weather"))
        #expect(decoded.toolCalls?.first?.result == "Sunny")
        #expect(decoded.citations?.first?.title == "Forecast")
        #expect(decoded.citations?.first?.url == "https://weather.example")
    }

    @Test("Provider builders serialize preserved tool metadata")
    func providerBuildersSerializePreservedToolMetadata() throws {
        let call = MCPToolCall(
            id: "builder-call",
            toolName: "web_search",
            arguments: ["query": AnyCodable("weather")]
        )
        var assistant = Message(role: .assistant, content: "")
        assistant.toolCalls = [call]
        let result = ToolExecutionResult(
            callID: call.id,
            toolName: call.toolName,
            arguments: call.arguments,
            output: "Sunny"
        ).makeMessage()

        let assistantPayload = OpenAIRequestBuilder.buildMessagePayload(from: assistant)
        let resultPayload = OpenAIRequestBuilder.buildMessagePayload(from: result)
        #expect((assistantPayload["tool_calls"] as? [[String: Any]])?.count == 1)
        #expect(resultPayload["tool_call_id"] as? String == call.id)

        let anthropic = try AnthropicRequestBuilder.extractSystemAndConvertMessages([assistant, result]).messages
        #expect(anthropic.count == 2)
        let assistantContent = anthropic[0]["content"] as? [[String: Any]]
        let resultContent = anthropic[1]["content"] as? [[String: Any]]
        #expect(assistantContent?.contains(where: { $0["type"] as? String == "tool_use" }) == true)
        #expect(resultContent?.contains(where: { $0["type"] as? String == "tool_result" }) == true)
    }

}
