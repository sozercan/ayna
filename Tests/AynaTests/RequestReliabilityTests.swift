// swiftlint:disable identifier_name
@testable import Ayna
import Foundation
import Testing

@Suite("Request reliability")
struct RequestReliabilityTests {
    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test(arguments: [408, 409, 429, 500, 503, 529])
    func `Transient statuses are retried`(status: Int) {
        let error = HTTPStatusError(statusCode: status, message: "x")
        #expect(AIRetryPolicy.shouldRetry(error: error, attempt: 0))
    }

    @Test(arguments: [400, 401, 403, 404, 422])
    func `Client errors are not retried`(status: Int) {
        let error = HTTPStatusError(statusCode: status, message: "x")
        #expect(!AIRetryPolicy.shouldRetry(error: error, attempt: 0))
    }

    @Test
    func `Retry-After is read as milliseconds, seconds, or an HTTP date`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fromMilliseconds = HTTPStatusError(
            statusCode: 429, message: "", response: response(429, headers: ["retry-after-ms": "1500", "Retry-After": "9"]), now: now
        )
        let fromSeconds = HTTPStatusError(statusCode: 429, message: "", response: response(429, headers: ["Retry-After": "7"]), now: now)
        let fromDate = HTTPStatusError(
            statusCode: 503, message: "", response: response(503, headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]), now: now
        )
        let missing = HTTPStatusError(statusCode: 503, message: "", response: response(503), now: now)

        #expect(fromMilliseconds.retryAfter == now.addingTimeInterval(1.5))
        #expect(fromSeconds.retryAfter == now.addingTimeInterval(7))
        #expect(fromDate.retryAfter == Date(timeIntervalSince1970: 1_445_412_480))
        #expect(missing.retryAfter == nil)
        #expect(AIRetryPolicy.retryAfterDate(for: fromSeconds) == now.addingTimeInterval(7))
    }

    @Test
    func `Claude output defaults fit each model`() {
        #expect(AnthropicOutputLimits.defaultMaxTokens(model: "claude-opus-5-5", stream: true) == 64000)
        #expect(AnthropicOutputLimits.defaultMaxTokens(model: "claude-opus-5-5", stream: false) == 16000)
        #expect(AnthropicOutputLimits.defaultMaxTokens(model: "claude-haiku-4-5", stream: true) == 64000)
        #expect(AnthropicOutputLimits.defaultMaxTokens(model: "claude-3-5-sonnet-20241022", stream: true) == 8192)
        #expect(AnthropicOutputLimits.defaultMaxTokens(model: "claude-3-haiku-20240307", stream: false) == 4096)
        #expect(AnthropicOutputLimits.defaultMaxTokens(model: "claude-opus-4-1-20250805", stream: true) == 32000)
    }

    #if !os(watchOS)
        @Test
        func `Output format and compression go only to GPT Image models`() {
            let jpeg = OpenAIImageService.ImageConfig(size: "1024x1024", quality: "low", outputFormat: "jpeg", outputCompression: 70)
            let png = OpenAIImageService.ImageConfig(size: "1024x1024", quality: "low", outputFormat: "png", outputCompression: 70)

            let gptJPEG = OpenAIImageService.outputFields(model: "gpt-image-1", config: jpeg)
            #expect(gptJPEG.map(\.0) == ["output_format", "output_compression"])
            #expect(gptJPEG.map(\.1) == ["jpeg", "70"])
            #expect(OpenAIImageService.outputFields(model: "gpt-image-1", config: png).map(\.0) == ["output_format"])
            #expect(OpenAIImageService.outputFields(model: "dall-e-3", config: jpeg).isEmpty)
        }
    #endif

    @Test
    func `Previous images are sent with their real type`() {
        #expect(ImageEditContext.sniffedImageMIMEType(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(ImageEditContext.sniffedImageMIMEType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == "image/png")
        #expect(ImageEditContext.sniffedImageMIMEType(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == "image/webp")
        #expect(ImageEditContext.sniffedImageMIMEType(Data([0x00, 0x01])) == nil)
    }
}

