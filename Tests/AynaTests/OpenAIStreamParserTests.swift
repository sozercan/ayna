@testable import Ayna
import Foundation
import Testing

@Suite("OpenAIStreamParser Tests")
struct OpenAIStreamParserTests {
    @Test("Tool call arguments accumulate across streamed chunks")
    func toolCallArgumentsAccumulateAcrossChunks() async {
        let recorder = ToolCallRecorder()
        var buffers: [Int: [String: Any]] = [:]
        var ids: [Int: String] = [:]

        let firstChunk = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_123","function":{"name":"web_search","arguments":"{\"query\":\"te"}}]}}]}"#
        let secondChunk = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"st\"}"}}]}}]}"#
        let completionChunk = #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#

        var result = await OpenAIStreamParser.processStreamLine(
            firstChunk,
            toolCallBuffers: buffers,
            toolCallIds: ids,
            onToolCall: nil,
            onToolCallRequested: nil
        )
        buffers = result.toolCallBuffers
        ids = result.toolCallIds

        result = await OpenAIStreamParser.processStreamLine(
            secondChunk,
            toolCallBuffers: buffers,
            toolCallIds: ids,
            onToolCall: nil,
            onToolCallRequested: nil
        )
        buffers = result.toolCallBuffers
        ids = result.toolCallIds

        _ = await OpenAIStreamParser.processStreamLine(
            completionChunk,
            toolCallBuffers: buffers,
            toolCallIds: ids,
            onToolCall: { id, name, arguments in
                recorder.record(id: id, name: name, query: arguments["query"] as? String)
                return "ok"
            },
            onToolCallRequested: nil
        )

        let call = recorder.firstCall()
        #expect(call?.id == "call_123")
        #expect(call?.name == "web_search")
        #expect(call?.query == "test")
    }

    @Test("[DONE] marker completes the stream")
    func doneMarkerCompletesStream() async {
        let result = await OpenAIStreamParser.processStreamLine(
            "data: [DONE]",
            toolCallBuffers: [:],
            toolCallIds: [:],
            onToolCall: nil,
            onToolCallRequested: nil
        )

        #expect(result.shouldComplete == true)
    }
}

private final class ToolCallRecorder: @unchecked Sendable {
    struct Call: Sendable {
        let id: String
        let name: String
        let query: String?
    }

    private let lock = NSLock()
    private var firstRecordedCall: Call?

    func record(id: String, name: String, query: String?) {
        lock.lock()
        defer { lock.unlock() }

        if firstRecordedCall == nil {
            firstRecordedCall = Call(id: id, name: name, query: query)
        }
    }

    func firstCall() -> Call? {
        lock.lock()
        defer { lock.unlock() }
        return firstRecordedCall
    }
}
