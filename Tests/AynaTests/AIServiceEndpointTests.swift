@testable import Ayna
import Foundation
import Testing

extension AIServiceGlobalStateTests {
    @Suite("AIService Endpoint Tests", .tags(.networking, .async), .serialized)
    @MainActor
    struct AIServiceEndpointTests {
        init() {
            guard let defaults = UserDefaults(suiteName: "AIServiceEndpointTests") else {
                fatalError("Failed to create UserDefaults suite")
            }
            defaults.removePersistentDomain(forName: "AIServiceEndpointTests")
            AppPreferences.use(defaults)
            AIService.keychain = InMemoryKeychainStorage()
            EndpointMockURLProtocol.reset()
        }

        private func makeService() -> AIService {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [EndpointMockURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: configuration))
            service.customModels = ["gpt-4o"]
            service.selectedModel = "gpt-4o"
            service.modelProviders["gpt-4o"] = .openai
            return service
        }

        @Test(.timeLimit(.minutes(1)))
        func `custom OpenAI-compatible endpoint can send without API key`() async throws {
            let service = makeService()
            service.modelAPIKeys["gpt-4o"] = ""
            service.modelEndpoints["gpt-4o"] = "https://proxy.example.com"
            EndpointMockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"choices":[{"message":{"content":"Hello from proxy"}}]}"#.utf8))
            }
            let receivedChunk = LockedEndpointString()
            let callbackWaiter = TestCallbackWaiter()

            #expect(service.isModelConfigured("gpt-4o"))
            await confirmation("Custom endpoint request completes") { completed in
                service.sendMessage(
                    messages: [Message(role: .user, content: "Hi")],
                    model: "gpt-4o",
                    stream: false,
                    onChunk: { receivedChunk.append($0) },
                    onComplete: { completed(); callbackWaiter.signal() },
                    onError: { Issue.record("Unexpected error: \($0)"); callbackWaiter.signal() }
                )
                await callbackWaiter.wait()
            }

            let request = try #require(EndpointMockURLProtocol.lastRequest)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.absoluteString == "https://proxy.example.com/v1/chat/completions")
            #expect(receivedChunk.value == "Hello from proxy")
        }

        @Test(.timeLimit(.minutes(1)))
        func `custom OpenAI-compatible image endpoint can send without API key`() async throws {
            let service = makeService()
            service.customModels = ["image-model"]
            service.selectedModel = "image-model"
            service.modelProviders["image-model"] = .openai
            service.modelAPIKeys["image-model"] = ""
            service.modelEndpoints["image-model"] = "https://proxy.example.com"
            service.modelEndpointTypes["image-model"] = .imageGeneration
            EndpointMockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#.utf8))
            }
            let receivedData = LockedEndpointData()
            let callbackWaiter = TestCallbackWaiter()

            #expect(service.isModelConfigured("image-model"))
            await confirmation("Custom image endpoint request completes") { completed in
                service.generateImage(
                    prompt: "a glass sphere",
                    model: "image-model",
                    onComplete: { receivedData.value = $0; completed(); callbackWaiter.signal() },
                    onError: { Issue.record("Unexpected error: \($0)"); callbackWaiter.signal() }
                )
                await callbackWaiter.wait()
            }

            let request = try #require(EndpointMockURLProtocol.lastRequest)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.absoluteString == "https://proxy.example.com/v1/images/generations")
            #expect(receivedData.value == Data("image".utf8))
        }
    }
}

private final class EndpointMockURLProtocol: URLProtocol, @unchecked Sendable {
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
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            Self.lastRequest = request
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

private final class LockedEndpointString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    var value: String {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage += value }
    }
}

private final class LockedEndpointData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