extension AIServiceGlobalStateTests {
    @Suite("AIService status retries", .serialized)
    @MainActor
    struct AIServiceStatusRetryTests {
        init() {
            // Isolate persisted settings and keys from the real defaults and Keychain.
            let suiteName = "AIServiceStatusRetryTests"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                fatalError("Failed to create UserDefaults suite for \(suiteName)")
            }
            defaults.removePersistentDomain(forName: suiteName)
            AppPreferences.use(defaults)
            AIService.keychain = InMemoryKeychainStorage()
        }

        @Test(.timeLimit(.minutes(1)), arguments: DataFlightVariant.allCases)
        func `A 503 with Retry-After is retried and then succeeds`(variant: DataFlightVariant) async {
            let server = FlightTestURLProtocolServer()
            FlightTestURLProtocol.install(server: server)
            defer { FlightTestURLProtocol.reset() }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FlightTestURLProtocol.self]
            let requestedRetryAfter = FlightTestBox<Date?>(nil)
            let firstResponseSentAt = FlightTestBox(Date.distantPast)
            let service = AIService(
                urlSession: URLSession(configuration: config),
                retryDelay: { _, retryAfter in requestedRetryAfter.value = retryAfter }
            )
            let model = variant.model
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
            service.modelEndpointTypes[model] = variant.endpointType

            let chunks = FlightTestBox("")
            let completed = FlightTestSignal()
            let failure = FlightTestBox<String?>(nil)
            service.sendMessage(
                messages: [Message(role: .user, content: "Hi")],
                model: model,
                stream: false,
                onChunk: { chunks.value += $0 },
                onComplete: { completed.signal() },
                onError: { failure.value = $0.localizedDescription; completed.signal() }
            )

            let first = await server.exchange(at: 0)
            firstResponseSentAt.value = Date()
            first.sendResponse(statusCode: 503, headers: ["Content-Type": "application/json", "Retry-After": "3"])
            first.send(Data("{\"error\":{\"message\":\"overloaded\"}}".utf8))
            first.finish()

            // Bounded wait, so a retry regression fails here instead of hanging on the exchange.
            let retried = await server.waitForRequestCount(2, timeout: .seconds(5))
            #expect(retried)
            guard retried else { return }
            let second = await server.exchange(at: 1)
            second.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
            second.send(variant.responseData)
            second.finish()

            #expect(await completed.wait(timeout: .seconds(5)))
            #expect(failure.value == nil)
            #expect(chunks.value == "stale")
            // The deadline is three seconds after the 503 arrived.
            let deadline = requestedRetryAfter.value.map { $0.timeIntervalSince(firstResponseSentAt.value) } ?? -1
            #expect(deadline >= 3 && deadline <= 8)
        }

        @Test(.timeLimit(.minutes(1)))
        func `A 400 is reported without retrying`() async {
            let server = FlightTestURLProtocolServer()
            FlightTestURLProtocol.install(server: server)
            defer { FlightTestURLProtocol.reset() }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FlightTestURLProtocol.self]
            let service = AIService(urlSession: URLSession(configuration: config), retryDelay: { _, _ in })
            let model = DataFlightVariant.chatCompletions.model
            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
            service.modelEndpointTypes[model] = .chatCompletions

            let failure = FlightTestBox<Error?>(nil)
            let done = FlightTestSignal()
            service.sendMessage(
                messages: [Message(role: .user, content: "Hi")],
                model: model,
                stream: false,
                onChunk: { _ in },
                onComplete: { done.signal() },
                onError: { failure.value = $0; done.signal() }
            )
            let first = await server.exchange(at: 0)
            first.sendResponse(statusCode: 400, headers: ["Content-Type": "application/json"])
            first.send(Data("{\"error\":{\"message\":\"bad model\"}}".utf8))
            first.finish()

            #expect(await done.wait(timeout: .seconds(5)))
            #expect((failure.value as? HTTPStatusError)?.statusCode == 400)
            #expect(server.requestCount == 1)
        }
    }
}

// swiftlint:enable identifier_name
