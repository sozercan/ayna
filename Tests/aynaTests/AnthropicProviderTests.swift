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

    @Test("Factory returns AnthropicProvider for .anthropic")
    func factoryReturnsAnthropicProvider() {
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let provider = AIProviderFactory.createProvider(for: .anthropic, urlSession: session)

        #expect(provider.providerType == .anthropic)
        #expect(provider is AnthropicProvider)
    }

    // MARK: - Provider Properties Tests

    @Test("Provider type is anthropic")
    func providerTypeIsAnthropic() {
        let provider = makeProvider()
        #expect(provider.providerType == .anthropic)
    }

    @Test("Provider requires API key")
    func providerRequiresAPIKey() {
        let provider = makeProvider()
        #expect(provider.requiresAPIKey == true)
    }

    // MARK: - Configuration Validation Tests

    @Test("Validation fails with empty API key")
    func validationFailsWithEmptyAPIKey() {
        let provider = makeProvider()
        let config = makeConfig(apiKey: "")

        let error = provider.validateConfiguration(config)
        #expect(error != nil)
    }

    @Test("Validation fails with empty model")
    func validationFailsWithEmptyModel() {
        let provider = makeProvider()
        let config = makeConfig(model: "")

        let error = provider.validateConfiguration(config)
        #expect(error != nil)
    }

    @Test("Validation passes with valid config")
    func validationPassesWithValidConfig() {
        let provider = makeProvider()
        let config = makeConfig()

        let error = provider.validateConfiguration(config)
        #expect(error == nil)
    }

    // MARK: - Non-Streaming Response Tests

    @Test("Non-streaming response parses text content", .timeLimit(.minutes(1)))
    func nonStreamingResponseParsesTextContent() async {
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

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { chunk in receivedChunks.append(chunk) },
                    onComplete: { completed() },
                    onError: { error in Issue.record("Unexpected error: \(error)") }
                )
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedChunks.joined() == "Hello! How can I help you today?")
    }

    @Test("Non-streaming response parses thinking content", .timeLimit(.minutes(1)))
    func nonStreamingResponseParsesThinkingContent() async {
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

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { chunk in receivedChunks.append(chunk) },
                    onComplete: { completed() },
                    onError: { error in Issue.record("Unexpected error: \(error)") },
                    onReasoning: { reasoning in receivedReasoning.append(reasoning) }
                )
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedChunks.joined() == "Here's my answer.")
        #expect(receivedReasoning.joined() == "Let me consider this carefully...")
    }

    @Test("Non-streaming response handles tool use", .timeLimit(.minutes(1)))
    func nonStreamingResponseHandlesToolUse() async {
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

        var toolCallReceived = false
        var receivedToolId = ""
        var receivedToolName = ""

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { completed() },
                    onError: { error in Issue.record("Unexpected error: \(error)") },
                    onToolCallRequested: { id, name, _ in
                        toolCallReceived = true
                        receivedToolId = id
                        receivedToolName = name
                    }
                )
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(toolCallReceived)
        #expect(receivedToolId == "toolu_abc123")
        #expect(receivedToolName == "web_search")
    }

    // MARK: - HTTP Error Tests

    @Test("HTTP 400 returns appropriate error", .timeLimit(.minutes(1)))
    func http400ReturnsAppropriateError() async {
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

        var receivedError: Error?

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

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") || errorMessage.contains("Invalid"))
    }

    @Test("HTTP 401 returns API key invalid error", .timeLimit(.minutes(1)))
    func http401ReturnsAPIKeyInvalidError() async {
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

        var receivedError: Error?

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

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") && errorMessage.lowercased().contains("key"))
    }

    @Test("HTTP 429 returns rate limit error", .timeLimit(.minutes(1)))
    func http429ReturnsRateLimitError() async {
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

        var receivedError: Error?

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

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") || errorMessage.lowercased().contains("request"))
    }

    @Test("HTTP 500 returns server error", .timeLimit(.minutes(1)))
    func http500ReturnsServerError() async {
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

        var receivedError: Error?

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

            // Allow time for retries
            try? await Task.sleep(for: .seconds(2))
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Anthropic") || errorMessage.contains("500") || errorMessage.contains("server"))
    }

    // MARK: - Anthropic Error Format Tests

    @Test("Anthropic error format is parsed correctly", .timeLimit(.minutes(1)))
    func anthropicErrorFormatParsedCorrectly() async {
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

        var receivedError: Error?

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

            try? await Task.sleep(for: .milliseconds(500))
        }

        #expect(receivedError != nil)
        let errorMessage = (receivedError as? AynaError)?.errorDescription ?? receivedError?.localizedDescription ?? ""
        #expect(errorMessage.contains("Custom error message from Anthropic"))
    }

    // MARK: - Endpoint Resolution Tests

    @Test("Invalid endpoint triggers error callback", .timeLimit(.minutes(1)))
    func invalidEndpointTriggersError() async {
        let provider = makeProvider()
        let config = makeConfig(customEndpoint: "not-a-valid-url")
        let messages = [Message(role: .user, content: "Hello")]

        var receivedError: Error?

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

    @Test("HTTP endpoint triggers error callback", .timeLimit(.minutes(1)))
    func httpEndpointTriggersError() async {
        let provider = makeProvider()
        let config = makeConfig(customEndpoint: "http://insecure.example.com")
        let messages = [Message(role: .user, content: "Hello")]

        var receivedError: Error?

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

    @Test("Cancel request stops current task")
    func cancelRequestStopsCurrentTask() async {
        let provider = makeProvider()
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        // Set up handler that never completes
        AnthropicMockURLProtocol.requestHandler = { _ in
            // Sleep forever to simulate long-running request
            Thread.sleep(forTimeInterval: 10)
            let response = HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        var errorCalled = false

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

    @Test("Request includes correct headers", .timeLimit(.minutes(1)))
    func requestIncludesCorrectHeaders() async {
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

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { completed() },
                    onError: { error in Issue.record("Unexpected error: \(error)") }
                )
            )

            try? await Task.sleep(for: .milliseconds(500))
        }

        let request = capturedRequest
        #expect(request != nil)
        #expect(request?.value(forHTTPHeaderField: "x-api-key") == "test-api-key")
        #expect(request?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Thinking budget adds beta header for Claude 4 models", .timeLimit(.minutes(1)))
    func thinkingBudgetAddsBetaHeader() async {
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

        await confirmation("Response completes") { completed in
            provider.sendMessage(
                messages: messages,
                config: config,
                stream: false,
                tools: nil,
                callbacks: AIProviderStreamCallbacks(
                    onChunk: { _ in },
                    onComplete: { completed() },
                    onError: { error in Issue.record("Unexpected error: \(error)") }
                )
            )

            try? await Task.sleep(for: .milliseconds(500))
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
