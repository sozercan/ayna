import Foundation

extension AIService {
    private struct StreamExecutionContext: Sendable {
        let request: URLRequest
        let callbacks: StreamCallbacks
        let attempt: Int
        let requestLane: AITextRequestLane
        let isMultiModelRequest: Bool
        let modelName: String?
        let flightID: RequestFlightID
    }

    private struct NonStreamExecutionContext: Sendable {
        let request: URLRequest
        let modelName: String
        let requestLane: AITextRequestLane
        let isMultiModelRequest: Bool
        let callbacks: StreamCallbacks
        let attempt: Int
        let flightID: RequestFlightID
    }

    private struct StreamParseState {
        var buffer = Data()
        var toolCallBuffers: [Int: [String: Any]] = [:]
        var toolCallIds: [Int: String] = [:]
        var contentBuffer = ""
        var reasoningBuffer = ""
        var totalBytesReceived = 0
        var hasReceivedData = false
    }

    nonisolated func httpStatusError(
        response: URLResponse?,
        data: Data?,
        requestURL: URL?
    ) -> HTTPStatusError? {
        guard let httpResponse = response as? HTTPURLResponse,
              !(200 ... 299).contains(httpResponse.statusCode)
        else {
            return nil
        }
        let message = if let data, !data.isEmpty {
            extractAPIErrorMessage(from: data, statusCode: httpResponse.statusCode)
        } else {
            getHTTPErrorMessage(statusCode: httpResponse.statusCode, requestURL: requestURL)
        }
        return HTTPStatusError(statusCode: httpResponse.statusCode, message: message, response: httpResponse)
    }

    nonisolated func getHTTPErrorMessage(statusCode: Int, requestURL: URL?) -> String {
        switch statusCode {
        case 400:
            if requestURL?.absoluteString.lowercased().contains("openai.azure.com") == true {
                return "HTTP \(statusCode) - Invalid Azure deployment or API version (\(azureAPIVersion))."
            }
            return "HTTP \(statusCode) - Invalid request. Check your model name and parameters."
        case 429:
            return "Too many requests. Please wait a minute before trying again."
        case 403:
            return "HTTP \(statusCode) - Forbidden. Check your API key permissions."
        case 500, 502, 503, 504:
            return "Server error (\(statusCode)). Please try again in a moment."
        default:
            return "HTTP \(statusCode)"
        }
    }

