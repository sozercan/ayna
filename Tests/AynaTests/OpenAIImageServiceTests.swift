@testable import Ayna
import Foundation
import Testing

@Suite("OpenAIImageService Tests", .tags(.networking, .async), .serialized)
struct OpenAIImageServiceTests {
    @Test(.timeLimit(.minutes(1)))
    func `generation requests omit response_format for GPT image models`() async throws {
        ImageServiceMockURLProtocol.reset()
        defer { ImageServiceMockURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageServiceMockURLProtocol.self]
        let service = OpenAIImageService(urlSession: URLSession(configuration: configuration))
        let handle = OpenAIImageService.RequestHandle()
        let completionReceived = FlightTestSignal()
        let errorReceived = FlightTestSignal()
        ImageServiceMockURLProtocol.requestHandler = { request in
            let response = try #require(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#.utf8))
        }

        service.generateImage(
            prompt: "a glass sphere",
            requestConfig: OpenAIImageService.RequestConfig(
                model: "gpt-image-1",
                apiKey: "sk-unit-test",
                provider: .openai,
                customEndpoint: nil,
                azureAPIVersion: "2025-04-01-preview"
            ),
            requestHandle: handle,
            onComplete: { _ in completionReceived.signal() },
            onError: { _ in
                errorReceived.signal()
                completionReceived.signal()
            }
        )

        await completionReceived.wait()
        #expect(!errorReceived.isSignaled)

        let request = try #require(ImageServiceMockURLProtocol.lastRequest)
        let bodyData = try #require(requestBody(from: request))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        #expect(body["response_format"] == nil)
    }

    @Test
    func `cancelled handle cancels a URLSession task rejected during registration`() throws {
        let handle = OpenAIImageService.RequestHandle()
        let url = try #require(URL(string: "https://example.com/image"))
        let task = URLSession(configuration: .ephemeral).dataTask(with: url)
        handle.cancel()

        #expect(!handle.register(task))
        #expect(task.state != .suspended)
    }
}

private final class ImageServiceMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func requestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}
