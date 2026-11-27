@testable import Ayna
import Foundation
import Testing

@Suite("AnthropicProvider ErrorPresenter Tests", .tags(.networking, .async), .serialized)
@MainActor
struct AnthropicProviderErrorPresenterTests {
    init() {
        CircuitBreakerRegistry.shared.resetAll()
    }

    private func makeConfig() -> AIProviderRequestConfig {
        AIProviderRequestConfig(
            model: "claude-sonnet-4-20250514",
            apiKey: "sk-ant-test-key-12345",
            customEndpoint: nil,
            temperature: 0.7
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func `stream timeout emits AynaError timeout classified as retryable network error`() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ErrorPresenterMockURLProtocol.self]
        let provider = AnthropicProvider(
            urlSession: URLSession(configuration: sessionConfig),
            retryDelay: { _, _ in
                CircuitBreakerRegistry.shared.resetAll()
            }
        )
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        ErrorPresenterMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let callbackWaiter = TestCallbackWaiter()
        let capturedError = FlightTestBox<Error?>(nil)

        provider.sendMessage(
            messages: messages,
            config: config,
            stream: true,
            tools: nil,
            callbacks: AIProviderStreamCallbacks(
                onChunk: { _ in },
                onComplete: {
                    Issue.record("Expected timeout error")
                    callbackWaiter.signal()
                },
                onError: { error in
                    capturedError.value = error
                    callbackWaiter.signal()
                }
            )
        )

        await callbackWaiter.wait()
        let error = try #require(capturedError.value as? AynaError)
        #expect(error == .timeout)
        #expect(ErrorPresenter.category(for: error) == .network)
        #expect(ErrorPresenter.isRetryable(error))
        #expect(ErrorPresenter.suggestedAction(for: error) == .retry)
    }

    @Test(.timeLimit(.minutes(1)))
    func `stream lost connection emits AynaError networkError classified as retryable network error`() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ErrorPresenterMockURLProtocol.self]
        let provider = AnthropicProvider(
            urlSession: URLSession(configuration: sessionConfig),
            retryDelay: { _, _ in
                CircuitBreakerRegistry.shared.resetAll()
            }
        )
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        ErrorPresenterMockURLProtocol.requestHandler = { _ in
            throw URLError(.networkConnectionLost)
        }

        let callbackWaiter = TestCallbackWaiter()
        let capturedError = FlightTestBox<Error?>(nil)

        provider.sendMessage(
            messages: messages,
            config: config,
            stream: true,
            tools: nil,
            callbacks: AIProviderStreamCallbacks(
                onChunk: { _ in },
                onComplete: {
                    Issue.record("Expected network error")
                    callbackWaiter.signal()
                },
                onError: { error in
                    capturedError.value = error
                    callbackWaiter.signal()
                }
            )
        )

        await callbackWaiter.wait()
        let error = try #require(capturedError.value as? AynaError)
        guard case let .networkError(underlying) = error else {
            Issue.record("Expected networkError, got \(error)")
            return
        }
        #expect((underlying as? URLError)?.code == .networkConnectionLost)
        #expect(ErrorPresenter.category(for: error) == .network)
        #expect(ErrorPresenter.isRetryable(error))
        #expect(ErrorPresenter.suggestedAction(for: error) == .retry)
    }

    @Test(.timeLimit(.minutes(1)))
    func `open circuit breaker emits retryable 503 AynaError`() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ErrorPresenterMockURLProtocol.self]
        let provider = AnthropicProvider(urlSession: URLSession(configuration: sessionConfig))
        let config = makeConfig()
        let url = try #require(URL(string: "https://api.anthropic.com/v1/messages"))
        let circuitKey = NetworkCircuitBreaker.key(for: url, label: "anthropic.messages")
        for _ in 0 ..< 10 {
            NetworkCircuitBreaker.recordFailure(key: circuitKey)
        }
        defer { CircuitBreakerRegistry.shared.resetAll() }

        let callbackWaiter = TestCallbackWaiter()
        let capturedError = FlightTestBox<Error?>(nil)

        provider.sendMessage(
            messages: [Message(role: .user, content: "Hello")],
            config: config,
            stream: true,
            tools: nil,
            callbacks: AIProviderStreamCallbacks(
                onChunk: { _ in },
                onComplete: {
                    Issue.record("Expected circuit breaker error")
                    callbackWaiter.signal()
                },
                onError: { error in
                    capturedError.value = error
                    callbackWaiter.signal()
                }
            )
        )

        await callbackWaiter.wait()
        let error = try #require(capturedError.value as? AynaError)
        guard case let .httpError(statusCode, _) = error else {
            Issue.record("Expected httpError(503), got \(error)")
            return
        }
        #expect(statusCode == 503)
        #expect(ErrorPresenter.isRetryable(error))
        #expect(ErrorPresenter.suggestedAction(for: error) == .retry)
    }
}

private final class ErrorPresenterMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
