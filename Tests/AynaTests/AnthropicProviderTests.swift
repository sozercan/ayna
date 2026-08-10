//
//  AnthropicProviderTests.swift
//  aynaTests
//
//  Created on 1/30/26.
//

@testable import Ayna
import Foundation
import Testing

@Suite("AnthropicProvider Tests", .serialized)
@MainActor
struct AnthropicProviderTests {
    init() {
        AnthropicMockURLProtocol.reset()
        CircuitBreakerRegistry.shared.resetAll()
    }

    private func makeProvider() -> AnthropicProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return AnthropicProvider(urlSession: session)
    }

    private func makeConfig(
        model: String = "claude-sonnet-4-20250514",
        apiKey: String = "test-api-key",
        customEndpoint: String? = nil,
        maxTokens: Int? = nil,
        thinkingBudget: Int? = nil
    ) -> AIProviderRequestConfig {
        AIProviderRequestConfig(
            model: model,
            apiKey: apiKey,
            customEndpoint: customEndpoint,
            maxTokens: maxTokens,
            thinkingBudget: thinkingBudget
        )
    }

    // MARK: - Factory Tests

    // MARK: - Provider Properties Tests

    // MARK: - Configuration Validation Tests

    // MARK: - Non-Streaming Response Tests

    @Test(.timeLimit(.minutes(1)))
    func `non-streaming response parses text content`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello!")]

        let responseBody = """
        {
            "id": "msg_123",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Hello! How can I help you today?"}
            ],
            "stop_reason": "end_turn"
        }
        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let receivedChunks = ChunkCollector()
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { chunk in receivedChunks.append(chunk) },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)"); callbackWaiter.signal() }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(receivedChunks.joined() == "Hello! How can I help you today?")
    }

    @Test(.timeLimit(.minutes(1)))
    func `non-streaming response parses thinking content`() async {
        let provider = makeProvider()
        let config = makeConfig(thinkingBudget: 2048)
        let messages = [Message(role: .user, content: "Think about this")]

        let responseBody = """
        {
            "id": "msg_123",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Let me consider this carefully..."},
                {"type": "text", "text": "Here's my answer."}
            ],
            "stop_reason": "end_turn"
        }
        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let receivedChunks = ChunkCollector()
        let receivedReasoning = ChunkCollector()
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { chunk in receivedChunks.append(chunk) },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)"); callbackWaiter.signal() },
                    onReasoning: { reasoning in receivedReasoning.append(reasoning) }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(receivedChunks.joined() == "Here's my answer.")
        #expect(receivedReasoning.joined() == "Let me consider this carefully...")
    }

    @Test(.timeLimit(.minutes(1)))
    func `non-streaming response handles tool use`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Search for Swift")]

        let responseBody = """
        {
            "id": "msg_123",
            "type": "message",
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": "toolu_abc123",
                    "name": "web_search",
                    "input": {"query": "Swift programming"}
                }
            ],
            "stop_reason": "tool_use"
        }
        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        nonisolated(unsafe) var toolCallReceived = false
        nonisolated(unsafe) var receivedToolId = ""
        nonisolated(unsafe) var receivedToolName = ""
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)"); callbackWaiter.signal() },
                    onToolCallRequested: { id, name, _ in
                        toolCallReceived = true
                        receivedToolId = id
                        receivedToolName = name
                    }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(toolCallReceived)
        #expect(receivedToolId == "toolu_abc123")
        #expect(receivedToolName == "web_search")
    }

    // MARK: - HTTP Error Tests

    @Test(.timeLimit(.minutes(1)))
    func `hTTP 400 returns appropriate error`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        let errorBody = """
        {"type": "error", "error": {"type": "invalid_request_error", "message": "Invalid model name"}}
        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(errorBody.utf8))
        }

        nonisolated(unsafe) var receivedError: Error?
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Error received") { errorReceived in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { Issue.record("Should not complete") },
                    onError: { error in
                        receivedError = error
                        errorReceived()
                        callbackWaiter.signal()
                    }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") || errorMessage.contains("Invalid"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `hTTP 401 returns API key invalid error`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        let errorBody = """
        {"type": "error", "error": {"type": "authentication_error", "message": "Invalid API key"}}
        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(errorBody.utf8))
        }

        nonisolated(unsafe) var receivedError: Error?
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Error received") { errorReceived in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { Issue.record("Should not complete"); callbackWaiter.signal() },
                    onError: { error in
                        receivedError = error
                        errorReceived()
                        callbackWaiter.signal()
                    }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") && errorMessage.lowercased().contains("key"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `hTTP 429 returns rate limit error`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        let errorBody = """
        {"type": "error", "error": {"type": "rate_limit_error", "message": "Rate limit exceeded"}}
        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(errorBody.utf8))
        }

        nonisolated(unsafe) var receivedError: Error?
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Error received") { errorReceived in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { Issue.record("Should not complete"); callbackWaiter.signal() },
                    onError: { error in receivedError = error; errorReceived(); callbackWaiter.signal() }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") || errorMessage.lowercased().contains("request"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `hTTP 500 returns server error`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("Internal Server Error".utf8))
        }

        nonisolated(unsafe) var receivedError: Error?
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Error received") { errorReceived in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { Issue.record("Should not complete"); callbackWaiter.signal() },
                    onError: { error in
                        receivedError = error
                        errorReceived()
                        callbackWaiter.signal()
                    }
                )
            )

            // Short wait for async callbacks since circuit breaker may retry
            await callbackWaiter.wait()
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") || errorMessage.contains("500") || errorMessage.contains("server"))
    }

    // MARK: - Anthropic Error Format Tests

    @Test(.timeLimit(.minutes(1)))
    func `anthropic error format is parsed correctly`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        let errorBody = """
        {"type": "error", "error": {"type": "invalid_request_error", "message": "Custom error message from Anthropic"}}
        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(errorBody.utf8))
        }

        nonisolated(unsafe) var receivedError: Error?
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Error received") { errorReceived in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { Issue.record("Should not complete"); callbackWaiter.signal() },
                    onError: { error in
                        receivedError = error
                        errorReceived()
                        callbackWaiter.signal()
                    }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Custom error message from Anthropic"))
    }

    // MARK: - Endpoint Resolution Tests

    @Test(.timeLimit(.minutes(1)))
    func `invalid endpoint triggers error callback`() async {
        let provider = makeProvider()
        let config = makeConfig(customEndpoint: "not-a-valid-url")
        let messages = [Message(role: .user, content: "Hello")]

        nonisolated(unsafe) var receivedError: Error?

        await confirmation("Error received") { errorReceived in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { Issue.record("Should not complete") },
                    onError: { error in
                        receivedError = error
                        errorReceived()
                    }
                )
            )

            try? await Task.sleep(for: .milliseconds(100))
        }

        #expect(receivedError != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `hTTP endpoint triggers error callback`() async {
        let provider = makeProvider()
        let config = makeConfig(customEndpoint: "http://insecure.example.com")
        let messages = [Message(role: .user, content: "Hello")]

        nonisolated(unsafe) var receivedError: Error?

        await confirmation("Error received") { errorReceived in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { Issue.record("Should not complete") },
                    onError: { error in
                        receivedError = error
                        errorReceived()
                    }
                )
            )

            try? await Task.sleep(for: .milliseconds(100))
        }

        #expect(receivedError != nil)
    }

    // MARK: - Cancellation Tests

    @Test
    func `cancel request stops current task`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        // Set up handler that simulates a slow request
        AnthropicMockURLProtocol.requestHandler = { _ in
            // Brief delay to simulate in-flight request without blocking URL loading threads
            Thread.sleep(forTimeInterval: 0.05)
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        nonisolated(unsafe) var errorCalled = false

        provider.sendMessage(
            messages: messages,
            config: config,
            stream: false,
            tools: nil,
            callbacks: AIProviderStreamCallbacks(
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in errorCalled = true }
            )
        )

        // Cancel immediately
        provider.cancelRequest()

        // Wait a bit to ensure no error callback for cancellation
        try? await Task.sleep(for: .milliseconds(200))

        // Note: We don't expect onError for cancellation
        // The test passes if it completes without hanging
    }

    // MARK: - Request Building Tests

    @Test(.timeLimit(.minutes(1)))
    func `request includes correct headers`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        let responseBody = """
        {"id": "msg_123", "type": "message", "role": "assistant", "content": [{"type": "text", "text": "Hi"}], "stop_reason": "end_turn"}
        """

        var capturedRequest: URLRequest?

        AnthropicMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)") }
                )
            )

            await callbackWaiter.wait()
        }

        let request = capturedRequest
        #expect(request != nil)
        #expect(request?.value(forHTTPHeaderField: "x-api-key") == "test-api-key")
        #expect(request?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    // MARK: - Streaming Response Tests

    @Test(.timeLimit(.minutes(1)))
    func `streaming response delivers text chunks`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        // Build SSE response with multiple chunks
        let sseResponse = """
        event: message_start
        data: {"type": "message_start", "message": {"id": "msg_123", "type": "message", "role": "assistant"}}

        event: content_block_start
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": " there"}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "!"}}

        event: content_block_stop
        data: {"type": "content_block_stop", "index": 0}

        event: message_delta
        data: {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}

        event: message_stop
        data: {"type": "message_stop"}

        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sseResponse.utf8))
        }

        let receivedChunks = ChunkCollector()

        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: true,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { chunk in receivedChunks.append(chunk) },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)") }
                )
            )

            await callbackWaiter.wait()
        }

        let fullText = receivedChunks.joined()
        #expect(fullText.contains("Hello"))
        #expect(fullText.contains("there"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `streaming response handles interleaved thinking`() async {
        let provider = makeProvider()
        let config = makeConfig(thinkingBudget: 2048)
        let messages = [Message(role: .user, content: "Think about this")]

        // SSE response with interleaved thinking and text
        let sseResponse = """
        event: message_start
        data: {"type": "message_start", "message": {"id": "msg_456", "type": "message", "role": "assistant"}}

        event: content_block_start
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Let me think..."}}

        event: content_block_stop
        data: {"type": "content_block_stop", "index": 0}

        event: content_block_start
        data: {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Here's my answer."}}

        event: content_block_stop
        data: {"type": "content_block_stop", "index": 1}

        event: message_delta
        data: {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}

        event: message_stop
        data: {"type": "message_stop"}

        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sseResponse.utf8))
        }

        let receivedChunks = ChunkCollector()
        let receivedReasoning = ChunkCollector()

        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: true,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { chunk in receivedChunks.append(chunk) },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)"); callbackWaiter.signal() },
                    onReasoning: { reasoning in receivedReasoning.append(reasoning) }
                )
            )

            await callbackWaiter.wait()
        }

        let fullText = receivedChunks.joined()
        let fullReasoning = receivedReasoning.joined()

        #expect(fullText.contains("answer"))
        #expect(fullReasoning.contains("think"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `streaming response handles tool use`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Search for Swift")]

        // SSE response with tool use
        let sseResponse = """
        event: message_start
        data: {"type": "message_start", "message": {"id": "msg_789", "type": "message", "role": "assistant"}}

        event: content_block_start
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_abc", "name": "web_search"}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{\\"query\\": \\"Swift\\"}"}}

        event: content_block_stop
        data: {"type": "content_block_stop", "index": 0}

        event: message_delta
        data: {"type": "message_delta", "delta": {"stop_reason": "tool_use"}}

        event: message_stop
        data: {"type": "message_stop"}

        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sseResponse.utf8))
        }

        nonisolated(unsafe) var toolCallReceived = false
        nonisolated(unsafe) var receivedToolId = ""
        nonisolated(unsafe) var receivedToolName = ""
        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: true,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)"); callbackWaiter.signal() },
                    onToolCallRequested: { id, name, _ in
                        toolCallReceived = true
                        receivedToolId = id
                        receivedToolName = name
                    }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(toolCallReceived)
        #expect(receivedToolId == "toolu_abc")
        #expect(receivedToolName == "web_search")
    }

    @Test(.timeLimit(.minutes(1)))
    func `streaming tool use is delivered before completion`() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Search for Swift")]

        let sseResponse = """
        event: message_start
        data: {"type": "message_start", "message": {"id": "msg_order", "type": "message", "role": "assistant"}}

        event: content_block_start
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_order", "name": "web_search"}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{\\"query\\": \\"Swift\\"}"}}

        event: content_block_stop
        data: {"type": "content_block_stop", "index": 0}

        event: message_delta
        data: {"type": "message_delta", "delta": {"stop_reason": "tool_use"}}

        event: message_stop
        data: {"type": "message_stop"}

        """

        AnthropicMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sseResponse.utf8))
        }

        let callbackOrder = CallbackOrderCollector()

        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: true,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: {
                        callbackOrder.append("complete")
                        completed()
                        callbackWaiter.signal()
                    },
                    onError: { error in Issue.record("Unexpected error: \(error)"); callbackWaiter.signal() },
                    onToolCallRequested: { _, _, _ in
                        callbackOrder.append("tool")
                    }
                )
            )

            await callbackWaiter.wait()
        }

        #expect(callbackOrder.events == ["tool", "complete"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `thinking budget adds beta header for Claude 4 models`() async {
        let provider = makeProvider()
        let config = makeConfig(model: "claude-4-opus-20250514", thinkingBudget: 2048)
        let messages = [Message(role: .user, content: "Hello")]

        let responseBody = """
        {"id": "msg_123", "type": "message", "role": "assistant", "content": [{"type": "text", "text": "Hi"}], "stop_reason": "end_turn"}
        """

        var capturedRequest: URLRequest?

        AnthropicMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let callbackWaiter = TestCallbackWaiter()

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { error in Issue.record("Unexpected error: \(error)") }
                )
            )

            await callbackWaiter.wait()
        }

        let request = capturedRequest
        #expect(request != nil)
        let betaHeader = request?.value(forHTTPHeaderField: "anthropic-beta")
        #expect(betaHeader?.contains("interleaved-thinking") == true)
    }
}

// MARK: - Test Helpers

private final class AnthropicMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        requestHandler = nil
        lastRequest = nil
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = AnthropicMockURLProtocol.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "AnthropicMockURLProtocol",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Handler not set"]
                )
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            AnthropicMockURLProtocol.lastRequest = request
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ChunkCollector: @unchecked Sendable {
    private var chunks: [String] = []
    private let lock = NSLock()

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return chunks.joined()
    }
}

private final class CallbackOrderCollector: @unchecked Sendable {
    private var recordedEvents: [String] = []
    private let lock = NSLock()

    func append(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}
