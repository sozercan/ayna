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

    @Test(
        "Cancelling a batch fences queued same-token GitHub models",
        .timeLimit(.minutes(1)),
        arguments: MultiModelBatchReplacementTrigger.allCases
    )
    func cancellingBatchFencesQueuedSameTokenGitHubModels(
        trigger: MultiModelBatchReplacementTrigger
    ) async throws {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let permitQueued = FlightTestSignal()
        let service = AIService(
            urlSession: URLSession(configuration: config),
            requestFlightObserver: RequestFlightObserver { checkpoint, _ in
                if checkpoint == .multiModelPermitQueued {
                    permitQueued.signal()
                }
            }
        )
        let staleModels = ["github-stale-a", "github-stale-b"]
        let replacementModel = "github-replacement"
        let token = "github-token-\(UUID().uuidString)"
        let models = staleModels + [replacementModel]
        let staleAllComplete = FlightTestBox(false)
        let replacementAllComplete = FlightTestSignal()
        service.customModels = models
        service.selectedModel = staleModels[0]
        for model in models {
            service.modelProviders[model] = .githubModels
            service.modelAPIKeys[model] = token
        }

        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Stale batch")],
            models: staleModels,
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { staleAllComplete.value = true },
            onError: { _, _ in }
        )
        let firstRequestStarted = await server.waitForRequestCount(1)
        #expect(firstRequestStarted)
        guard firstRequestStarted else {
            service.cancelCurrentRequest()
            return
        }
        _ = await server.exchange(at: 0)
        let queuedBeforeCancellation = await permitQueued.wait(timeout: .seconds(2))
        #expect(queuedBeforeCancellation)
        guard queuedBeforeCancellation else {
            service.cancelCurrentRequest()
            return
        }

        if trigger == .stopThenReplace {
            service.cancelCurrentRequest()
        }
        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Replacement")],
            models: [replacementModel],
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { replacementAllComplete.signal() },
            onError: { _, _ in }
        )

        let replacementStarted = await server.waitForRequestCount(2)
        #expect(replacementStarted)
        guard replacementStarted else {
            service.cancelCurrentRequest()
            return
        }

        let next = await server.exchange(at: 1)
        let startedModel = try requestModel(from: next.request)

        next.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        next.send(Data("data: [DONE]\n\n".utf8))
        next.finish()
        let replacementCompleted = await replacementAllComplete.wait(timeout: .seconds(2))
        service.cancelCurrentRequest()

        #expect(startedModel == replacementModel)
        #expect(replacementCompleted)
        #expect(!staleAllComplete.value)
        #expect(server.requestCount == 2)
    }

    @Test(
        "A queued model rejects configuration changes before launch",
        .timeLimit(.minutes(1)),
        arguments: MultiModelQueuedMutation.allCases
    )
    func queuedModelRejectsConfigurationChangesBeforeLaunch(
        mutation: MultiModelQueuedMutation
    ) async throws {
        GitHubOAuthService.shared.signOut()
        defer { GitHubOAuthService.shared.signOut() }

        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let permitQueued = FlightTestSignal()
        let service = AIService(
            urlSession: URLSession(configuration: config),
            requestFlightObserver: RequestFlightObserver { checkpoint, _ in
                if checkpoint == .multiModelPermitQueued {
                    permitQueued.signal()
                }
            }
        )
        let models = ["config-a", "config-b"]
        let token = "config-token-\(UUID().uuidString)"
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .githubModels
            service.modelAPIKeys[model] = token
        }

        let errors = FlightTestBox<[String]>([])
        let allComplete = FlightTestSignal()
        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "Configuration")],
            models: models,
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { allComplete.signal() },
            onError: { model, error in
                errors.update { $0.append("\(model):\(error.localizedDescription)") }
            }
        )

        let firstRequestStarted = await server.waitForRequestCount(1)
        let queuedBeforeMutation = await permitQueued.wait(timeout: .seconds(2))
        #expect(firstRequestStarted)
        #expect(queuedBeforeMutation)
        guard firstRequestStarted, queuedBeforeMutation else {
            service.cancelCurrentRequest()
            return
        }

        let first = await server.exchange(at: 0)
        let startedModel = try requestModel(from: first.request)
        let queuedModel = try #require(models.first(where: { $0 != startedModel }))
        switch mutation {
        case .provider:
            service.modelProviders[queuedModel] = .openai
        case .credential:
            service.modelAPIKeys[queuedModel] = "replacement-token"
        case .oauthPreference:
            let tokenInfo = GitHubTokenInfo(
                accessToken: "oauth-token",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scope: "models:read"
            )
            try GitHubOAuthService.keychain.setData(
                JSONEncoder().encode(tokenInfo),
                for: "github_token_info"
            )
            GitHubOAuthService.shared.isAuthenticated = true
        }

        first.sendResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"])
        first.send(Data("data: [DONE]\n\n".utf8))
        first.finish()
        let didComplete = await allComplete.wait(timeout: .seconds(2))
        service.cancelCurrentRequest()

        #expect(didComplete)
        #expect(server.requestCount == 1)
        #expect(errors.value == [
            "\(queuedModel):Model configuration changed while the request was queued. Please retry."
        ])
    }

    @Test("A near-expiry OAuth token without a refresh token remains valid")
    func nearExpiryOAuthTokenWithoutRefreshTokenRemainsValid() throws {
        let storage = InMemoryKeychainStorage()
        GitHubOAuthService.keychain = storage
        let accessToken = "near-expiry-token"
        let tokenInfo = GitHubTokenInfo(
            accessToken: accessToken,
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(60),
            scope: "models:read"
        )
        try storage.setData(JSONEncoder().encode(tokenInfo), for: "github_token_info")
        let oauth = GitHubOAuthService()

        #expect(oauth.isCurrentAccessTokenValid(accessToken))
    }

    @Test("A missing prepared GitHub credential never launches a request", .timeLimit(.minutes(1)))
    func missingPreparedGitHubCredentialNeverLaunchesRequest() async {
        GitHubOAuthService.shared.signOut()
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        let model = "github-missing-key"
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .githubModels
        service.modelAPIKeys[model] = ""
        let errors = FlightTestBox<[String]>([])
        let allComplete = FlightTestSignal()

        service.sendToMultipleModels(
            messages: [Message(role: .user, content: "No key")],
            models: [model],
            onChunk: { _, _ in },
            onModelComplete: { _ in },
            onAllComplete: { allComplete.signal() },
            onError: { _, error in errors.update { $0.append(error.localizedDescription) } }
        )

        let didComplete = await allComplete.wait(timeout: .seconds(2))
        service.cancelCurrentRequest()

        #expect(didComplete)
        #expect(errors.value == ["GitHub Models API key not configured"])
        #expect(server.requestCount == 0)
    }

    @Test("Prepared API key is the exact credential sent", .timeLimit(.minutes(1)))
    func preparedAPIKeyIsTheExactCredentialSent() async {
        let server = FlightTestURLProtocolServer()
        FlightTestURLProtocol.install(server: server)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlightTestURLProtocol.self]
        let service = AIService(urlSession: URLSession(configuration: config))
        service.customModels = ["prepared-model"]
        service.selectedModel = "prepared-model"
        service.modelProviders["prepared-model"] = .openai
        service.modelAPIKeys["prepared-model"] = "configured-key"
        let completed = FlightTestSignal()

        service.sendMessage(
            messages: [Message(role: .user, content: "Hello")],
            model: "prepared-model",
            stream: false,
            onChunk: { _ in },
            onComplete: { completed.signal() },
            onError: { error in Issue.record("Unexpected error: \(error)") },
            preparedAPIKey: "prepared-key"
        )

        let requestStarted = await server.waitForRequestCount(1)
        #expect(requestStarted)
        guard requestStarted else {
            service.cancelCurrentRequest()
            return
        }
        let exchange = await server.exchange(at: 0)
        let authorization = exchange.request.value(forHTTPHeaderField: "Authorization")
        exchange.sendResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
        exchange.send(Data("{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}".utf8))
        exchange.finish()
        let didComplete = await completed.wait(timeout: .seconds(2))
        service.cancelCurrentRequest()

        #expect(authorization == "Bearer prepared-key")
        #expect(didComplete)
    }

    private func requestModel(from request: URLRequest) throws -> String {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var streamedBody = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 1024)
                guard count > 0 else { break }
                streamedBody.append(buffer, count: count)
            }
            stream.close()
            body = streamedBody
        }

        let requestBody = try #require(body)
        let object = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        return try #require(object["model"] as? String)
    }
}

enum MultiModelQueuedMutation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case provider
    case credential
    case oauthPreference

    var testDescription: String {
        rawValue
    }
}

enum MultiModelBatchReplacementTrigger: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case stopThenReplace
    case replaceDirectly

    var testDescription: String {
        rawValue
    }
}
