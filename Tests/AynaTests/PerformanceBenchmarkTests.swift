@testable import Ayna
import Foundation
import Testing

@Suite("Parser Performance Benchmarks", .serialized)
struct ParserPerformanceBenchmarkTests {
    private static let lineCount = 10000

    @Test("OpenAI parser processes 10k content SSE string lines", .timeLimit(.minutes(1)))
    func openAIParserProcesses10kContentSSEStringLines() async {
        let line = #"data: {"choices":[{"delta":{"content":"x"}}]}"#
        var buffers: [Int: [String: Any]] = [:]
        var ids: [Int: String] = [:]
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = await OpenAIStreamParser.processStreamLine(
                line,
                toolCallBuffers: buffers,
                toolCallIds: ids,
                onToolCall: nil,
                onToolCallRequested: nil
            )
            buffers = result.toolCallBuffers
            ids = result.toolCallIds
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.openai.string.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }

    @Test("OpenAI parser processes 10k content SSE data lines", .timeLimit(.minutes(1)))
    func openAIParserProcesses10kContentSSEDataLines() async {
        let line = Data(#"data: {"choices":[{"delta":{"content":"x"}}]}"#.utf8)
        var buffers: [Int: [String: Any]] = [:]
        var ids: [Int: String] = [:]
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = await OpenAIStreamParser.processStreamLine(
                line,
                toolCallBuffers: buffers,
                toolCallIds: ids,
                onToolCall: nil,
                onToolCallRequested: nil
            )
            buffers = result.toolCallBuffers
            ids = result.toolCallIds
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.openai.data.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }

    @Test("Anthropic parser processes 10k content SSE string lines", .timeLimit(.minutes(1)))
    func anthropicParserProcesses10kContentSSEStringLines() {
        let parser = AnthropicStreamParser()
        _ = parser.processLine(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = parser.processLine(line)
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.anthropic.string.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }

    @Test("Anthropic parser processes 10k content SSE data lines", .timeLimit(.minutes(1)))
    func anthropicParserProcesses10kContentSSEDataLines() {
        let parser = AnthropicStreamParser()
        _ = parser.processLine(Data(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.utf8))
        let line = Data(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#.utf8)
        var contentLength = 0

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< Self.lineCount {
            let result = parser.processLine(line)
            contentLength += result.content?.count ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH parser.anthropic.data.10k seconds=\(elapsed)")
        #expect(contentLength == Self.lineCount)
    }
}
