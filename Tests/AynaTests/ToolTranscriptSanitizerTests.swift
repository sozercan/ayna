@testable import Ayna
import Foundation
import Testing

@Suite("Tool Transcript Sanitizer Tests")
@MainActor
struct ToolTranscriptSanitizerTests {
    @Test("Keeps only contiguous outputs that follow their assistant call")
    func keepsOnlyContiguousFollowingOutputs() {
        let call = MCPToolCall(id: "call", toolName: "lookup", arguments: [:])
        var assistant = Message(role: .assistant, content: "partial")
        assistant.toolCalls = [call]
        var result = Message(role: .tool, content: "result")
        result.toolCalls = [MCPToolCall(id: call.id, toolName: call.toolName, arguments: [:], result: "result")]

        let outputBefore = ToolTranscriptSanitizer.sanitize([result, assistant])
        #expect(outputBefore.count == 1)
        #expect(outputBefore[0].content == "partial")
        #expect(outputBefore[0].toolCalls == nil)

        let separated = ToolTranscriptSanitizer.sanitize([
            assistant,
            Message(role: .user, content: "new turn"),
            result
        ])
        #expect(separated.map(\.role) == [.assistant, .user])
        #expect(separated[0].toolCalls == nil)
    }

    @Test("Preserves parallel calls and results in call order")
    func preservesParallelCallsAndResultsInCallOrder() {
        let first = MCPToolCall(id: "first", toolName: "one", arguments: [:])
        let second = MCPToolCall(id: "second", toolName: "two", arguments: [:])
        var assistant = Message(role: .assistant, content: "")
        assistant.toolCalls = [first, second]
        var secondResult = Message(role: .tool, content: "two-result")
        secondResult.toolCalls = [MCPToolCall(id: second.id, toolName: second.toolName, arguments: [:], result: "two-result")]
        var firstResult = Message(role: .tool, content: "one-result")
        firstResult.toolCalls = [MCPToolCall(id: first.id, toolName: first.toolName, arguments: [:], result: "one-result")]

        let sanitized = ToolTranscriptSanitizer.sanitize([assistant, secondResult, firstResult])

        #expect(sanitized[0].toolCalls?.map(\.id) == ["first", "second"])
        #expect(sanitized.dropFirst().map(\.content) == ["one-result", "two-result"])
    }

    @Test("Drops orphan tool-only assistants")
    func dropsOrphanToolOnlyAssistants() {
        var assistant = Message(role: .assistant, content: "")
        assistant.toolCalls = [MCPToolCall(id: "orphan", toolName: "lookup", arguments: [:])]

        #expect(ToolTranscriptSanitizer.sanitize([assistant]).isEmpty)
    }

    @Test("Preserves non-tool assistant content when orphan calls are stripped")
    func preservesMeaningfulAssistantContent() throws {
        let orphanCall = MCPToolCall(id: "orphan", toolName: "lookup", arguments: [:])

        var textMessage = Message(role: .assistant, content: "Partial answer")
        textMessage.toolCalls = [orphanCall]

        var reasoningMessage = Message(role: .assistant, content: "", reasoning: "Useful reasoning")
        reasoningMessage.toolCalls = [orphanCall]

        var citationMessage = Message(
            role: .assistant,
            content: "",
            citations: [CitationReference(number: 1, title: "Source", url: "https://example.com")]
        )
        citationMessage.toolCalls = [orphanCall]

        var mediaMessage = Message(
            role: .assistant,
            content: "",
            mediaType: .image,
            imageData: Data([0x01])
        )
        mediaMessage.toolCalls = [orphanCall]

        for message in [textMessage, reasoningMessage, citationMessage, mediaMessage] {
            let sanitized = ToolTranscriptSanitizer.sanitize([message])
            #expect(sanitized.count == 1)
            let preserved = try #require(sanitized.first)
            #expect(preserved.id == message.id)
            #expect(preserved.toolCalls == nil)
        }
    }

    @Test("Provider builders omit cross-round tool pairs")
    func providerBuildersOmitCrossRoundToolPairs() throws {
        let call = MCPToolCall(id: "cross-round", toolName: "lookup", arguments: [:])
        var assistant = Message(role: .assistant, content: "partial")
        assistant.toolCalls = [call]
        var result = Message(role: .tool, content: "late result")
        result.toolCalls = [
            MCPToolCall(id: call.id, toolName: call.toolName, arguments: [:], result: "late result")
        ]
        let history = [assistant, Message(role: .user, content: "new turn"), result]

        let chatBody = OpenAIRequestBuilder.buildChatCompletionsBody(
            messages: history,
            model: "gpt-4o",
            stream: false
        )
        let chatMessages = try #require(chatBody["messages"] as? [[String: Any]])
        #expect(chatMessages.count == 2)
        #expect(chatMessages[0]["tool_calls"] == nil)

        let anthropic = try AnthropicRequestBuilder.extractSystemAndConvertMessages(history).messages
        #expect(anthropic.count == 2)
        #expect(anthropic[0]["role"] as? String == "assistant")
        #expect(anthropic[0]["content"] as? String == "partial")
    }
}
