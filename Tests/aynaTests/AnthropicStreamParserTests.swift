//
//  AnthropicStreamParserTests.swift
//  aynaTests
//
//  Created on 1/30/26.
//

@testable import Ayna
import Foundation
import Testing

@Suite("AnthropicStreamParser Tests")
struct AnthropicStreamParserTests {
    // MARK: - Basic Parsing Tests

    @Test("Empty line returns empty result")
    func emptyLineReturnsEmpty() {
        let parser = AnthropicStreamParser()
        let result = parser.processLine("")
        #expect(result.shouldComplete == false)
        #expect(result.content == nil)
    }

    @Test("Event line stores pending type")
    func eventLineStoresPendingType() {
        let parser = AnthropicStreamParser()
        _ = parser.processLine("event: message_start")
        // Internal state change, no visible result
        let result = parser.processLine("")
        #expect(result.shouldComplete == false)
    }

    @Test("Ping event is ignored")
    func pingEventIgnored() {
        let parser = AnthropicStreamParser()
        _ = parser.processLine("event: ping")
        let result = parser.processLine("data: {}")
        #expect(result.shouldComplete == false)
    }

    // MARK: - Message Start Tests

    @Test("Message start extracts message ID")
    func messageStartExtractsId() {
        let parser = AnthropicStreamParser()
        _ = parser.processLine("event: message_start")
        _ = parser.processLine("""
        data: {"type": "message_start", "message": {"id": "msg_123", "type": "message"}}
        """)
        #expect(parser.messageId == "msg_123")
    }

    // MARK: - Text Content Tests

