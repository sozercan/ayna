@testable import Ayna
import Foundation
import Testing

// swiftformat:disable swiftTestingTestCaseNames

extension AIServiceTests {
    @Test("An empty model list reports an error and completes the batch")
    func emptyModelListReportsErrorAndCompletesBatch() {
        let service = AIService()
        let errors = FlightTestBox<[String]>([])
        let allComplete = FlightTestBox(false)

        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Empty")],
            models: [],
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { allComplete.value = true },
            onError: { model, error in
                errors.update { $0.append("\(model):\(error.localizedDescription)") }
            }
        )

        #expect(errors.value == [":Please add or select a model in Settings"])
        #expect(allComplete.value)
    }

    @Test("Duplicate normalized models fail before launching a batch")
    func duplicateNormalizedModelsFailBeforeLaunchingBatch() {
        let service = AIService()
        let errors = FlightTestBox<[String]>([])
        let allComplete = FlightTestBox(false)

        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Duplicate")],
            models: ["gpt-4o", " gpt-4o "],
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { allComplete.value = true },
            onError: { model, error in
                errors.update { $0.append("\(model):\(error.localizedDescription)") }
            }
        )

        #expect(errors.value == [
            "gpt-4o:Duplicate model in multi-model request: gpt-4o",
            " gpt-4o :Duplicate model in multi-model request: gpt-4o"
        ])
        #expect(allComplete.value)
    }

    @Test("Cancelling an owned batch stops its child and suppresses callbacks", .timeLimit(.minutes(1)))
    func cancellingOwnedBatchStopsChildAndSuppressesCallbacks() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let model = "owned-batch"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-unit-test"

        let callbackReceived = FlightTestSignal()
        let batch = service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Cancel batch")],
            models: [model],
            onChunk: { _, _ in callbackReceived.signal() },
            onModelComplete: { _ in callbackReceived.signal() },
            onAllComplete: { callbackReceived.signal() },
            onError: { _, _ in callbackReceived.signal() }
        )

        let exchange = await server.exchange(at: 0)
        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        batch.cancel()

        #expect(await exchange.waitUntilStopped(timeout: .seconds(1)))
        exchange.send(Data("data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\n".utf8))
        exchange.finish()
        #expect(await !(callbackReceived.wait(timeout: .milliseconds(100))))
    }

    @Test("A stale batch handle cannot cancel its replacement or a foreground request", .timeLimit(.minutes(1)))
    func staleBatchHandleCannotCancelReplacementOrForeground() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let models = ["stale-batch", "replacement-batch", "foreground"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }

        let staleCallbacks = FlightTestSignal()
        let staleBatch = service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Stale")],
            models: [models[0]],
            onChunk: { _, _ in staleCallbacks.signal() },
            onModelComplete: { _ in staleCallbacks.signal() },
            onAllComplete: { staleCallbacks.signal() },
            onError: { _, _ in staleCallbacks.signal() }
        )
        let staleExchange = await server.exchange(at: 0)
        staleExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        let replacementComplete = FlightTestSignal()
        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Replacement")],
            models: [models[1]],
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { replacementComplete.signal() },
            onError: { _, error in Issue.record("Unexpected replacement error: \(error)") }
        )
        let replacementExchange = await server.exchange(at: 1)
        replacementExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        #expect(await staleExchange.waitUntilStopped(timeout: .seconds(1)))

        let foregroundChunk = FlightTestBox("")
        let foregroundComplete = FlightTestSignal()
        service.sendMessage(
            messages: [Message(role: .user, content: "Foreground")],
            model: models[2],
            onChunk: { foregroundChunk.value += $0 },
            onComplete: { foregroundComplete.signal() },
            onError: { error in Issue.record("Unexpected foreground error: \(error)") }
        )
        let foregroundExchange = await server.exchange(at: 2)
        foregroundExchange.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        staleBatch.cancel()
        #expect(!replacementExchange.isStopped)
        #expect(!foregroundExchange.isStopped)

        replacementExchange.send(Data("data: [DONE]\n\n".utf8))
        replacementExchange.finish()
        foregroundExchange.send(
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"foreground\"}}]}\n\n".utf8)
        )
        foregroundExchange.send(Data("data: [DONE]\n\n".utf8))
        foregroundExchange.finish()

        #expect(await replacementComplete.wait(timeout: .seconds(1)))
        #expect(await foregroundComplete.wait(timeout: .seconds(1)))
        #expect(foregroundChunk.value == "foreground")
        #expect(await !(staleCallbacks.wait(timeout: .milliseconds(100))))
    }

    @Test("A replacement batch drops delayed callbacks from the cancelled batch", .timeLimit(.minutes(1)))
    func replacementBatchDropsDelayedCallbacksFromCancelledBatch() async {
        let staleResponseWaiting = FlightTestSignal()
        let releaseStaleResponse = FlightTestSignal()
        let staleCallbackRejected = FlightTestSignal()
        let responseSimulator: AIServiceResponseSimulator = { messages, callbacks in
            let content = messages.last(where: { $0.role == .user })?.content ?? "Mock response"
            if content == "Stale" {
                Task { @MainActor in
                    staleResponseWaiting.signal()
                    await releaseStaleResponse.wait()
                    callbacks.onChunk("UI Test Response: Stale")
                    callbacks.onComplete()
                }
            } else {
                callbacks.onChunk("UI Test Response: \(content)")
                callbacks.onComplete()
            }
        }
        let service = AIService(
            requestFlightObserver: RequestFlightObserver { checkpoint, ownsFlight in
                if checkpoint == .multiModelCallback, !ownsFlight {
                    staleCallbackRejected.signal()
                }
            },
            responseSimulator: responseSimulator
        )
        let models = ["stale-ui-model", "replacement-ui-model"]
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "ui-test-key"
        }

        let staleChunks = FlightTestBox<[String]>([])
        let staleModelCompletions = FlightTestBox(0)
        let staleErrors = FlightTestBox(0)
        let staleAllComplete = FlightTestBox(false)
        let replacementChunks = FlightTestBox<[String]>([])
        let replacementAllComplete = FlightTestSignal()

        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Stale")],
            models: [models[0]],
            onChunk: { _, chunk in staleChunks.update { $0.append(chunk) } },
            onModelComplete: { _ in staleModelCompletions.update { $0 += 1 } },
            onAllComplete: { staleAllComplete.value = true },
            onError: { _, _ in staleErrors.update { $0 += 1 } }
        )

        let staleResponseIsHeld = await staleResponseWaiting.wait(timeout: .seconds(2))
        #expect(staleResponseIsHeld)
        guard staleResponseIsHeld else {
            releaseStaleResponse.signal()
            service.cancelCurrentRequest()
            return
        }

        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Replacement")],
            models: [models[1]],
            onChunk: { _, chunk in replacementChunks.update { $0.append(chunk) } },
            onModelComplete: { _ in },
            onAllComplete: { replacementAllComplete.signal() },
            onError: { _, error in Issue.record("Unexpected replacement error: \(error)") }
        )

        let replacementCompleted = await replacementAllComplete.wait(timeout: .seconds(2))
        releaseStaleResponse.signal()
        let rejectedStaleCallback = await staleCallbackRejected.wait(timeout: .seconds(2))
        service.cancelCurrentRequest()

        #expect(replacementCompleted)
        #expect(rejectedStaleCallback)
        #expect(replacementChunks.value == ["UI Test Response: Replacement"])
        #expect(staleChunks.value.isEmpty)
        #expect(staleModelCompletions.value == 0)
        #expect(staleErrors.value == 0)
        #expect(!staleAllComplete.value)
    }
}
