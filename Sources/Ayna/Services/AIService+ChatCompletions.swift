import Foundation

extension AIService {
    static let uiTestLongStreamPrefix = "[long-stream]"

    struct TextRequestRoutingContext {
        let messages: [Message]
        let model: String
        let temperature: Double?
        let stream: Bool
        let tools: [[String: Any]]?
        let conversationId: UUID?
        let requestLane: AITextRequestLane
        let isMultiModelRequest: Bool
        let callbacks: StreamCallbacks
        let flightID: RequestFlightID
    }

    func performSendMessage(
        messages: [Message],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = true,
        tools: [[String: Any]]? = nil,
        conversationId: UUID? = nil,
        requestLane: AITextRequestLane = .foreground,
        isMultiModelRequest: Bool = false,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        requestFlightID: RequestFlightID? = nil
    ) -> AITextRequest {
        let flightID = requestFlightID ?? RequestFlightID()
        let requestHandle = AITextRequest(service: self, flightID: flightID)
        let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        let callbacks = StreamCallbacks(
            onChunk: onChunk,
            onComplete: onComplete,
            onError: onError,
            onToolCallRequested: onToolCallRequested,
            onReasoning: onReasoning
        )

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📤 sendMessage called",
            metadata: [
                "model": requestModel,
                "messagesCount": "\(messages.count)",
                "stream": "\(stream)",
                "hasTools": "\(tools != nil)",
                "toolCount": "\(tools?.count ?? 0)"
            ]
        )

        let context = TextRequestRoutingContext(
            messages: messages,
            model: requestModel,
            temperature: temperature,
            stream: stream,
            tools: tools,
            conversationId: conversationId,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            callbacks: callbacks,
            flightID: flightID
        )

        if handleSimulatedRequestIfNeeded(context) {
            return requestHandle
        }

