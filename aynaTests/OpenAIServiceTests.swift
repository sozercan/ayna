@testable import Ayna
import XCTest

final class OpenAIServiceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        guard let suite = UserDefaults(suiteName: "OpenAIServiceTests") else {
            fatalError("Failed to create UserDefaults suite for OpenAIServiceTests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "OpenAIServiceTests")
        defaults.synchronize()
        AppPreferences.use(defaults)

        // Use in-memory keychain to avoid touching the real Keychain in tests
        OpenAIService.keychain = InMemoryKeychainStorage()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        AppPreferences.reset()
        defaults.removePersistentDomain(forName: "OpenAIServiceTests")
        defaults = nil
        OpenAIService.keychain = KeychainStorage.shared
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> OpenAIService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return OpenAIService(urlSession: session)
    }

    func testSendMessageWithoutAPIKeyThrowsError() {
        let service = makeService()
        service.apiKey = ""

        let errorExpectation = expectation(description: "onError called")

        service.sendMessage(
            messages: [Message(role: .user, content: "Ping")],
            model: nil,
            temperature: nil,
            stream: false,
            tools: nil,
            conversationId: nil,
            onChunk: { _ in
                XCTFail("Did not expect chunks when API key is missing")
            },
            onComplete: {
                XCTFail("Completion should not fire when API key is missing")
            },
            onError: { error in
                guard case OpenAIService.OpenAIError.missingAPIKey = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                errorExpectation.fulfill()
            },
            onToolCall: nil,
            onToolCallRequested: nil,
            onReasoning: nil
        )

        wait(for: [errorExpectation], timeout: 1)
    }

    func testSendMessageAddsAuthorizationHeaderAndPayload() {
        let service = makeService()
        service.apiKey = "sk-unit-test"

        let completionExpectation = expectation(description: "Request completes")

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"choices":[{"message":{"content":"Hello"}}]}
                """.utf8)
            return (response, body)
        }

        var receivedChunk = ""

        service.sendMessage(
            messages: [Message(role: .user, content: "Hi")],
            model: nil,
            temperature: nil,
            stream: false,
            tools: nil,
            conversationId: nil,
            onChunk: { chunk in
                receivedChunk = chunk
            },
            onComplete: {
                completionExpectation.fulfill()
            },
            onError: { error in
                XCTFail("Unexpected error: \(error)")
            },
            onToolCall: nil,
            onToolCallRequested: nil,
            onReasoning: nil
        )

        wait(for: [completionExpectation], timeout: 1)

        guard let request = MockURLProtocol.lastRequest else {
            return XCTFail("Expected captured request")
        }

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-unit-test")

        guard
            let body = request.httpBody,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return XCTFail("Failed to decode request body")
        }

        XCTAssertEqual(json["stream"] as? Bool, false)

        guard
            let messages = json["messages"] as? [[String: Any]],
            let firstMessage = messages.first,
            let content = firstMessage["content"] as? String
        else {
            return XCTFail("Missing message payload")
        }

        XCTAssertEqual(content, "Hi")
        XCTAssertEqual(receivedChunk, "Hello")
    }

    func testSendMessageParsesStructuredContentResponse() {
        let service = makeService()
        service.apiKey = "sk-unit-test"

        let completionExpectation = expectation(description: "Structured response parsed")

        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(
                """
                    {"choices":[{"message":{"content":[{"type":"text","text":"Structured hello"}]}}]}
                """.utf8)
            return (response, body)
        }

        var receivedChunk = ""

        service.sendMessage(
            messages: [Message(role: .user, content: "Hello")],
            model: nil,
            temperature: nil,
            stream: false,
            tools: nil,
            conversationId: nil,
            onChunk: { chunk in
                receivedChunk += chunk
            },
            onComplete: {
                XCTAssertEqual(receivedChunk, "Structured hello")
                completionExpectation.fulfill()
            },
            onError: { error in
                XCTFail("Unexpected error: \(error)")
            },
            onToolCall: nil,
            onToolCallRequested: nil,
            onReasoning: nil
        )

        wait(for: [completionExpectation], timeout: 1)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

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
