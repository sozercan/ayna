import Foundation

extension AIService {
    private struct MultiModelExecutionContext: Sendable {
        let messages: [Message]
        let callbackModel: String
        let model: String
        let temperature: Double?
        let effectiveProvider: AIProvider
        let preparedEndpoint: String?
        let preparedEndpointType: APIEndpointType?
        let flightID: RequestFlightID
        let observer: RequestFlightObserver
        let onChunk: @Sendable (String, String) -> Void
        let onModelComplete: @Sendable (String) -> Void
        let onError: @Sendable (String, Error) -> Void
        let onPendingToolCall: (@Sendable (String, String, String, [String: Any]) -> Void)?
        let onReasoning: (@Sendable (String, String) -> Void)?
    }

    @discardableResult
    func sendToMultipleModels(
        messages: [Message],
        models: [String],
        temperature: Double? = nil,
        onChunk: @escaping @Sendable (String, String) -> Void,
        onModelComplete: @escaping @Sendable (String) -> Void,
        onAllComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (String, Error) -> Void,
        onPendingToolCall: (@Sendable (String, String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String, String) -> Void)? = nil
    ) -> AITextBatchRequest {
        let flightID = RequestFlightID()
        let requestHandle = AITextBatchRequest(service: self, flightID: flightID)

        guard let validated = validateMultiModelBatch(models: models, onError: onError, onAllComplete: onAllComplete) else {
            return requestHandle
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🔀 Starting multi-model request",
            metadata: ["models": validated.requestModels.joined(separator: ", ")]
        )

        cancelAllMultiModelFlights()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                for (callbackModel, model) in validated.modelRequests {
                    guard !Task.isCancelled, self.multiModelTask.owns(flightID) else { return }
                    guard let effectiveProvider = validated.requestProviders[model] else { continue }
                    let executionContext = MultiModelExecutionContext(
                        messages: messages,
                        callbackModel: callbackModel,
                        model: model,
                        temperature: temperature,
                        effectiveProvider: effectiveProvider,
                        preparedEndpoint: self.modelEndpoints[model],
                        preparedEndpointType: self.modelEndpointTypes[model],
                        flightID: flightID,
                        observer: self.requestFlightObserver,
                        onChunk: onChunk,
                        onModelComplete: onModelComplete,
                        onError: onError,
                        onPendingToolCall: onPendingToolCall,
                        onReasoning: onReasoning
                    )

                    group.addTask { [weak self] in
                        await self?.runMultiModelMember(executionContext)
                    }
                }
            }

