//
//  AnthropicRequestBuilderTests.swift
//  aynaTests
//
//  Created on 1/30/26.
//

@testable import Ayna
import Foundation
import Testing

@Suite("AnthropicRequestBuilder Tests")
@MainActor
struct AnthropicRequestBuilderTests {
    // MARK: - Header Configuration Tests

    @Test("Required headers are set correctly")
    func requiredHeadersAreSet() throws {
        var request = try URLRequest(url: #require(URL(string: "https://api.anthropic.com/v1/messages")))

        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-api-key"
        )

        AnthropicRequestBuilder.configureHeaders(&request, config: config)

        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-api-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.httpMethod == "POST")
    }

    @Test("Beta headers are set correctly")
    func betaHeadersAreSet() throws {
        var request = try URLRequest(url: #require(URL(string: "https://api.anthropic.com/v1/messages")))

        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-api-key",
            betaHeaders: ["interleaved-thinking-2025-05-14", "extended-cache-ttl-2025-04-11"]
        )

        AnthropicRequestBuilder.configureHeaders(&request, config: config)

        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "interleaved-thinking-2025-05-14,extended-cache-ttl-2025-04-11")
    }

    @Test("No beta header when empty")
    func noBetaHeaderWhenEmpty() throws {
        var request = try URLRequest(url: #require(URL(string: "https://api.anthropic.com/v1/messages")))

        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-api-key",
            betaHeaders: []
        )

        AnthropicRequestBuilder.configureHeaders(&request, config: config)

        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    // MARK: - System Prompt Extraction Tests

    @Test("System prompt is extracted to top level")
    func systemPromptExtracted() throws {
        let messages = [
            Message(role: .system, content: "You are a helpful assistant."),
            Message(role: .user, content: "Hello!")
        ]

        let (systemPrompt, anthropicMessages) = try AnthropicRequestBuilder.extractSystemAndConvertMessages(messages)

        #expect(systemPrompt == "You are a helpful assistant.")
        #expect(anthropicMessages.count == 1)

        let firstMsg = anthropicMessages[0]
        #expect(firstMsg["role"] as? String == "user")
        #expect(firstMsg["content"] as? String == "Hello!")
    }

    @Test("Multiple system messages are concatenated")
    func multipleSystemMessagesConcatenated() throws {
        let messages = [
            Message(role: .system, content: "First instruction."),
            Message(role: .system, content: "Second instruction."),
            Message(role: .user, content: "Hello!")
        ]

        let (systemPrompt, anthropicMessages) = try AnthropicRequestBuilder.extractSystemAndConvertMessages(messages)

        #expect(systemPrompt == "First instruction.\n\nSecond instruction.")
        #expect(anthropicMessages.count == 1)
    }

    @Test("No system prompt when none provided")
    func noSystemPromptWhenNoneProvided() throws {
        let messages = [
            Message(role: .user, content: "Hello!")
        ]

        let (systemPrompt, anthropicMessages) = try AnthropicRequestBuilder.extractSystemAndConvertMessages(messages)

        #expect(systemPrompt == nil)
        #expect(anthropicMessages.count == 1)
    }

    // MARK: - Role Mapping Tests

    @Test("User role maps correctly")
    func userRoleMapsCorrectly() throws {
        let messages = [Message(role: .user, content: "Hello!")]

        let (_, anthropicMessages) = try AnthropicRequestBuilder.extractSystemAndConvertMessages(messages)

        #expect(anthropicMessages[0]["role"] as? String == "user")
    }

    @Test("Assistant role maps correctly")
    func assistantRoleMapsCorrectly() throws {
        let messages = [Message(role: .assistant, content: "Hi there!")]

        let (_, anthropicMessages) = try AnthropicRequestBuilder.extractSystemAndConvertMessages(messages)

        #expect(anthropicMessages[0]["role"] as? String == "assistant")
    }

    // MARK: - max_tokens Tests

    @Test("Default max_tokens is 4096")
    func defaultMaxTokensIs4096() throws {
        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-key"
        )

        let messages = [Message(role: .user, content: "Hello!")]
        let body = try AnthropicRequestBuilder.buildMessagesBody(
            messages: messages,
            config: config,
            stream: false,
            tools: nil
        )

        #expect(body["max_tokens"] as? Int == 4096)
    }

    @Test("Custom max_tokens is used")
    func customMaxTokensIsUsed() throws {
        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-key",
            maxTokens: 8192
        )

        let messages = [Message(role: .user, content: "Hello!")]
        let body = try AnthropicRequestBuilder.buildMessagesBody(
            messages: messages,
            config: config,
            stream: false,
            tools: nil
        )

        #expect(body["max_tokens"] as? Int == 8192)
    }

    // MARK: - Extended Thinking Tests

    @Test("Extended thinking enabled when budget_tokens >= 1024")
    func extendedThinkingEnabled() throws {
        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-key",
            budgetTokens: 2048
        )

        let messages = [Message(role: .user, content: "Hello!")]
        let body = try AnthropicRequestBuilder.buildMessagesBody(
            messages: messages,
            config: config,
            stream: false,
            tools: nil
        )

        let thinking = body["thinking"] as? [String: Any]
        #expect(thinking != nil)
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 2048)
    }

    @Test("Extended thinking disabled when budget_tokens < 1024")
    func extendedThinkingDisabledWhenBudgetTooLow() throws {
        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-key",
            budgetTokens: 512
        )

        let messages = [Message(role: .user, content: "Hello!")]
        let body = try AnthropicRequestBuilder.buildMessagesBody(
            messages: messages,
            config: config,
            stream: false,
            tools: nil
        )

        #expect(body["thinking"] == nil)
    }

    @Test("Extended thinking disabled when budget_tokens is nil")
    func extendedThinkingDisabledWhenNil() throws {
        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-key",
            budgetTokens: nil
        )

        let messages = [Message(role: .user, content: "Hello!")]
        let body = try AnthropicRequestBuilder.buildMessagesBody(
            messages: messages,
            config: config,
            stream: false,
            tools: nil
        )

        #expect(body["thinking"] == nil)
    }

    // MARK: - Tool Conversion Tests

    @Test("OpenAI tool format converts to Anthropic format")
    func toolConversionWorks() {
        let openAITools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "web_search",
                    "description": "Search the web",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string"]
                        ],
                        "required": ["query"]
                    ]
                ]
            ]
        ]

        let anthropicTools = AnthropicRequestBuilder.convertToolsToAnthropicFormat(openAITools)

        #expect(anthropicTools.count == 1)

        let tool = anthropicTools[0]
        #expect(tool["name"] as? String == "web_search")
        #expect(tool["description"] as? String == "Search the web")

        let inputSchema = tool["input_schema"] as? [String: Any]
        #expect(inputSchema != nil)
        #expect(inputSchema?["type"] as? String == "object")
    }

    @Test("Tool without description still converts")
    func toolWithoutDescriptionConverts() {
        let openAITools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "simple_tool",
                    "parameters": ["type": "object", "properties": [:]]
                ]
            ]
        ]

        let anthropicTools = AnthropicRequestBuilder.convertToolsToAnthropicFormat(openAITools)

        #expect(anthropicTools.count == 1)
        #expect(anthropicTools[0]["name"] as? String == "simple_tool")
        #expect(anthropicTools[0]["description"] == nil)
    }

    // MARK: - Image Validation Tests

    @Test("JPEG magic bytes detected correctly")
    func jpegDetection() {
        // JPEG magic bytes: FF D8 FF
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])

        let mediaType = AnthropicRequestBuilder.detectImageMediaType(data: jpegData)
        #expect(mediaType == "image/jpeg")
    }

    @Test("PNG magic bytes detected correctly")
    func pngDetection() {
        // PNG magic bytes: 89 50 4E 47
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

        let mediaType = AnthropicRequestBuilder.detectImageMediaType(data: pngData)
        #expect(mediaType == "image/png")
    }

    @Test("GIF magic bytes detected correctly")
    func gifDetection() {
        // GIF magic bytes: 47 49 46 38
        let gifData = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00])

        let mediaType = AnthropicRequestBuilder.detectImageMediaType(data: gifData)
        #expect(mediaType == "image/gif")
    }

    @Test("WebP magic bytes detected correctly")
    func webpDetection() {
        // WebP magic bytes: RIFF....WEBP
        let webpData = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])

        let mediaType = AnthropicRequestBuilder.detectImageMediaType(data: webpData)
        #expect(mediaType == "image/webp")
    }

    @Test("Unknown format returns nil")
    func unknownFormatReturnsNil() {
        let unknownData = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        let mediaType = AnthropicRequestBuilder.detectImageMediaType(data: unknownData)
        #expect(mediaType == nil)
    }

    @Test("Image size limit enforced")
    func imageSizeLimitEnforced() throws {
        // Create data larger than 3.75 MB
        let largeData = Data(repeating: 0xFF, count: 4_000_000)
        // Add JPEG header
        var jpegData = Data([0xFF, 0xD8, 0xFF])
        jpegData.append(largeData)

        #expect(throws: AynaError.self) {
            _ = try AnthropicRequestBuilder.validateAndBuildImageBlock(data: jpegData, fileName: "test.jpg")
        }
    }

    @Test("Valid image builds content block")
    func validImageBuildsContentBlock() throws {
        // Valid small JPEG
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])

        let block = try AnthropicRequestBuilder.validateAndBuildImageBlock(data: jpegData, fileName: "test.jpg")

        #expect(block["type"] as? String == "image")

        let source = block["source"] as? [String: Any]
        #expect(source != nil)
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/jpeg")
        #expect(source?["data"] is String)
    }

    // MARK: - Tool Result Building Tests

    @Test("Tool result builds correctly")
    func toolResultBuildsCorrectly() {
        let result = AnthropicRequestBuilder.buildToolResultContent(
            toolUseId: "toolu_abc123",
            content: "Search results: ..."
        )

        #expect(result["type"] as? String == "tool_result")
        #expect(result["tool_use_id"] as? String == "toolu_abc123")
        #expect(result["content"] as? String == "Search results: ...")
        #expect(result["is_error"] == nil)
    }

    @Test("Tool error result includes is_error flag")
    func toolErrorResultIncludesFlag() {
        let result = AnthropicRequestBuilder.buildToolResultContent(
            toolUseId: "toolu_abc123",
            content: "Error: Tool not found",
            isError: true
        )

        #expect(result["type"] as? String == "tool_result")
        #expect(result["is_error"] as? Bool == true)
    }

    // MARK: - Full Request Building Tests

    @Test("Complete request builds successfully")
    func completeRequestBuilds() throws {
        let url = try #require(URL(string: "https://api.anthropic.com/v1/messages"))
        let config = AnthropicRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "test-key"
        )
        let messages = [
            Message(role: .system, content: "You are helpful."),
            Message(role: .user, content: "Hello!")
        ]

        let request = try AnthropicRequestBuilder.createMessagesRequest(
            url: url,
            messages: messages,
            config: config,
            stream: true,
            tools: nil
        )

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.httpBody != nil)

        // Verify body structure
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "claude-sonnet-4-20250514")
        #expect(body?["stream"] as? Bool == true)
        #expect(body?["system"] as? String == "You are helpful.")

        let msgs = body?["messages"] as? [[String: Any]]
        #expect(msgs?.count == 1)
        #expect(msgs?[0]["role"] as? String == "user")
    }
}
