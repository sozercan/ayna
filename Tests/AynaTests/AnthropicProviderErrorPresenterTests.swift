@testable import Ayna
import Foundation
import Testing

@Suite("AnthropicProvider ErrorPresenter Tests", .tags(.networking, .async), .serialized)
@MainActor
struct AnthropicProviderErrorPresenterTests {
    init() {
        AnthropicMockURLProtocol.reset()
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
        sessionConfig.protocolClasses = [AnthropicMockURLProtocol.self]
        let provider = AnthropicProvider(
            urlSession: URLSession(configuration: sessionConfig),
            retryDelay: { _, _ in
                CircuitBreakerRegistry.shared.resetAll()
            }
        )
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        AnthropicMockURLProtocol.requestHandler = { _ in
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
        sessionConfig.protocolClasses = [AnthropicMockURLProtocol.self]
        let provider = AnthropicProvider(
            urlSession: URLSession(configuration: sessionConfig),
            retryDelay: { _, _ in
                CircuitBreakerRegistry.shared.resetAll()
            }
        )
        let config = makeConfig()
        let messages = [Message(role: .user, content: "Hello")]

        AnthropicMockURLProtocol.requestHandler = { _ in
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
}