            guard !Task.isCancelled else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🛑 Multi-model task cancelled, not calling onAllComplete"
                )
                return
            }

            guard self.multiModelTask.clear(ifOwnedBy: flightID) else { return }
            self.multiModelRequestBuildTasks.removeAll()
            self.multiModelStreamTasks.removeAll()
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🏁 All models completed in multi-model request"
            )
            onAllComplete()
        }
        multiModelTask.install(task, id: flightID)?.cancel()
        return requestHandle
    }

    private struct ValidatedMultiModelBatch {
        let requestModels: [String]
        let modelRequests: [(String, String)]
        let requestProviders: [String: AIProvider]
    }

    private func validateMultiModelBatch(
        models: [String],
        onError: @escaping @Sendable (String, Error) -> Void,
        onAllComplete: @escaping @Sendable () -> Void
    ) -> ValidatedMultiModelBatch? {
        guard !models.isEmpty else {
            onError("", AynaError.noModelSelected)
            onAllComplete()
            return nil
        }

        func rejectBatch(_ error: Error) {
            models.forEach { onError($0, error) }
            onAllComplete()
        }

        let requestModels = models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let modelRequests = Array(zip(models, requestModels))
        guard !requestModels.contains(where: \.isEmpty) else {
            rejectBatch(AynaError.noModelSelected)
            return nil
        }

        var uniqueModels: Set<String> = []
        if let duplicateModel = requestModels.first(where: { !uniqueModels.insert($0).inserted }) {
            rejectBatch(AynaError.apiError(message: "Duplicate model in multi-model request: \(duplicateModel)"))
            return nil
        }

        var requestProviders: [String: AIProvider] = [:]
        do {
            for model in requestModels {
                requestProviders[model] = try resolvedProvider(for: model)
            }
        } catch {
            rejectBatch(error)
            return nil
        }

        return ValidatedMultiModelBatch(
            requestModels: requestModels,
            modelRequests: modelRequests,
            requestProviders: requestProviders
        )
    }

    private nonisolated func runMultiModelMember(_ context: MultiModelExecutionContext) async {
        guard !Task.isCancelled else {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🛑 Multi-model task cancelled before starting model",
                metadata: ["model": context.model]
            )
            return
        }

        let stillOwnsBatch = await MainActor.run {
            self.multiModelTask.owns(context.flightID)
        }
        guard stillOwnsBatch else { return }

        await MultiModelRequestRunner.run { [weak self] completion in
            guard let self,
                  !Task.isCancelled,
                  self.multiModelTask.owns(context.flightID)
            else {
                completion()
                return
            }

            let callbackForwarder = self.makeMultiModelCallbackForwarder(
                context: context,
                completion: completion
            )

            let currentProvider = try? self.resolvedProvider(for: context.model)
            guard currentProvider == context.effectiveProvider,
                  self.modelEndpoints[context.model] == context.preparedEndpoint,
                  self.modelEndpointTypes[context.model] == context.preparedEndpointType
            else {
                callbackForwarder.enqueue(
                    .error(
                        AynaError.apiError(
                            message: "Model configuration changed while the request was queued. Please retry."
                        )
                    )
                )
                return
            }

            context.observer.record(.multiModelStart, true)

            self.sendMessage(
                messages: context.messages,
                model: context.model,
                temperature: context.temperature,
                stream: true,
                tools: nil,
                conversationId: nil,
                isMultiModelRequest: true,
                onChunk: { chunk in
                    callbackForwarder.enqueue(.chunk(chunk))
                },
                onComplete: {
                    callbackForwarder.enqueue(.complete)
                },
                onError: { error in
                    callbackForwarder.enqueue(.error(error))
                },
                onToolCallRequested: { toolID, toolName, arguments in
                    callbackForwarder.enqueue(
                        .toolRequest(id: toolID, name: toolName, arguments: arguments)
                    )
                },
                onReasoning: { reasoning in
                    callbackForwarder.enqueue(.reasoning(reasoning))
                },
                requestFlightID: context.flightID
            )
        }
    }

    private func makeMultiModelCallbackForwarder(
        context: MultiModelExecutionContext,
        completion: MultiModelRequestRunner.Completion
    ) -> OrderedMainActorForwarder<MultiModelBatchCallback> {
        OrderedMainActorForwarder<MultiModelBatchCallback> { [weak self] event in
            let ownsBatch = self?.multiModelTask.owns(context.flightID) == true
            context.observer.record(.multiModelCallback, ownsBatch)
            guard ownsBatch else { return }

            switch event {
            case let .chunk(chunk):
                guard !completion.isFinished else { return }
                context.onChunk(context.callbackModel, chunk)

            case .complete:
                guard completion() else { return }
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "✅ Model completed in multi-model request",
                    metadata: ["model": context.model]
                )
                context.onModelComplete(context.callbackModel)

            case let .error(error):
                guard completion() else { return }
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "❌ Model failed in multi-model request",
                    metadata: ["model": context.model, "error": error.localizedDescription]
                )
                context.onError(context.callbackModel, error)

            case let .toolRequest(toolID, toolName, arguments):
                guard !completion.isFinished else { return }
                context.onPendingToolCall?(context.callbackModel, toolID, toolName, arguments)

            case let .reasoning(reasoning):
                guard !completion.isFinished else { return }
                context.onReasoning?(context.callbackModel, reasoning)
            }
        }
    }
}
