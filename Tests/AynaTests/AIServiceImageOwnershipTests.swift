@testable import Ayna
import Foundation
import Testing

extension AIServiceTests {
    @Test("Cancelling the current request stops image generation and suppresses callbacks", .timeLimit(.minutes(1)))
    func cancellingCurrentRequestStopsImageGenerationAndSuppressesCallbacks() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-cancel.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let callbackReceived = FlightTestSignal()
        service.generateImage(
            prompt: "a glass sphere",
            model: "image-model",
            onComplete: { _ in callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() }
        )

        let exchange = await server.exchange(at: 0)
        service.cancelCurrentRequest()
        let requestStopped = await exchange.waitUntilStopped(timeout: .milliseconds(250))

        exchange.sendResponse(statusCode: 200)
        exchange.send(Data(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#.utf8))
        exchange.finish()
        let callbackWasDelivered = await callbackReceived.wait(timeout: .milliseconds(100))

        #expect(requestStopped)
        #expect(!callbackWasDelivered)
    }

    @Test("Cancelling the current request stops image editing and suppresses callbacks", .timeLimit(.minutes(1)))
    func cancellingCurrentRequestStopsImageEditingAndSuppressesCallbacks() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-edit-cancel.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let callbackReceived = FlightTestSignal()
        service.editImage(
            prompt: "make it blue",
            sourceImage: Data("source".utf8),
            model: "image-model",
            onComplete: { _ in callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() }
        )

        let exchange = await server.exchange(at: 0)
        service.cancelCurrentRequest()
        let requestStopped = await exchange.waitUntilStopped(timeout: .milliseconds(250))

        exchange.sendResponse(statusCode: 200)
        exchange.send(Data(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#.utf8))
        exchange.finish()
        let callbackWasDelivered = await callbackReceived.wait(timeout: .milliseconds(100))

        #expect(requestStopped)
        #expect(!callbackWasDelivered)
    }

    @Test("Cancelling image generation during retry backoff prevents a retry", .timeLimit(.minutes(1)))
    func cancellingImageGenerationDuringRetryBackoffPreventsRetry() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let retryStarted = FlightTestSignal()
        let releaseRetry = FlightTestSignal()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(
            urlSession: URLSession(configuration: config),
            retryDelay: { _, _ in
                retryStarted.signal()
                await releaseRetry.wait()
            }
        )
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-retry.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let callbackReceived = FlightTestSignal()
        service.generateImage(
            prompt: "a glass sphere",
            model: "image-model",
            onComplete: { _ in callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() }
        )

        let firstExchange = await server.exchange(at: 0)
        firstExchange.fail(URLError(.networkConnectionLost))
        await retryStarted.wait()

        service.cancelCurrentRequest()
        releaseRetry.signal()

        let retryStartedAfterCancellation = await server.waitForRequestCount(2, timeout: .milliseconds(150))
        let callbackWasDelivered = await callbackReceived.wait(timeout: .milliseconds(100))
        #expect(!retryStartedAfterCancellation)
        #expect(!callbackWasDelivered)
    }

    @Test("Cancelling image generation stops a fallback image download", .timeLimit(.minutes(1)))
    func cancellingImageGenerationStopsFallbackImageDownload() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-fallback.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let callbackReceived = FlightTestSignal()
        service.generateImage(
            prompt: "a glass sphere",
            model: "image-model",
            onComplete: { _ in callbackReceived.signal() },
            onError: { _ in callbackReceived.signal() }
        )

        let generationExchange = await server.exchange(at: 0)
        generationExchange.sendResponse(statusCode: 200)
        generationExchange.send(Data(#"{"data":[{"url":"https://cdn.example.com/generated.png"}]}"#.utf8))
        generationExchange.finish()

        let downloadExchange = await server.exchange(at: 1)
        service.cancelCurrentRequest()
        let downloadStopped = await downloadExchange.waitUntilStopped(timeout: .milliseconds(250))

        downloadExchange.sendResponse(statusCode: 200)
        downloadExchange.send(Data("image".utf8))
        downloadExchange.finish()
        let callbackWasDelivered = await callbackReceived.wait(timeout: .milliseconds(100))

        #expect(downloadStopped)
        #expect(!callbackWasDelivered)
    }

    @Test("A failed fallback image download reports an error instead of completing", .timeLimit(.minutes(1)))
    func failedFallbackImageDownloadReportsErrorInsteadOfCompleting() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-fallback-error.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let completionReceived = FlightTestSignal()
        let errorReceived = FlightTestSignal()
        service.generateImage(
            prompt: "a glass sphere",
            model: "image-model",
            onComplete: { _ in completionReceived.signal() },
            onError: { _ in errorReceived.signal() }
        )

        let generationExchange = await server.exchange(at: 0)
        generationExchange.sendResponse(statusCode: 200)
        generationExchange.send(Data(#"{"data":[{"url":"https://cdn.example.com/missing.png"}]}"#.utf8))
        generationExchange.finish()

        let downloadExchange = await server.exchange(at: 1)
        downloadExchange.sendResponse(statusCode: 404)
        downloadExchange.send(Data("not an image".utf8))
        downloadExchange.finish()

        #expect(await errorReceived.wait(timeout: .seconds(1)))
        #expect(!completionReceived.isSignaled)
    }

    @Test("A successful fallback response with non-image data reports an error", .timeLimit(.minutes(1)))
    func successfulFallbackResponseWithNonImageDataReportsError() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-fallback-html.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let completionReceived = FlightTestSignal()
        let errorReceived = FlightTestSignal()
        service.generateImage(
            prompt: "a glass sphere",
            model: "image-model",
            onComplete: { _ in completionReceived.signal() },
            onError: { _ in errorReceived.signal() }
        )

        let generationExchange = await server.exchange(at: 0)
        generationExchange.sendResponse(statusCode: 200)
        generationExchange.send(Data(#"{"data":[{"url":"https://cdn.example.com/not-image.png"}]}"#.utf8))
        generationExchange.finish()

        let downloadExchange = await server.exchange(at: 1)
        downloadExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/html"])
        downloadExchange.send(Data("<html>error</html>".utf8))
        downloadExchange.finish()

        #expect(await errorReceived.wait(timeout: .seconds(1)))
        #expect(!completionReceived.isSignaled)
    }

    @Test("A transient fallback download failure retries under the same owner", .timeLimit(.minutes(1)))
    func transientFallbackDownloadFailureRetriesUnderSameOwner() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let retryStarted = FlightTestSignal()
        let releaseRetry = FlightTestSignal()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(
            urlSession: URLSession(configuration: config),
            retryDelay: { _, _ in
                retryStarted.signal()
                await releaseRetry.wait()
            }
        )
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-fallback-retry.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let completionReceived = FlightTestSignal()
        let errorReceived = FlightTestSignal()
        service.generateImage(
            prompt: "a glass sphere",
            model: "image-model",
            onComplete: { _ in completionReceived.signal() },
            onError: { _ in errorReceived.signal() }
        )

        let generationExchange = await server.exchange(at: 0)
        generationExchange.sendResponse(statusCode: 200)
        generationExchange.send(Data(#"{"data":[{"url":"https://cdn.example.com/transient.png"}]}"#.utf8))
        generationExchange.finish()

        let failedDownload = await server.exchange(at: 1)
        failedDownload.sendResponse(statusCode: 503)
        failedDownload.send(Data("temporarily unavailable".utf8))
        failedDownload.finish()
        await retryStarted.wait()

        releaseRetry.signal()
        let retriedDownload = await server.exchange(at: 2)
        retriedDownload.sendResponse(statusCode: 200)
        retriedDownload.send(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        retriedDownload.finish()

        #expect(await completionReceived.wait(timeout: .seconds(1)))
        #expect(!errorReceived.isSignaled)
    }

    @Test("An active fallback download cancellation terminates with an error", .timeLimit(.minutes(1)))
    func activeFallbackDownloadCancellationTerminatesWithError() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-fallback-cancelled.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let completionReceived = FlightTestSignal()
        let errorReceived = FlightTestSignal()
        service.generateImage(
            prompt: "a glass sphere",
            model: "image-model",
            onComplete: { _ in completionReceived.signal() },
            onError: { _ in errorReceived.signal() }
        )

        let generationExchange = await server.exchange(at: 0)
        generationExchange.sendResponse(statusCode: 200)
        generationExchange.send(Data(#"{"data":[{"url":"https://cdn.example.com/cancelled.png"}]}"#.utf8))
        generationExchange.finish()

        let downloadExchange = await server.exchange(at: 1)
        downloadExchange.fail(URLError(.cancelled))

        #expect(await errorReceived.wait(timeout: .seconds(1)))
        #expect(!completionReceived.isSignaled)
    }

    @Test("Cancelling one image request preserves a peer request", .timeLimit(.minutes(1)))
    func cancellingOneImageRequestPreservesPeerRequest() async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-peer.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let firstCallback = FlightTestSignal()
        let secondCallback = FlightTestSignal()
        let firstRequestCandidate = service.generateImage(
            prompt: "first",
            model: "image-model",
            onComplete: { _ in firstCallback.signal() },
            onError: { _ in firstCallback.signal() }
        )
        let firstRequest = try #require(firstRequestCandidate)
        service.generateImage(
            prompt: "second",
            model: "image-model",
            onComplete: { _ in secondCallback.signal() },
            onError: { _ in secondCallback.signal() }
        )

        let firstExchange = await server.exchange(at: 0)
        let secondExchange = await server.exchange(at: 1)
        firstRequest.cancel()

        let firstStopped = await firstExchange.waitUntilStopped(timeout: .milliseconds(250))
        #expect(firstStopped)
        #expect(!secondExchange.isStopped)

        secondExchange.sendResponse(statusCode: 200)
        secondExchange.send(Data(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#.utf8))
        secondExchange.finish()

        let secondCompleted = await secondCallback.wait(timeout: .seconds(1))
        let firstCompleted = await firstCallback.wait(timeout: .milliseconds(100))
        #expect(secondCompleted)
        #expect(!firstCompleted)
    }

    @Test("Cancelling non-image work preserves an image owned by another view", .timeLimit(.minutes(1)))
    func cancellingNonImageWorkPreservesImageOwnedByAnotherView() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-peer-stop.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let completionReceived = FlightTestSignal()
        service.generateImage(
            prompt: "peer image",
            model: "image-model",
            onComplete: { _ in completionReceived.signal() },
            onError: { _ in }
        )

        let exchange = await server.exchange(at: 0)
        service.cancelCurrentRequest(includeImageRequests: false)
        #expect(!exchange.isStopped)

        exchange.sendResponse(statusCode: 200)
        exchange.send(Data(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#.utf8))
        exchange.finish()
        #expect(await completionReceived.wait(timeout: .seconds(1)))
    }

    @Test("Replacing a logical image batch cancels every old child and preserves new children", .timeLimit(.minutes(1)))
    func replacingLogicalImageBatchCancelsOldChildrenAndPreservesNewChildren() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["image-model"]
        service.selectedModel = "image-model"
        service.modelProviders["image-model"] = .openai
        service.modelAPIKeys["image-model"] = "sk-unit-test"
        service.modelEndpoints["image-model"] = "https://image-batch-replacement.example.com"
        service.modelEndpointTypes["image-model"] = .imageGeneration

        let coordinator = ImageGenerationCoordinator()
        let oldOperationID = coordinator.beginOperation()
        for prompt in ["old-one", "old-two"] {
            let request = service.generateImage(
                prompt: prompt,
                model: "image-model",
                onComplete: { _ in },
                onError: { _ in }
            )
            coordinator.track(request, for: oldOperationID)
        }
        let firstOldExchange = await server.exchange(at: 0)
        let secondOldExchange = await server.exchange(at: 1)

        let newOperationID = coordinator.beginOperation()
        for prompt in ["new-one", "new-two"] {
            let request = service.generateImage(
                prompt: prompt,
                model: "image-model",
                onComplete: { _ in },
                onError: { _ in }
            )
            coordinator.track(request, for: newOperationID)
        }
        let firstNewExchange = await server.exchange(at: 2)
        let secondNewExchange = await server.exchange(at: 3)

        #expect(await firstOldExchange.waitUntilStopped(timeout: .milliseconds(250)))
        #expect(await secondOldExchange.waitUntilStopped(timeout: .milliseconds(250)))
        #expect(!firstNewExchange.isStopped)
        #expect(!secondNewExchange.isStopped)
        #expect(coordinator.owns(newOperationID))

        coordinator.cancelCurrentOperation()
        #expect(await firstNewExchange.waitUntilStopped(timeout: .milliseconds(250)))
        #expect(await secondNewExchange.waitUntilStopped(timeout: .milliseconds(250)))
    }
}
