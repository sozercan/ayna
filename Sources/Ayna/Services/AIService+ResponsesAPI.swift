import Foundation

extension AIService {
    private struct ResponsesAPIExecutionContext {
        let messages: [Message]
        let model: String
        let toolDefinitions: RequestBuilderToolDefinitions
        let conversationId: UUID?
        let callbacks: StreamCallbacks
        let requestLane: AITextRequestLane
        let isMultiModelRequest: Bool
        let attempt: Int
        let flightID: RequestFlightID
        let existingFlightID: RequestFlightID?
    }

    func responsesAPIRequest(
        messages: [Message],
        model: String,
        tools: [[String: Any]]?,
        conversationId: UUID? = nil,
        callbacks: StreamCallbacks,
        requestLane: AITextRequestLane = .foreground,
        isMultiModelRequest: Bool = false,
        attempt: Int = 0,
        initialFlightID: RequestFlightID? = nil,
        existingFlightID: RequestFlightID? = nil
    ) {
        let flightID = existingFlightID ?? initialFlightID ?? RequestFlightID()
        let context = ResponsesAPIExecutionContext(
            messages: messages,
            model: model,
            toolDefinitions: RequestBuilderToolDefinitions(tools),
            conversationId: conversationId,
            callbacks: callbacks,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            attempt: attempt,
            flightID: flightID,
            existingFlightID: existingFlightID
        )

        guard existingFlightID == nil || ownsDataFlight(
            flightID,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            modelName: model
        ) else {
            return
        }

        guard let prepared = prepareResponsesEndpoint(for: context) else {
            return
        }

        if let tools, !tools.isEmpty {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🔧 Responses API: Sending tools",
                metadata: ["count": "\(tools.count)"]
            )
        }

        let messagesWithMemory = buildMessagesWithMemory(from: messages, conversationId: conversationId)

        if existingFlightID == nil {
            takeDataTask(
                flightID: flightID,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                modelName: model
            )?.cancel()
        }

        let supportsParallelToolCalls = prepared.usesAzureEndpoint ||
            prepared.url.host?.caseInsensitiveCompare("api.openai.com") == .orderedSame
        let buildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let request = await OpenAIRequestBuilder.createResponsesRequestAsync(
                url: prepared.url,
                messages: messagesWithMemory,
                model: model,
                tools: context.toolDefinitions,
                apiKey: prepared.apiKey,
                isAzure: prepared.usesAzureEndpoint,
                supportsParallelToolCalls: supportsParallelToolCalls
            )

            guard self.clearRequestBuildFlight(
                flightID,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                modelName: model
            ) else {
                return
            }

            guard let request else {
                self.reportResponsesSetupError(
                    AynaError.encodingFailed(detail: "Failed to build API request"),
                    context: context
                )
                return
            }

