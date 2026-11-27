import Foundation

extension AIService {
    private func ownsAnthropicFlight(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        model: String
    ) -> Bool {
        if requestLane == .background {
            return backgroundAnthropicProviders[flightID] != nil
        }
        if isMultiModelRequest {
            return multiModelAnthropicProviders[model]?.owns(flightID) == true
        }
        return currentAnthropicProvider.owns(flightID)
    }

    @discardableResult
    private func clearAnthropicFlight(
        _ flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        model: String
    ) -> Bool {
        if requestLane == .background {
            return backgroundAnthropicProviders.removeValue(forKey: flightID) != nil
        }
        if isMultiModelRequest {
            guard var flight = multiModelAnthropicProviders[model],
                  flight.clear(ifOwnedBy: flightID)
            else {
                return false
            }
            multiModelAnthropicProviders.removeValue(forKey: model)
            return true
        }
        return currentAnthropicProvider.clear(ifOwnedBy: flightID)
    }

    // swiftlint:disable:next function_parameter_count
    func handleAnthropicRequest(
        messages: [Message],
        model: String,
        stream: Bool,
        tools: [[String: Any]]?,
        conversationId: UUID?,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        callbacks: AIProviderStreamCallbacks,
        flightID: RequestFlightID = RequestFlightID()
    ) {
        let modelAPIKey = getAPIKey(for: model)
        let endpointInfo = customEndpoint(for: model)

        guard !modelAPIKey.isEmpty else {
            callbacks.onError(AynaError.missingAPIKey(provider: AIProvider.anthropic.displayName))
            return
        }

        let config = AIProviderRequestConfig(
            model: model,
            apiKey: modelAPIKey,
            customEndpoint: endpointInfo?.endpoint,
            maxTokens: nil,
            temperature: nil,
            thinkingBudget: thinkingBudget(for: model)
        )

        let messagesWithMemory = buildMessagesWithMemory(
            from: messages,
            conversationId: conversationId
        )

        let provider = anthropicProviderFactory(urlSession)
        installAnthropicProvider(
            provider,
            flightID: flightID,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            model: model
        )

        let forwarder = makeAnthropicForwarder(
            flightID: flightID,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            model: model,
            callbacks: callbacks
        )

        let wrappedCallbacks = AIProviderStreamCallbacks(
            onChunk: { forwarder.enqueue(.chunk($0)) },
            onComplete: { forwarder.enqueue(.complete) },
            onError: { forwarder.enqueue(.error($0)) },
            onToolCallRequested: { toolID, toolName, arguments in
                forwarder.enqueue(.toolRequest(id: toolID, name: toolName, arguments: arguments))
            },
            onReasoning: { forwarder.enqueue(.reasoning($0)) }
        )

        provider.sendMessage(
            messages: messagesWithMemory,
            config: config,
            stream: stream,
            tools: tools,
            callbacks: wrappedCallbacks
        )
    }

    private func installAnthropicProvider(
        _ provider: any AIProviderProtocol,
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        model: String
    ) {
        if requestLane == .background {
            backgroundAnthropicProviders.updateValue(provider, forKey: flightID)?.cancelRequest()
        } else if isMultiModelRequest {
            var previousFlight = multiModelAnthropicProviders.removeValue(forKey: model)
            let previousProvider = previousFlight?.take()
            previousProvider?.cancelRequest()
            var flight = RequestFlight<any AIProviderProtocol>()
            flight.install(provider, id: flightID)
            multiModelAnthropicProviders[model] = flight
        } else {
            let previousProvider = currentAnthropicProvider.take()
            previousProvider?.cancelRequest()
            currentAnthropicProvider.install(provider, id: flightID)
        }
    }

    private func makeAnthropicForwarder(
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        model: String,
        callbacks: AIProviderStreamCallbacks
    ) -> OrderedMainActorForwarder<AnthropicFlightCallback> {
        OrderedMainActorForwarder<AnthropicFlightCallback> { [weak self] event in
            guard let self else { return }

            switch event {
            case let .chunk(chunk):
                guard self.ownsAnthropicFlight(
                    flightID,
                    requestLane: requestLane,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                ) else {
                    return
                }
                callbacks.onChunk(chunk)

            case .complete:
                let ownsFlight = self.ownsAnthropicFlight(
                    flightID,
                    requestLane: requestLane,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                )
                self.requestFlightObserver.record(.anthropicTerminal, ownsFlight)
                guard ownsFlight,
                      self.clearAnthropicFlight(
                          flightID,
                          requestLane: requestLane,
                          isMultiModelRequest: isMultiModelRequest,
                          model: model
                      )
                else {
                    return
                }
                callbacks.onComplete()

            case let .error(error):
                let ownsFlight = self.ownsAnthropicFlight(
                    flightID,
                    requestLane: requestLane,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                )
                self.requestFlightObserver.record(.anthropicTerminal, ownsFlight)
                guard ownsFlight,
                      self.clearAnthropicFlight(
                          flightID,
                          requestLane: requestLane,
                          isMultiModelRequest: isMultiModelRequest,
                          model: model
                      )
                else {
                    return
                }
                callbacks.onError(error)

            case let .toolRequest(toolID, toolName, arguments):
                guard self.ownsAnthropicFlight(
                    flightID,
                    requestLane: requestLane,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                ) else {
                    return
                }
                callbacks.onToolCallRequested?(toolID, toolName, arguments)

            case let .reasoning(reasoning):
                guard self.ownsAnthropicFlight(
                    flightID,
                    requestLane: requestLane,
                    isMultiModelRequest: isMultiModelRequest,
                    model: model
                ) else {
                    return
                }
                callbacks.onReasoning?(reasoning)
            }
        }
    }
}
