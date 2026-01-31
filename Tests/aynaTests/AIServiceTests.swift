@testable import Ayna
import Foundation
import Testing

@Suite("AIService Tests", .tags(.networking, .async), .serialized)
@MainActor
struct AIServiceTests {
    private var defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: "AIServiceTests") else {
            fatalError("Failed to create UserDefaults suite for AIServiceTests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "AIServiceTests")
        defaults.synchronize()
        AppPreferences.use(defaults)

        // Use in-memory keychain to avoid touching the real Keychain in tests
        AIService.keychain = InMemoryKeychainStorage()
        GitHubOAuthService.keychain = InMemoryKeychainStorage()
        MockURLProtocol.reset()
    }

    private func makeService() -> AIService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = AIService(urlSession: session)
        service.customModels = ["gpt-4o"]
        service.selectedModel = "gpt-4o"
        return service
    }

    @Test("Send message without API key throws error", .timeLimit(.minutes(1)))
    func sendMessageWithoutAPIKeyThrowsError() async {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = ""

        await confirmation("onError called") { errorReceived in
            service.sendMessage(
                messages: [Message(role: .user, content: "Ping")],
                model: nil,
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { _ in
                    Issue.record("Did not expect chunks when API key is missing")
                },
                onComplete: {
                    Issue.record("Completion should not fire when API key is missing")
                },
                onError: { error in
                    guard case AIService.AIError.missingAPIKey = error else {
                        Issue.record("Unexpected error: \(error)")
                        return
                    }
                    errorReceived()
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            // Give time for async callback
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("Send message adds authorization header and payload", .timeLimit(.minutes(1)))
    func sendMessageAddsAuthorizationHeaderAndPayload() async throws {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = "sk-unit-test"

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"choices":[{"message":{"content":"Hello"}}]}
                """.utf8
            )
            return (response, body)
        }

        let receivedChunk = ResultHolder()

        await confirmation("Request completes") { completed in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hi")],
                model: nil,
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { chunk in
                    receivedChunk.value = chunk
                },
                onComplete: {
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            // Give time for async callback
            try? await Task.sleep(for: .milliseconds(500))
        }

        let request = try #require(MockURLProtocol.lastRequest)

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-unit-test")

        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            stream.close()
            bodyData = data
        }

        let body = try #require(bodyData)
        let json = try #require(try? JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["stream"] as? Bool == false)

        let messages = try #require(json["messages"] as? [[String: Any]])
        let firstMessage = try #require(messages.first)
        let content = try #require(firstMessage["content"] as? String)

        #expect(content == "Hi")
        #expect(receivedChunk.value == "Hello")
    }

    @Test("Send message parses structured content response", .timeLimit(.minutes(1)))
    func sendMessageParsesStructuredContentResponse() async {
        let service = makeService()
        service.modelAPIKeys["gpt-4o"] = "sk-unit-test"

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"choices":[{"message":{"content":[{"type":"text","text":"Structured hello"}]}}]}
                """.utf8
            )
            return (response, body)
        }

        let receivedChunk = ResultHolder()

        await confirmation("Structured response parsed") { completed in
            service.sendMessage(
                messages: [Message(role: .user, content: "Hello")],
                model: nil,
                temperature: nil,
                stream: false,
                tools: nil,
                conversationId: nil,
                onChunk: { chunk in
                    receivedChunk.value += chunk
                },
                onComplete: {
                    #expect(receivedChunk.value == "Structured hello")
                    completed()
                },
                onError: { error in
                    Issue.record("Unexpected error: \(error)")
                },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil
            )

            // Give time for async callback
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test("GitHub Models rate limit tracking is per token")
    func gitHubModelsRateLimitTrackingIsPerToken() throws {
        let oauth = GitHubOAuthService()

        let url = try #require(URL(string: "https://models.github.ai/inference/chat/completions"))
        let now = Date()

        let responseA = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "X-RateLimit-Limit": "100",
                "X-RateLimit-Remaining": "10",
                "X-RateLimit-Reset": "\(Int(now.addingTimeInterval(60).timeIntervalSince1970))",
                "X-RateLimit-Resource": "ai-inference"
            ]
        ))

        let responseB = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "X-RateLimit-Limit": "100",
                "X-RateLimit-Remaining": "3",
                "X-RateLimit-Reset": "\(Int(now.addingTimeInterval(120).timeIntervalSince1970))",
                "X-RateLimit-Resource": "ai-inference"
            ]
        ))

        oauth.updateRateLimit(from: responseA, forAccessToken: "token-A")
        oauth.updateRateLimit(from: responseB, forAccessToken: "token-B")

        #expect(oauth.rateLimitInfo(forAccessToken: "token-A")?.remaining == 10)
        #expect(oauth.rateLimitInfo(forAccessToken: "token-B")?.remaining == 3)
    }

    @Test("GitHub Models retry after is per token")
    func gitHubModelsRetryAfterIsPerToken() throws {
        let oauth = GitHubOAuthService()

        let url = try #require(URL(string: "https://models.github.ai/inference/chat/completions"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: [
                "Retry-After": "60"
            ]
        ))

        oauth.updateRetryAfter(from: response, forAccessToken: "token-A")

        #expect(oauth.retryAfterDate(forAccessToken: "token-A") != nil)
        #expect(oauth.retryAfterDate(forAccessToken: "token-B") == nil)

        oauth.clearRetryAfter(forAccessToken: "token-A")
        #expect(oauth.retryAfterDate(forAccessToken: "token-A") == nil)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0, userInfo: [NSLocalizedDescriptionKey: "Handler not set"]))
            return
        }

        do {
            let (response, data) = try handler(request)
            MockURLProtocol.lastRequest = request
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ResultHolder: @unchecked Sendable {
    var value = ""
}