    @Test("Text delta returns content in result")
    func textDeltaReturnsContent() {
        let parser = AnthropicStreamParser()

        // Start content block
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}
        """)

        // Send delta
        _ = parser.processLine("event: content_block_delta")
        let result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}
        """)

        #expect(result.content == "Hello")
    }

    // MARK: - Thinking Tests

    @Test("Thinking delta returns reasoning in result")
    func thinkingDeltaReturnsReasoning() {
        let parser = AnthropicStreamParser()

        // Start thinking block
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}
        """)

        // Send delta
        _ = parser.processLine("event: content_block_delta")
        let result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Let me think..."}}
        """)

        #expect(result.reasoning == "Let me think...")
    }

    @Test("Redacted thinking block doesn't return reasoning")
    func redactedThinkingNoReasoning() {
        let parser = AnthropicStreamParser()

        // Start redacted thinking block
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "redacted_thinking"}}
        """)

        // Send signature delta (no thinking content)
        _ = parser.processLine("event: content_block_delta")
        let result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "abc123"}}
        """)

        #expect(result.reasoning == nil)
    }

    // MARK: - Tool Use Tests

    @Test("Tool use block returns tool call on stop")
    func toolUseReturnsToolCallOnStop() {
        let parser = AnthropicStreamParser()

        // Start tool_use block
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_123", "name": "web_search", "input": {}}}
        """)

        // Send JSON fragments
        _ = parser.processLine("event: content_block_delta")
        _ = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{\\"query\\""}}
        """)

        _ = parser.processLine("event: content_block_delta")
        _ = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": ": \\"test\\"}"}}
        """)

        // Stop block
        _ = parser.processLine("event: content_block_stop")
        let result = parser.processLine("""
        data: {"type": "content_block_stop", "index": 0}
        """)

        #expect(result.toolCall != nil)
        #expect(result.toolCall?.id == "toolu_123")
        #expect(result.toolCall?.name == "web_search")
        #expect(result.toolCall?.input["query"]?.value as? String == "test")
    }

    @Test("Malformed tool JSON creates error input")
    func malformedToolJsonCreatesError() {
        let parser = AnthropicStreamParser()

        // Start tool_use block
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_456", "name": "bad_tool", "input": {}}}
        """)

        // Send invalid JSON fragment
        _ = parser.processLine("event: content_block_delta")
        _ = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{not valid json"}}
        """)

        // Stop block
        _ = parser.processLine("event: content_block_stop")
        let result = parser.processLine("""
        data: {"type": "content_block_stop", "index": 0}
        """)

        #expect(result.toolCall != nil)
        #expect(result.toolCall?.input["_error"] != nil)
    }

    // MARK: - Multiple Block Tests

    @Test("Interleaved thinking and text blocks track correctly")
    func interleavedThinkingAndText() {
        let parser = AnthropicStreamParser()

        var textContent = ""
        var reasoningContent = ""

        // Start thinking block at index 0
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking"}}
        """)

        // Thinking delta
        _ = parser.processLine("event: content_block_delta")
        var result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "First thought. "}}
        """)
        if let reasoning = result.reasoning {
            reasoningContent += reasoning
        }

        // Start text block at index 1
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 1, "content_block": {"type": "text"}}
        """)

        // Text delta
        _ = parser.processLine("event: content_block_delta")
        result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Hello! "}}
        """)
        if let content = result.content {
            textContent += content
        }

        // More thinking at index 0
        _ = parser.processLine("event: content_block_delta")
        result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Second thought."}}
        """)
        if let reasoning = result.reasoning {
            reasoningContent += reasoning
        }

        // More text at index 1
        _ = parser.processLine("event: content_block_delta")
        result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "World!"}}
        """)
        if let content = result.content {
            textContent += content
        }

        #expect(textContent == "Hello! World!")
        #expect(reasoningContent == "First thought. Second thought.")
    }

    // MARK: - Message Completion Tests

    @Test("Message stop returns shouldComplete")
    func messageStopReturnsShouldComplete() {
        let parser = AnthropicStreamParser()

        _ = parser.processLine("event: message_stop")
        let result = parser.processLine("""
        data: {"type": "message_stop"}
        """)

        #expect(result.shouldComplete == true)
    }

    @Test("Message delta extracts stop reason")
    func messageDeltaExtractsStopReason() {
        let parser = AnthropicStreamParser()

        _ = parser.processLine("event: message_delta")
        _ = parser.processLine("""
        data: {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}
        """)

        #expect(parser.stopReason == "end_turn")
    }

    @Test("Stop reason tool_use is extracted")
    func stopReasonToolUseExtracted() {
        let parser = AnthropicStreamParser()

        _ = parser.processLine("event: message_delta")
        _ = parser.processLine("""
        data: {"type": "message_delta", "delta": {"stop_reason": "tool_use"}}
        """)

        #expect(parser.stopReason == "tool_use")
    }

    // MARK: - Error Handling Tests

    @Test("Error event returns error in result")
    func errorEventReturnsError() {
        let parser = AnthropicStreamParser()

        _ = parser.processLine("event: error")
        let result = parser.processLine("""
        data: {"type": "error", "error": {"type": "invalid_request_error", "message": "Invalid API key"}}
        """)

        #expect(result.error != nil)
    }

    @Test("Empty data line is skipped")
    func emptyDataLineSkipped() {
        let parser = AnthropicStreamParser()
        let result = parser.processLine("data: ")
        #expect(result.shouldComplete == false)
        #expect(result.content == nil)
    }

    // MARK: - Reset Tests

    @Test("Reset clears parser state")
    func resetClearsState() {
        let parser = AnthropicStreamParser()

        // Set some state
        _ = parser.processLine("event: message_start")
        _ = parser.processLine("""
        data: {"type": "message_start", "message": {"id": "msg_123"}}
        """)

        _ = parser.processLine("event: message_delta")
        _ = parser.processLine("""
        data: {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}
        """)

        // Reset
        parser.reset()

        #expect(parser.messageId == nil)
        #expect(parser.stopReason == nil)
    }

    // MARK: - Two-Line Format Tests

    @Test("Event and data correlation works correctly")
    func eventDataCorrelation() {
        let parser = AnthropicStreamParser()

        // Start block
        _ = parser.processLine("event: content_block_start")
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text"}}
        """)

        // Delta with event line first
        _ = parser.processLine("event: content_block_delta")
        let result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Test"}}
        """)

        #expect(result.content == "Test")
    }

    @Test("Data line without event line uses type field")
    func dataLineWithoutEventUsesType() {
        let parser = AnthropicStreamParser()

        // Start block without event line (type is in data)
        _ = parser.processLine("""
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text"}}
        """)

        // Delta without event line
        let result = parser.processLine("""
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Test"}}
        """)

        #expect(result.content == "Test")
    }
}