            self.startResponsesDataTask(request: request, context: context)
        }
        installRequestBuildTask(
            buildTask,
            flightID: flightID,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            modelName: model
        )?.cancel()
    }

    private func reportResponsesSetupError(_ error: Error, context: ResponsesAPIExecutionContext) {
        if context.existingFlightID == nil || clearDataFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model
        ) {
            context.callbacks.onError(error)
        }
    }

    private struct PreparedResponsesEndpoint {
        let url: URL
        let apiKey: String
        let usesAzureEndpoint: Bool
    }

    private func prepareResponsesEndpoint(
        for context: ResponsesAPIExecutionContext
    ) -> PreparedResponsesEndpoint? {
        let effectiveProvider: AIProvider
        do {
            effectiveProvider = try resolvedProvider(for: context.model)
        } catch {
            reportResponsesSetupError(error, context: context)
            return nil
        }

        if effectiveProvider == .appleIntelligence {
            reportResponsesSetupError(
                AynaError.apiError(message: "Apple Intelligence doesn't support the Responses API endpoint"),
                context: context
            )
            return nil
        }

        let endpointInfo = customEndpoint(for: context.model)
        let usesAzureEndpoint = endpointInfo.map { isAzureEndpoint($0.endpoint) } ?? false
        let modelAPIKey = getAPIKey(for: context.model)

        let apiURL: String
        do {
            apiURL = try getResponsesAPIURL(deploymentName: context.model, provider: effectiveProvider)
        } catch {
            reportResponsesSetupError(error, context: context)
            return nil
        }

        guard let url = URL(string: apiURL) else {
            reportResponsesSetupError(AynaError.invalidEndpoint(apiURL), context: context)
            return nil
        }

        return PreparedResponsesEndpoint(
            url: url,
            apiKey: modelAPIKey,
            usesAzureEndpoint: usesAzureEndpoint
        )
    }

    private func startResponsesDataTask(
        request: URLRequest,
        context: ResponsesAPIExecutionContext
    ) {
        if context.existingFlightID == nil {
            let previousTask = takeDataTask(
                flightID: context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.model
            )
            previousTask?.cancel()
        } else {
            guard ownsDataFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.model
            ) else {
                return
            }
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, transportError in
            let selfRef = self
            Task { @MainActor in
                guard let self = selfRef else { return }
                self.handleResponsesTaskResult(
                    data: data,
                    response: response,
                    transportError: transportError,
                    requestURL: request.url,
                    context: context
                )
            }
        }

        guard installDataTask(
            task,
            flightID: context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model,
            requiresExistingOwner: context.existingFlightID != nil
        ) else {
            task.cancel()
            return
        }
        task.resume()
    }

    private func handleResponsesTaskResult(
        data: Data?,
        response: URLResponse?,
        transportError: Error?,
        requestURL: URL?,
        context: ResponsesAPIExecutionContext
    ) {
        let ownsFlight = ownsDataFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model
        )
        requestFlightObserver.record(.dataCallback, ownsFlight)
        guard ownsFlight else { return }

        let error = transportError ?? httpStatusError(
            response: response,
            data: data,
            requestURL: requestURL
        )

        if let error {
            handleResponsesError(error, context: context)
            return
        }

        guard let data else {
            finishResponsesWithError(
                AynaError.invalidResponse(detail: "No data received from API"),
                context: context
            )
            return
        }

        deliverResponsesPayload(data: data, context: context)
    }

    private func handleResponsesError(_ error: Error, context: ResponsesAPIExecutionContext) {
        if (error as NSError).code == NSURLErrorCancelled {
            clearDataFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.model
            )
            return
        }

        if shouldRetry(error: error, attempt: context.attempt) {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "⚠️ Retrying responses API request (attempt \(context.attempt + 1))",
                metadata: ["error": error.localizedDescription]
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.delay(for: context.attempt, retryAfterDate: AIRetryPolicy.retryAfterDate(for: error))
                let ownsFlight = self.ownsDataFlight(
                    context.flightID,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    modelName: context.model
                )
                self.requestFlightObserver.record(.dataRetry, ownsFlight)
                guard ownsFlight else { return }
                self.responsesAPIRequest(
                    messages: context.messages,
                    model: context.model,
                    tools: context.toolDefinitions.value,
                    conversationId: context.conversationId,
                    callbacks: context.callbacks,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    attempt: context.attempt + 1,
                    existingFlightID: context.flightID
                )
            }
            return
        }

        finishResponsesWithError(error, context: context)
    }

    private func deliverResponsesPayload(data: Data, context: ResponsesAPIExecutionContext) {
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let errorDict = json?["error"] as? [String: Any],
               let message = errorDict["message"] as? String
            {
                finishResponsesWithError(AynaError.apiError(message: message), context: context)
                return
            }

            if let outputArray = json?["output"] as? [[String: Any]] {
                let result = OpenAIRequestBuilder.deliverResponsesOutput(
                    outputArray,
                    onChunk: { chunk in
                        guard self.ownsResponsesFlight(context) else { return }
                        context.callbacks.onChunk(chunk)
                    },
                    onReasoning: { reasoning in
                        guard self.ownsResponsesFlight(context) else { return }
                        context.callbacks.onReasoning?(reasoning)
                    },
                    onToolCallRequested: { toolID, toolName, arguments in
                        guard self.ownsResponsesFlight(context) else { return }
                        context.callbacks.onToolCallRequested?(toolID, toolName, arguments)
                    }
                )

                guard ownsResponsesFlight(context) else { return }

                if result.hasToolCalls {
                    DiagnosticsLogger.log(
                        .aiService,
                        level: .info,
                        message: "🔧 Responses API: Tool calls detected",
                        metadata: ["count": "\(result.toolCalls.count)"]
                    )
                }
            }

            guard clearDataFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.model
            ) else {
                return
            }
            context.callbacks.onComplete()
        } catch {
            finishResponsesWithError(error, context: context)
        }
    }

    private func ownsResponsesFlight(_ context: ResponsesAPIExecutionContext) -> Bool {
        ownsDataFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model
        )
    }

    private func finishResponsesWithError(_ error: Error, context: ResponsesAPIExecutionContext) {
        guard clearDataFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model
        ) else {
            return
        }
        context.callbacks.onError(error)
    }
}