        dispatchTextRequest(context)
        return requestHandle
    }

    private func handleSimulatedRequestIfNeeded(_ context: TextRequestRoutingContext) -> Bool {
        if let responseSimulator {
            let simulatedRequest = beginSimulatedTextRequest(
                flightID: context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.model
            )
            responseSimulator(
                context.messages,
                ownedSimulationCallbacks(
                    flightID: context.flightID,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    modelName: context.model,
                    requestHandle: simulatedRequest,
                    onChunk: context.callbacks.onChunk,
                    onComplete: context.callbacks.onComplete
                )
            )
            return true
        }

        if UITestEnvironment.isEnabled {
            simulateUITestResponse(context: context)
            return true
        }

        return false
    }

    private func dispatchTextRequest(_ context: TextRequestRoutingContext) {
        guard !context.model.isEmpty else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Model is empty"
            )
            context.callbacks.onError(AynaError.noModelSelected)
            return
        }

        let effectiveProvider: AIProvider
        do {
            effectiveProvider = try resolvedProvider(for: context.model)
        } catch {
            context.callbacks.onError(error)
            return
        }
        let endpointInfo = customEndpoint(for: context.model)
        let usesAzureEndpoint = endpointInfo.map { isAzureEndpoint($0.endpoint) } ?? false

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📤 Provider resolved",
            metadata: [
                "model": context.model,
                "provider": effectiveProvider.rawValue,
                "hasCustomEndpoint": "\(endpointInfo != nil)",
                "isAzure": "\(usesAzureEndpoint)"
            ]
        )

        if effectiveProvider == .appleIntelligence {
            dispatchAppleIntelligenceRequest(context)
            return
        }

        if effectiveProvider == .anthropic {
            let anthropicCallbacks = AIProviderStreamCallbacks(
                onChunk: context.callbacks.onChunk,
                onComplete: context.callbacks.onComplete,
                onError: context.callbacks.onError,
                onToolCallRequested: context.callbacks.onToolCallRequested,
                onReasoning: context.callbacks.onReasoning
            )
            handleAnthropicRequest(
                messages: context.messages,
                model: context.model,
                stream: context.stream,
                tools: context.tools,
                conversationId: context.conversationId,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                callbacks: anthropicCallbacks,
                flightID: context.flightID
            )
            return
        }

        do {
            try validateProviderSettings(for: effectiveProvider, model: context.model)
        } catch {
            context.callbacks.onError(error)
            return
        }

        let endpointType = modelEndpointTypes[context.model] ?? .chatCompletions
        if endpointType == .responses {
            responsesAPIRequest(
                messages: context.messages,
                model: context.model,
                tools: context.tools,
                conversationId: context.conversationId,
                callbacks: context.callbacks,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                initialFlightID: context.flightID
            )
            return
        }

        sendChatCompletionsRequest(
            context: context,
            effectiveProvider: effectiveProvider,
            usesAzureEndpoint: usesAzureEndpoint
        )
    }

    private func dispatchAppleIntelligenceRequest(_ context: TextRequestRoutingContext) {
        if context.messages.contains(where: { $0.attachments?.isEmpty == false }) {
            let error = AynaError.apiError(
                message: "Apple Intelligence does not support attachments. Choose a vision-capable cloud model."
            )
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "Apple Intelligence request rejected because it contains attachments",
                metadata: ["model": context.model]
            )
            context.callbacks.onError(error)
            return
        }

        #if !os(watchOS)
            if let service = injectedAppleIntelligenceService {
                handleAppleIntelligenceRequest(AppleIntelligenceRequestContext(
                    service: service,
                    messages: context.messages,
                    modelName: context.model,
                    temperature: context.temperature,
                    stream: context.stream,
                    conversationID: context.conversationId,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    onChunk: context.callbacks.onChunk,
                    onComplete: context.callbacks.onComplete,
                    onError: context.callbacks.onError
                ), flightID: context.flightID)
            } else if #available(macOS 26.0, iOS 26.0, *) {
                handleAppleIntelligenceRequest(AppleIntelligenceRequestContext(
                    service: AppleIntelligenceService.shared,
                    messages: context.messages,
                    modelName: context.model,
                    temperature: context.temperature,
                    stream: context.stream,
                    conversationID: context.conversationId,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    onChunk: context.callbacks.onChunk,
                    onComplete: context.callbacks.onComplete,
                    onError: context.callbacks.onError
                ), flightID: context.flightID)
            } else {
                context.callbacks.onError(AynaError.apiError(message: "Apple Intelligence requires macOS 26.0 or iOS 26.0 or later"))
            }
        #else
            context.callbacks.onError(AynaError.apiError(message: "Apple Intelligence is not available on Apple Watch"))
        #endif
    }

    private func sendChatCompletionsRequest(
        context: TextRequestRoutingContext,
        effectiveProvider: AIProvider,
        usesAzureEndpoint: Bool
    ) {
        let modelAPIKey = getAPIKey(for: context.model)
        let apiURL: String
        do {
            apiURL = try getAPIURL(deploymentName: context.model, provider: effectiveProvider)
        } catch {
            context.callbacks.onError(error)
            return
        }

        guard let url = URL(string: apiURL) else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Invalid URL",
                metadata: ["url": apiURL]
            )
            context.callbacks.onError(AynaError.invalidEndpoint(apiURL))
            return
        }

        let needsAuth = effectiveProvider == .openai
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📤 Building request",
            metadata: [
                "url": apiURL,
                "hasAPIKey": "\(!modelAPIKey.isEmpty)",
                "needsAuth": "\(needsAuth)"
            ]
        )

        let messagesWithMemory = buildMessagesWithMemory(
            from: context.messages,
            conversationId: context.conversationId
        )

        takeDataTask(
            flightID: context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model
        )?.cancel()
        if context.stream {
            takeStreamTask(
                flightID: context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.model
            )?.cancel()
        }

        let toolDefinitions = RequestBuilderToolDefinitions(context.tools)
        let supportsParallelToolCalls = usesAzureEndpoint ||
            url.host?.caseInsensitiveCompare("api.openai.com") == .orderedSame
        let buildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let request = await OpenAIRequestBuilder.createChatCompletionsRequestAsync(
                url: url,
                messages: messagesWithMemory,
                model: context.model,
                stream: context.stream,
                tools: toolDefinitions,
                apiKey: needsAuth ? modelAPIKey : "",
                isAzure: usesAzureEndpoint,
                supportsParallelToolCalls: supportsParallelToolCalls
            )

            guard self.clearRequestBuildFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.model
            ) else {
                return
            }

            guard let request else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "❌ Failed to create request"
                )
                context.callbacks.onError(AynaError.encodingFailed(detail: "Failed to build API request"))
                return
            }

            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "🌐 Starting stream request",
                metadata: [
                    "url": url.absoluteString,
                    "model": context.model,
                    "stream": "\(context.stream)"
                ]
            )

            if context.stream {
                self.streamResponse(
                    request: request,
                    callbacks: context.callbacks,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    modelName: context.model,
                    initialFlightID: context.flightID
                )
            } else {
                self.nonStreamResponse(
                    request: request,
                    modelName: context.model,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    callbacks: context.callbacks,
                    initialFlightID: context.flightID
                )
            }
        }
        installRequestBuildTask(
            buildTask,
            flightID: context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model
        )?.cancel()
    }

    func buildMessagesWithMemory(
        from messages: [Message],
        conversationId: UUID?
    ) -> [Message] {
        let systemPrompt = messages.first { $0.role == .system }?.content
        let conversationHistory = messages.filter { $0.role != .system }
        let memoryContext = MemoryContextProvider.shared.buildContext(
            currentConversationId: conversationId
        )
        return OpenAIRequestBuilder.buildMessagesWithMemory(
            systemPrompt: systemPrompt,
            memoryContext: memoryContext,
            conversationHistory: conversationHistory
        )
    }

    private func ownedSimulationCallbacks(
        flightID: RequestFlightID,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        modelName: String,
        requestHandle: SimulatedTextRequestHandle,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) -> AIServiceResponseSimulationCallbacks {
        AIServiceResponseSimulationCallbacks(
            onChunk: { [weak self] chunk in
                guard let self else { return }
                let ownsRequest = self.ownsSimulatedTextRequest(
                    flightID,
                    requestLane: requestLane,
                    isMultiModelRequest: isMultiModelRequest,
                    modelName: modelName
                )
                if isMultiModelRequest {
                    self.requestFlightObserver.record(.multiModelCallback, ownsRequest)
                }
                guard ownsRequest else { return }
                onChunk(chunk)
            },
            onComplete: { [weak self] in
                guard let self else { return }
                let finishedRequest = self.finishSimulatedTextRequest(
                    flightID,
                    requestLane: requestLane,
                    isMultiModelRequest: isMultiModelRequest,
                    modelName: modelName,
                    requestHandle: requestHandle
                )
                if isMultiModelRequest {
                    self.requestFlightObserver.record(.multiModelCallback, finishedRequest)
                }
                guard finishedRequest else { return }
                onComplete()
            }
        )
    }

    private func simulateUITestResponse(context: TextRequestRoutingContext) {
        let requestHandle = beginSimulatedTextRequest(
            flightID: context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model
        )
        let callbacks = ownedSimulationCallbacks(
            flightID: context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.model,
            requestHandle: requestHandle,
            onChunk: context.callbacks.onChunk,
            onComplete: context.callbacks.onComplete
        )
        let fallback = "Mock response"
        let userContent = context.messages.last(where: { $0.role == .user })?.content ?? fallback

        if userContent.starts(with: "Generate a very short title") {
            if let range = userContent.range(of: "starts with: \""),
               let endRange = userContent.range(of: "\". Only respond")
            {
                let content = String(userContent[range.upperBound ..< endRange.lowerBound])
                let title = String(content.prefix(50))
                callbacks.onChunk(title)
                callbacks.onComplete()
                return
            }
        }

        let response = "UI Test Response: \(userContent)"

        if context.stream, userContent.hasPrefix(Self.uiTestLongStreamPrefix) {
            let task = Task { @MainActor in
                for line in 1 ... 150 {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    callbacks.onChunk("Line \(line) of a long streamed reply.\n\n")
                }
                callbacks.onComplete()
            }
            requestHandle.install(task)
            return
        }

        if context.stream {
            let task = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                callbacks.onChunk(response)
                callbacks.onComplete()
            }
            requestHandle.install(task)
        } else {
            let task = Task { @MainActor in
                callbacks.onChunk(response)
                callbacks.onComplete()
            }
            requestHandle.install(task)
        }
    }
}
