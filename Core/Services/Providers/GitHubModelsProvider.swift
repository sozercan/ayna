//
//  GitHubModelsProvider.swift
//  ayna
//
//  Created on 12/11/25.
//

import Foundation

/// Provider implementation for GitHub Models API
///
/// Handles:
/// - GitHub Models inference API (models.github.ai)
/// - OAuth token authentication
/// - Rate limit tracking
@MainActor
final class GitHubModelsProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .githubModels
    let requiresAPIKey: Bool = true

    private let urlSession: URLSession
    private var currentStreamTask: Task<Void, Never>?

    private static let chatCompletionsURL = "https://models.github.ai/inference/chat/completions"

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    func sendMessage(
        messages: [Message],
        config: AIProviderRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    ) {
        // Check rate limit before making request
        if let rateLimitError = checkRateLimit(accessToken: config.apiKey) {
            callbacks.onError(OpenAIService.OpenAIError.apiError(rateLimitError))
            return
        }

        guard let url = URL(string: Self.chatCompletionsURL) else {
            callbacks.onError(OpenAIService.OpenAIError.invalidURL)
            return
        }

        let circuitKey = NetworkCircuitBreaker.key(for: url, label: "github.models.chat")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Service temporarily unavailable. Please try again in \(seconds)s."
                : "Service temporarily unavailable. Please try again shortly."
            callbacks.onError(OpenAIService.OpenAIError.apiError(message))
            return
        }

        guard let request = OpenAIRequestBuilder.createChatCompletionsRequest(
            url: url,
            messages: messages,
            model: config.model,
            stream: stream,
            tools: tools,
            apiKey: config.apiKey,
            isAzure: false,
            isGitHubModels: true
        ) else {
            callbacks.onError(OpenAIService.OpenAIError.invalidRequest)
            return
        }

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "🌐 GitHubModelsProvider: Starting request",
            metadata: [
                "url": url.absoluteString,
                "model": config.model,
                "stream": "\(stream)"
            ]
        )

        if stream {
            streamResponse(request: request, callbacks: callbacks, circuitKey: circuitKey, accessToken: config.apiKey)
        } else {
            nonStreamResponse(request: request, callbacks: callbacks, circuitKey: circuitKey, accessToken: config.apiKey)
        }
    }

    func cancelRequest() {
        currentStreamTask?.cancel()
        currentStreamTask = nil
    }

    // MARK: - Rate Limit Handling

    private func checkRateLimit(accessToken: String) -> String? {
        guard !accessToken.isEmpty else { return nil }
        let oauthService = GitHubOAuthService.shared

        if let retryAfter = oauthService.retryAfterDate(forAccessToken: accessToken), retryAfter > Date() {
            let secondsRemaining = Int(retryAfter.timeIntervalSinceNow)
            if secondsRemaining > 60 {
                let minutesRemaining = secondsRemaining / 60
                return "Rate limited. Please wait \(minutesRemaining) minute\(minutesRemaining == 1 ? "" : "s")."
            } else if secondsRemaining > 0 {
                return "Rate limited. Please wait \(secondsRemaining) second\(secondsRemaining == 1 ? "" : "s")."
            }
        }

        if let rateLimitInfo = oauthService.rateLimitInfo(forAccessToken: accessToken), rateLimitInfo.isExhausted {
            return "Rate limit exhausted. Resets \(rateLimitInfo.formattedReset)."
        }

        return nil
    }

    private func updateRateLimitFromResponse(_ response: HTTPURLResponse, accessToken: String, errorData: Data? = nil) {
        guard !accessToken.isEmpty else { return }
        GitHubOAuthService.shared.updateRateLimit(from: response, forAccessToken: accessToken)

        let statusCode = response.statusCode
        if statusCode == 429 || (statusCode == 403 && isRateLimitErrorBody(errorData)) {
            GitHubOAuthService.shared.updateRetryAfter(from: response, forAccessToken: accessToken)
        } else if statusCode == 200 {
            GitHubOAuthService.shared.clearRetryAfter(forAccessToken: accessToken)
        }
    }

    private nonisolated func isRateLimitErrorBody(_ data: Data?) -> Bool {
        guard let data, let errorString = String(data: data, encoding: .utf8) else { return false }
        let lowercased = errorString.lowercased()
        return lowercased.contains("rate limit") ||
            lowercased.contains("rate_limit") ||
            lowercased.contains("too many requests") ||
            lowercased.contains("ratelimit")
    }

    // MARK: - Streaming

    private func streamResponse(
        request: URLRequest,
        callbacks: AIProviderStreamCallbacks,
        circuitKey: String,
        accessToken: String,
        attempt: Int = 0
    ) {
        currentStreamTask?.cancel()

        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Service temporarily unavailable. Please try again in \(seconds)s."
                : "Service temporarily unavailable. Please try again shortly."
            callbacks.onError(OpenAIService.OpenAIError.apiError(message))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            var hasReceivedData = false

            do {
                try await withTaskCancellationHandler {
                    let (bytes, response) = try await urlSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenAIService.OpenAIError.invalidResponse
                    }

                    guard httpResponse.statusCode == 200 else {
                        let (errorMessage, errorData) = await handleHTTPError(
                            bytes: bytes,
                            statusCode: httpResponse.statusCode,
                            httpResponse: httpResponse
                        )
                        await MainActor.run {
                            self.updateRateLimitFromResponse(httpResponse, accessToken: accessToken, errorData: errorData)
                        }

                        if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                            NetworkCircuitBreaker.recordFailure(key: circuitKey)
                        }

                        throw OpenAIService.OpenAIError.apiError(errorMessage)
                    }

                    // Update rate limit on success
                    await MainActor.run {
                        self.updateRateLimitFromResponse(httpResponse, accessToken: accessToken)
                    }

                    NetworkCircuitBreaker.recordSuccess(key: circuitKey)

                    var buffer = Data()
                    var currentToolCallBuffer: [String: Any] = [:]
                    var toolCallId = ""
                    var contentBuffer = ""
                    var reasoningBuffer = ""
                    var lastUpdateTime = CFAbsoluteTimeGetCurrent()

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        hasReceivedData = true
                        buffer.append(byte)

                        if byte == 0x0A {
                            if let line = String(data: buffer, encoding: .utf8) {
                                let streamCallbacks = StreamCallbacks(
                                    onChunk: callbacks.onChunk,
                                    onComplete: callbacks.onComplete,
                                    onError: callbacks.onError,
                                    onToolCall: callbacks.onToolCall,
                                    onToolCallRequested: callbacks.onToolCallRequested,
                                    onReasoning: callbacks.onReasoning
                                )

                                let result = await OpenAIStreamParser.processStreamLine(
                                    line,
                                    toolCallBuffer: currentToolCallBuffer,
                                    toolCallId: toolCallId,
                                    onToolCall: streamCallbacks.onToolCall,
                                    onToolCallRequested: streamCallbacks.onToolCallRequested
                                )
                                currentToolCallBuffer = result.toolCallBuffer
                                toolCallId = result.toolCallId

                                if let content = result.content {
                                    contentBuffer += content
                                }
                                if let reasoning = result.reasoning {
                                    reasoningBuffer += reasoning
                                }

                                if result.shouldComplete {
                                    await flushBuffers(
                                        contentBuffer: contentBuffer,
                                        reasoningBuffer: reasoningBuffer,
                                        callbacks: callbacks
                                    )
                                    await MainActor.run {
                                        self.currentStreamTask = nil
                                        callbacks.onComplete()
                                    }
                                    return
                                }

                                // Batch updates
                                if !contentBuffer.isEmpty || !reasoningBuffer.isEmpty {
                                    let timeSinceLastUpdate = CFAbsoluteTimeGetCurrent() - lastUpdateTime
                                    if timeSinceLastUpdate > 0.05 || contentBuffer.count > 100 || reasoningBuffer.count > 100 {
                                        await flushBuffers(
                                            contentBuffer: contentBuffer,
                                            reasoningBuffer: reasoningBuffer,
                                            callbacks: callbacks
                                        )
                                        contentBuffer = ""
                                        reasoningBuffer = ""
                                        lastUpdateTime = CFAbsoluteTimeGetCurrent()
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }

                    // Flush remaining content
                    await flushBuffers(
                        contentBuffer: contentBuffer,
                        reasoningBuffer: reasoningBuffer,
                        callbacks: callbacks
                    )
                    await MainActor.run {
                        self.currentStreamTask = nil
                        callbacks.onComplete()
                    }
                } onCancel: {
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .info,
                        message: "GitHubModelsProvider: Stream task cancelled"
                    )
                }
            } catch is CancellationError {
                await MainActor.run { self.currentStreamTask = nil }
            } catch {
                if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }
                await handleStreamError(
                    error: error,
                    attempt: attempt,
                    hasReceivedData: hasReceivedData,
                    request: request,
                    callbacks: callbacks,
                    accessToken: accessToken,
                    circuitKey: circuitKey
                )
            }
        }
        currentStreamTask = task
    }

    private func nonStreamResponse(
        request: URLRequest,
        callbacks: AIProviderStreamCallbacks,
        circuitKey: String,
        accessToken: String,
        attempt: Int = 0
    ) {
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Service temporarily unavailable. Please try again in \(seconds)s."
                : "Service temporarily unavailable. Please try again shortly."
            callbacks.onError(OpenAIService.OpenAIError.apiError(message))
            return
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                if let httpResponse = response as? HTTPURLResponse {
                    self?.updateRateLimitFromResponse(httpResponse, accessToken: accessToken, errorData: data)
                }

                if let error {
                    if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                        NetworkCircuitBreaker.recordFailure(key: circuitKey)
                    }
                    if self?.shouldRetry(error: error, attempt: attempt) == true {
                        Task {
                            await self?.delay(for: attempt)
                            await MainActor.run {
                                self?.nonStreamResponse(
                                    request: request,
                                    callbacks: callbacks,
                                    circuitKey: circuitKey,
                                    accessToken: accessToken,
                                    attempt: attempt + 1
                                )
                            }
                        }
                        return
                    }
                    callbacks.onError(error)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    callbacks.onError(OpenAIService.OpenAIError.invalidResponse)
                    return
                }

                guard let data else {
                    callbacks.onError(OpenAIService.OpenAIError.invalidResponse)
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                        NetworkCircuitBreaker.recordFailure(key: circuitKey)
                    }
                    let message = self?.extractAPIErrorMessage(from: data, statusCode: httpResponse.statusCode)
                        ?? "HTTP \(httpResponse.statusCode)"
                    callbacks.onError(OpenAIService.OpenAIError.apiError(message))
                    return
                }

                NetworkCircuitBreaker.recordSuccess(key: circuitKey)

                if !accessToken.isEmpty {
                    GitHubOAuthService.shared.clearRetryAfter(forAccessToken: accessToken)
                }

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let errorDict = json?["error"] as? [String: Any],
                       let message = errorDict["message"] as? String
                    {
                        callbacks.onError(OpenAIService.OpenAIError.apiError(message))
                        return
                    }

                    if let choices = json?["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any]
                    {
                        // Handle reasoning
                        if let reasoning = message["reasoning"] as? String ?? message["reasoning_content"] as? String {
                            callbacks.onReasoning?(reasoning)
                        }

                        // Handle content
                        if let contentField = message["content"], !(contentField is NSNull) {
                            let textSegments = OpenAIStreamParser.extractTextSegments(
                                from: contentField,
                                source: "nonstream.github",
                                metadata: ["phase": "final"]
                            )
                            for segment in textSegments where !segment.isEmpty {
                                callbacks.onChunk(segment)
                            }
                        }

                        callbacks.onComplete()
                    } else {
                        callbacks.onError(OpenAIService.OpenAIError.invalidResponse)
                    }
                } catch {
                    callbacks.onError(error)
                }
            }
        }
        task.resume()
    }

    // MARK: - Error Handling

    private func handleHTTPError(
        bytes: URLSession.AsyncBytes,
        statusCode: Int,
        httpResponse _: HTTPURLResponse
    ) async -> (String, Data?) {
        var errorData = Data()
        do {
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 4096 { break }
            }
        } catch {
            // Ignore errors reading error body
        }

        if !errorData.isEmpty {
            return (extractAPIErrorMessage(from: errorData, statusCode: statusCode), errorData)
        }

        return (getHTTPErrorMessage(statusCode: statusCode), nil)
    }

    private nonisolated func getHTTPErrorMessage(statusCode: Int) -> String {
        switch statusCode {
        case 400:
            "HTTP \(statusCode) - Invalid request. Check your model name and parameters."
        case 429:
            "Too many requests. Please wait a minute before trying again."
        case 403:
            "Rate limit exceeded. GitHub Models has usage limits. Please wait a few minutes."
        case 500, 502, 503, 504:
            "Server error (\(statusCode)). Please try again in a moment."
        default:
            "HTTP \(statusCode)"
        }
    }

    private nonisolated func extractAPIErrorMessage(from data: Data, statusCode: Int) -> String {
        if statusCode == 429 || statusCode == 403 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                if message.lowercased().contains("rate") || message.lowercased().contains("limit") {
                    return "Rate limit exceeded. Please wait a few minutes before trying again."
                }
                return message
            }
            if statusCode == 429 {
                return "Too many requests. Please wait a minute before trying again."
            }
            return "Rate limit exceeded. GitHub Models has usage limits. Please wait a few minutes."
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

    private func handleStreamError(
        error: Error,
        attempt: Int,
        hasReceivedData: Bool,
        request: URLRequest,
        callbacks: AIProviderStreamCallbacks,
        accessToken: String,
        circuitKey: String
    ) async {
        let retryAfterDate = accessToken.isEmpty
            ? nil
            : await MainActor.run { GitHubOAuthService.shared.retryAfterDate(forAccessToken: accessToken) }

        if shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData) {
            await delay(for: attempt, retryAfterDate: retryAfterDate)
            await MainActor.run {
                streamResponse(
                    request: request,
                    callbacks: callbacks,
                    circuitKey: circuitKey,
                    accessToken: accessToken,
                    attempt: attempt + 1
                )
            }
        } else {
            await MainActor.run {
                self.currentStreamTask = nil
                if let urlError = error as? URLError, urlError.code == .timedOut {
                    callbacks.onError(OpenAIService.OpenAIError.apiError(
                        "Request timed out. The model may be slow or overloaded. Please try again."
                    ))
                } else if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
                    callbacks.onError(OpenAIService.OpenAIError.apiError(
                        "Network connection was lost. The server may have rejected the request."
                    ))
                } else if error is CancellationError {
                    // Task was cancelled, don't report as error
                } else {
                    callbacks.onError(error)
                }
            }
        }
    }

    private func flushBuffers(
        contentBuffer: String,
        reasoningBuffer: String,
        callbacks: AIProviderStreamCallbacks
    ) async {
        await MainActor.run {
            if !contentBuffer.isEmpty { callbacks.onChunk(contentBuffer) }
            if !reasoningBuffer.isEmpty { callbacks.onReasoning?(reasoningBuffer) }
        }
    }

    // MARK: - Retry Logic

    private func shouldRetry(error: Error, attempt: Int, hasReceivedData: Bool = false) -> Bool {
        OpenAIRetryPolicy.shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData)
    }

    private func delay(for attempt: Int, retryAfterDate: Date? = nil) async {
        await OpenAIRetryPolicy.wait(for: attempt, retryAfterDate: retryAfterDate)
    }
}