    nonisolated func extractAPIErrorMessage(from data: Data, statusCode: Int) -> String {
        if statusCode == 429 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                if message.lowercased().contains("rate") || message.lowercased().contains("limit") {
                    return "Too many requests. Please wait a minute before trying again."
                }
                return message
            }
            return "Too many requests. Please wait a minute before trying again."
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
            if let errorDesc = json["error_description"] as? String {
                return errorDesc
            }
            if let error = json["error"] as? String {
                return error
            }
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(200))
        }
        return "HTTP \(statusCode)"
    }

    @discardableResult
    private func deliverStreamBuffers(
        content: String,
        reasoning: String,
        context: StreamExecutionContext,
        terminal: Bool
    ) -> Bool {
        guard ownsStreamFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.modelName
        ) else {
            return false
        }

        if !content.isEmpty {
            context.callbacks.onChunk(content)
            guard ownsStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            ) else {
                return false
            }
        }

        if !reasoning.isEmpty {
            context.callbacks.onReasoning?(reasoning)
            guard ownsStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            ) else {
                return false
            }
        }

        if terminal {
            guard clearStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            ) else {
                return false
            }
            context.callbacks.onComplete()
        }
        return true
    }

    func streamResponse(
        request: URLRequest,
        callbacks: StreamCallbacks,
        attempt: Int = 0,
        requestLane: AITextRequestLane = .foreground,
        isMultiModelRequest: Bool = false,
        modelName: String? = nil,
        initialFlightID: RequestFlightID? = nil,
        existingFlightID: RequestFlightID? = nil
    ) {
        let session = urlSession
        let flightID = existingFlightID ?? initialFlightID ?? RequestFlightID()

        if existingFlightID != nil {
            guard ownsStreamFlight(
                flightID,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            ) else {
                return
            }
        } else {
            let previousTask = takeStreamTask(
                flightID: flightID,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            )
            if previousTask != nil, !isMultiModelRequest {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "⚠️ Cancelling existing stream task before starting new one"
                )
            }
            previousTask?.cancel()
        }

        let context = StreamExecutionContext(
            request: request,
            callbacks: callbacks,
            attempt: attempt,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName,
            flightID: flightID
        )

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🔄 Creating new stream task",
            metadata: ["url": request.url?.absoluteString ?? "unknown"]
        )

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.executeStreamTask(session: session, context: context)
        }
        guard installStreamTask(
            task,
            flightID: flightID,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName,
            requiresExistingOwner: existingFlightID != nil
        ) else {
            task.cancel()
            return
        }
    }

    private nonisolated func executeStreamTask(
        session: URLSession,
        context: StreamExecutionContext
    ) async {
        var parseState = StreamParseState()

        do {
            try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: context.request)
                try await validateStreamHTTPResponse(
                    response: response,
                    bytes: bytes,
                    requestURL: context.request.url
                )
                let guardedToolCall = makeGuardedToolCallHandler(context: context)
                let completedEarly = try await consumeStreamBytes(
                    bytes,
                    state: &parseState,
                    context: context,
                    guardedToolCall: guardedToolCall
                )
                guard !completedEarly else { return }
                try await flushRemainingStreamBuffer(
                    state: &parseState,
                    context: context,
                    guardedToolCall: guardedToolCall
                )
                await finalizeStream(state: parseState, context: context)
            } onCancel: {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "Stream task cancellation handler triggered"
                )
            }
        } catch {
            await handleStreamError(
                error: error,
                hasReceivedData: parseState.hasReceivedData,
                context: context
            )
        }
    }

    private nonisolated func validateStreamHTTPResponse(
        response: URLResponse,
        bytes: URLSession.AsyncBytes,
        requestURL: URL?
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Invalid response type"
            )
            throw AynaError.invalidResponse(detail: nil)
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📥 HTTP response received",
            metadata: [
                "statusCode": "\(httpResponse.statusCode)",
                "url": requestURL?.absoluteString ?? "unknown"
            ]
        )

        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            do {
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count > 4096 {
                        break
                    }
                }
            } catch {}

            let errorMessage: String = if !errorData.isEmpty {
                extractAPIErrorMessage(from: errorData, statusCode: httpResponse.statusCode)
            } else {
                await MainActor.run {
                    self.getHTTPErrorMessage(
                        statusCode: httpResponse.statusCode,
                        requestURL: requestURL
                    )
                }
            }

            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ API error response",
                metadata: [
                    "statusCode": "\(httpResponse.statusCode)",
                    "error": errorMessage,
                    "url": requestURL?.absoluteString ?? "unknown"
                ]
            )
            throw HTTPStatusError(
                statusCode: httpResponse.statusCode,
                message: errorMessage,
                response: httpResponse
            )
        }
    }

    private nonisolated func makeGuardedToolCallHandler(
        context: StreamExecutionContext
    ) -> (@Sendable (String, String, [String: Any]) -> Void)? {
        guard let onToolCallRequested = context.callbacks.onToolCallRequested else {
            return nil
        }
        return { [weak self] toolCallID, toolName, arguments in
            let arguments = UncheckedSendableWrapper(arguments)
            MainActor.assumeIsolated {
                guard let self,
                      !Task.isCancelled,
                      self.ownsStreamFlight(
                          context.flightID,
                          requestLane: context.requestLane,
                          isMultiModelRequest: context.isMultiModelRequest,
                          modelName: context.modelName
                      )
                else {
                    return
                }
                onToolCallRequested(toolCallID, toolName, arguments.value)
            }
        }
    }

    private nonisolated func consumeStreamBytes(
        _ bytes: URLSession.AsyncBytes,
        state: inout StreamParseState,
        context: StreamExecutionContext,
        guardedToolCall: (@Sendable (String, String, [String: Any]) -> Void)?
    ) async throws -> Bool {
        let maxLineLength = 65536

        for try await byte in bytes {
            try Task.checkCancellation()

            state.hasReceivedData = true
            state.totalBytesReceived += 1
            state.buffer.append(byte)

            if state.buffer.count > maxLineLength {
                throw AynaError.apiError(message: "Malformed stream: line exceeds maximum length")
            }

            if state.totalBytesReceived == 1 {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "📦 First byte received from stream"
                )
            }

            if byte == 0x0A {
                if let line = String(data: state.buffer, encoding: .utf8) {
                    let completed = try await processStreamLineAndDeliver(
                        line,
                        state: &state,
                        context: context,
                        guardedToolCall: guardedToolCall
                    )
                    if completed {
                        return true
                    }
                }
                state.buffer.removeAll()
            }
        }
        return false
    }

    private nonisolated func processStreamLineAndDeliver(
        _ line: String,
        state: inout StreamParseState,
        context: StreamExecutionContext,
        guardedToolCall: (@Sendable (String, String, [String: Any]) -> Void)?
    ) async throws -> Bool {
        let ownsFlight = await MainActor.run {
            self.ownsStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            )
        }
        guard ownsFlight else { throw CancellationError() }

        let result = await OpenAIStreamParser.processStreamLine(
            line,
            toolCallBuffers: state.toolCallBuffers,
            toolCallIds: state.toolCallIds,
            onToolCallRequested: guardedToolCall
        )
        let ownsAfterParser = await MainActor.run {
            self.ownsStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            )
        }
        guard ownsAfterParser else { throw CancellationError() }
        try Task.checkCancellation()

        state.toolCallBuffers = result.toolCallBuffers
        state.toolCallIds = result.toolCallIds

        if let content = result.content {
            state.contentBuffer += content
        }
        if let reasoning = result.reasoning {
            state.reasoningBuffer += reasoning
        }

        if result.shouldComplete {
            let contentToSend = state.contentBuffer
            let reasoningToSend = state.reasoningBuffer
            _ = await MainActor.run {
                self.deliverStreamBuffers(
                    content: contentToSend,
                    reasoning: reasoningToSend,
                    context: context,
                    terminal: true
                )
            }
            return true
        }

        if !state.contentBuffer.isEmpty || !state.reasoningBuffer.isEmpty {
            let contentToSend = state.contentBuffer
            let reasoningToSend = state.reasoningBuffer
            let delivered = await MainActor.run {
                self.deliverStreamBuffers(
                    content: contentToSend,
                    reasoning: reasoningToSend,
                    context: context,
                    terminal: false
                )
            }
            guard delivered else { return true }
            state.contentBuffer = ""
            state.reasoningBuffer = ""
        }

        return false
    }

    private nonisolated func flushRemainingStreamBuffer(
        state: inout StreamParseState,
        context: StreamExecutionContext,
        guardedToolCall: (@Sendable (String, String, [String: Any]) -> Void)?
    ) async throws {
        guard !state.buffer.isEmpty, let line = String(data: state.buffer, encoding: .utf8) else {
            return
        }
        let ownsFlight = await MainActor.run {
            self.ownsStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            )
        }
        guard ownsFlight else { throw CancellationError() }
        let result = await OpenAIStreamParser.processStreamLine(
            line,
            toolCallBuffers: state.toolCallBuffers,
            toolCallIds: state.toolCallIds,
            onToolCallRequested: guardedToolCall
        )
        state.toolCallBuffers = result.toolCallBuffers
        state.toolCallIds = result.toolCallIds
        if let content = result.content {
            state.contentBuffer += content
        }
        if let reasoning = result.reasoning {
            state.reasoningBuffer += reasoning
        }
        state.buffer.removeAll()
    }

    private nonisolated func finalizeStream(
        state: StreamParseState,
        context: StreamExecutionContext
    ) async {
        let contentToSend = state.contentBuffer
        let reasoningToSend = state.reasoningBuffer
        let receivedData = state.hasReceivedData
        let bytesReceived = state.totalBytesReceived
        await MainActor.run {
            guard self.ownsStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            ) else {
                return
            }

            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "📊 Stream ended",
                metadata: [
                    "totalBytesReceived": "\(bytesReceived)",
                    "hasReceivedData": "\(receivedData)",
                    "contentBufferLength": "\(contentToSend.count)",
                    "reasoningBufferLength": "\(reasoningToSend.count)"
                ]
            )

            if !receivedData {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "⚠️ Stream completed with no data received",
                    metadata: ["url": context.request.url?.absoluteString ?? "unknown"]
                )
            }

            self.deliverStreamBuffers(
                content: contentToSend,
                reasoning: reasoningToSend,
                context: context,
                terminal: true
            )
        }
    }

    private nonisolated func isStreamCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    private func handleStreamError(
        error: Error,
        hasReceivedData: Bool,
        context: StreamExecutionContext
    ) async {
        if isStreamCancellation(error) {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "Stream task cancelled"
            )
            let cleared = clearStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            )
            requestFlightObserver.record(.streamCancellation, cleared)
            return
        }

        guard ownsStreamFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.modelName
        ) else {
            return
        }

        if shouldRetry(error: error, attempt: context.attempt, hasReceivedData: hasReceivedData) {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "⚠️ Retrying stream request (attempt \(context.attempt + 1))",
                metadata: ["error": error.localizedDescription]
            )
            await delay(for: context.attempt, retryAfterDate: AIRetryPolicy.retryAfterDate(for: error))
            let ownsFlight = ownsStreamFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            )
            requestFlightObserver.record(.streamRetry, ownsFlight)
            guard ownsFlight else { return }
            streamResponse(
                request: context.request,
                callbacks: context.callbacks,
                attempt: context.attempt + 1,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName,
                existingFlightID: context.flightID
            )
            return
        }

        guard clearStreamFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.modelName
        ) else {
            return
        }

        if let urlError = error as? URLError, urlError.code == .timedOut {
            context.callbacks.onError(AynaError.timeout)
        } else if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
            context.callbacks.onError(AynaError.networkError(underlying: urlError))
        } else {
            context.callbacks.onError(error)
        }
    }

    func nonStreamResponse(
        request: URLRequest,
        modelName: String,
        requestLane: AITextRequestLane,
        isMultiModelRequest: Bool,
        callbacks: StreamCallbacks,
        attempt: Int = 0,
        initialFlightID: RequestFlightID? = nil,
        existingFlightID: RequestFlightID? = nil
    ) {
        let flightID = existingFlightID ?? initialFlightID ?? RequestFlightID()
        let context = NonStreamExecutionContext(
            request: request,
            modelName: modelName,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            callbacks: callbacks,
            attempt: attempt,
            flightID: flightID
        )

        if existingFlightID == nil {
            let previousTask = takeDataTask(
                flightID: flightID,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            )
            previousTask?.cancel()
        } else {
            guard ownsDataFlight(
                flightID,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                modelName: modelName
            ) else {
                return
            }
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, transportError in
            let selfRef = self
            Task { @MainActor in
                guard let self = selfRef else { return }
                self.handleNonStreamTaskResult(
                    data: data,
                    response: response,
                    transportError: transportError,
                    context: context
                )
            }
        }

        guard installDataTask(
            task,
            flightID: flightID,
            requestLane: requestLane,
            isMultiModelRequest: isMultiModelRequest,
            modelName: modelName,
            requiresExistingOwner: existingFlightID != nil
        ) else {
            task.cancel()
            return
        }
        task.resume()
    }

    private func handleNonStreamTaskResult(
        data: Data?,
        response: URLResponse?,
        transportError: Error?,
        context: NonStreamExecutionContext
    ) {
        let ownsFlight = ownsDataFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.modelName
        )
        requestFlightObserver.record(.dataCallback, ownsFlight)
        guard ownsFlight else { return }

        let error = transportError ?? httpStatusError(
            response: response,
            data: data,
            requestURL: context.request.url
        )

        if let error {
            handleNonStreamError(error, context: context)
            return
        }

        guard let data else {
            finishNonStreamWithError(AynaError.invalidResponse(detail: nil), context: context)
            return
        }

        deliverNonStreamPayload(data: data, context: context)
    }

    private func handleNonStreamError(_ error: Error, context: NonStreamExecutionContext) {
        if shouldRetry(error: error, attempt: context.attempt) {
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "⚠️ Retrying non-stream request (attempt \(context.attempt + 1))",
                metadata: ["error": error.localizedDescription]
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.delay(for: context.attempt, retryAfterDate: AIRetryPolicy.retryAfterDate(for: error))
                let ownsFlight = self.ownsDataFlight(
                    context.flightID,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    modelName: context.modelName
                )
                self.requestFlightObserver.record(.dataRetry, ownsFlight)
                guard ownsFlight else { return }
                self.nonStreamResponse(
                    request: context.request,
                    modelName: context.modelName,
                    requestLane: context.requestLane,
                    isMultiModelRequest: context.isMultiModelRequest,
                    callbacks: context.callbacks,
                    attempt: context.attempt + 1,
                    existingFlightID: context.flightID
                )
            }
            return
        }
        finishNonStreamWithError(error, context: context)
    }

    private func deliverNonStreamPayload(data: Data, context: NonStreamExecutionContext) {
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let errorDict = json?["error"] as? [String: Any],
               let message = errorDict["message"] as? String
            {
                finishNonStreamWithError(AynaError.apiError(message: message), context: context)
                return
            }

            guard let choices = json?["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any]
            else {
                finishNonStreamWithError(AynaError.invalidResponse(detail: nil), context: context)
                return
            }

            guard deliverNonStreamChoiceMessage(message, json: json, context: context) else {
                return
            }

            guard clearDataFlight(
                context.flightID,
                requestLane: context.requestLane,
                isMultiModelRequest: context.isMultiModelRequest,
                modelName: context.modelName
            ) else {
                return
            }
            context.callbacks.onComplete()
        } catch {
            finishNonStreamWithError(error, context: context)
        }
    }

    private func deliverNonStreamChoiceMessage(
        _ message: [String: Any],
        json: [String: Any]?,
        context: NonStreamExecutionContext
    ) -> Bool {
        if let reasoning = extractNonStreamReasoning(message: message, json: json),
           let onReasoning = context.callbacks.onReasoning
        {
            onReasoning(reasoning)
            guard ownsNonStreamFlight(context) else { return false }
        }

        if let contentField = message["content"], !(contentField is NSNull) {
            let textSegments = OpenAIStreamParser.extractTextSegments(
                from: contentField,
                source: "nonstream.chat",
                metadata: ["phase": "final"]
            )
            for segment in textSegments where !segment.isEmpty {
                guard ownsNonStreamFlight(context) else { return false }
                context.callbacks.onChunk(segment)
            }
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let onToolCallRequested = context.callbacks.onToolCallRequested
        {
            for toolCall in toolCalls {
                guard ownsNonStreamFlight(context) else { return false }
                if let id = toolCall["id"] as? String,
                   let function = toolCall["function"] as? [String: Any],
                   let name = function["name"] as? String,
                   let argsString = function["arguments"] as? String,
                   let argsData = argsString.data(using: .utf8),
                   let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    onToolCallRequested(id, name, arguments)
                }
            }
        }

        return true
    }

    private func extractNonStreamReasoning(message: [String: Any], json: [String: Any]?) -> String? {
        if let reasoning = message["reasoning"] as? String {
            return reasoning
        }
        if let reasoning = message["reasoning_content"] as? String {
            return reasoning
        }
        if let usage = json?["usage"] as? [String: Any],
           let details = usage["completion_tokens_details"] as? [String: Any],
           let reasoningTokens = details["reasoning_tokens"] as? Int,
           reasoningTokens > 0
        {
            return "💭 Reasoning tokens used: \(reasoningTokens)"
        }
        return nil
    }

    private func ownsNonStreamFlight(_ context: NonStreamExecutionContext) -> Bool {
        ownsDataFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.modelName
        )
    }

    private func finishNonStreamWithError(_ error: Error, context: NonStreamExecutionContext) {
        guard clearDataFlight(
            context.flightID,
            requestLane: context.requestLane,
            isMultiModelRequest: context.isMultiModelRequest,
            modelName: context.modelName
        ) else {
            return
        }
        context.callbacks.onError(error)
    }
}
