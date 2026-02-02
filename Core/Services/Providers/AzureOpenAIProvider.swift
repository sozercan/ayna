//
//  AzureOpenAIProvider.swift
//  ayna
//
//  Created on 12/11/25.
//

import Foundation
import os

/// Provider implementation for Azure OpenAI Service
///
/// Handles:
/// - Azure OpenAI deployments with api-key authentication
/// - Azure-specific URL formatting with deployment names
/// - API version management
///
/// Note: This provider extends OpenAIProvider functionality but uses
/// Azure-specific authentication (api-key header instead of Bearer token)
@MainActor
final class AzureOpenAIProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .openai // Azure is an OpenAI variant
    let requiresAPIKey: Bool = true

    private let urlSession: URLSession
    private var currentStreamTask: Task<Void, Never>?

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
        guard let customEndpoint = config.customEndpoint,
              OpenAIEndpointResolver.isAzureEndpoint(customEndpoint)
        else {
            callbacks.onError(AynaError.invalidEndpoint("Invalid Azure URL"))
            return
        }

        let apiURL = resolveEndpointURL(config: config)

        guard let url = URL(string: apiURL) else {
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "❌ Invalid Azure URL",
                metadata: ["url": apiURL]
            )
            callbacks.onError(AynaError.invalidEndpoint("Invalid Azure URL"))
            return
        }

        guard let request = OpenAIRequestBuilder.createChatCompletionsRequest(
            url: url,
            messages: messages,
            model: config.model,
            stream: stream,
            tools: tools,
            apiKey: config.apiKey,
            isAzure: true,
            isGitHubModels: false
        ) else {
            callbacks.onError(AynaError.missingConfiguration(detail: "Failed to build API request"))
            return
        }

        let circuitKey = NetworkCircuitBreaker.key(for: url, label: "azure.chat")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Service temporarily unavailable. Please try again in \(seconds)s."
                : "Service temporarily unavailable. Please try again shortly."
            callbacks.onError(AynaError.apiError(message: message))
            return
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🌐 AzureOpenAIProvider: Starting request",
            metadata: [
                "url": url.absoluteString,
                "model": config.model,
                "stream": "\(stream)"
            ]
        )

        if stream {
            streamResponse(request: request, callbacks: callbacks, circuitKey: circuitKey)
        } else {
            nonStreamResponse(request: request, callbacks: callbacks, circuitKey: circuitKey)
        }
    }

    func cancelRequest() {
        currentStreamTask?.cancel()
        currentStreamTask = nil
    }

    // MARK: - Private Methods

    private func resolveEndpointURL(config: AIProviderRequestConfig) -> String {
        let endpointConfig = OpenAIEndpointResolver.EndpointConfig(
            modelName: config.model,
            provider: .openai,
            customEndpoint: config.customEndpoint,
            azureAPIVersion: config.azureAPIVersion
        )
        return OpenAIEndpointResolver.chatCompletionsURL(for: endpointConfig)
    }

    private func streamResponse(
        request: URLRequest,
        callbacks: AIProviderStreamCallbacks,
        circuitKey: String,
        attempt: Int = 0
    ) {
        currentStreamTask?.cancel()

        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Service temporarily unavailable. Please try again in \(seconds)s."
                : "Service temporarily unavailable. Please try again shortly."
            callbacks.onError(AynaError.apiError(message: message))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            var hasReceivedData = false

            do {
                try await withTaskCancellationHandler {
                    let (bytes, response) = try await urlSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AynaError.invalidResponse(detail: nil)
                    }

                    guard httpResponse.statusCode == 200 else {
                        let errorMessage = await handleHTTPError(
                            bytes: bytes,
                            statusCode: httpResponse.statusCode,
                            request: request
                        )

                        if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                            NetworkCircuitBreaker.recordFailure(key: circuitKey)
                        }

                        throw AynaError.apiError(message: errorMessage)
                    }

                    NetworkCircuitBreaker.recordSuccess(key: circuitKey)

                    var buffer = Data()
                    var currentToolCallBuffer: [String: Any] = [:]
                    var toolCallId = ""
                    var contentBuffer = ""
                    var reasoningBuffer = ""
                    var lastUpdateTime = CFAbsoluteTimeGetCurrent()

                    // Maximum line length to prevent OOM from malformed streams without newlines
                    let maxLineLength = 65536 // 64KB

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        hasReceivedData = true
                        buffer.append(byte)

                        // Prevent unbounded buffer growth from malformed streams
                        if buffer.count > maxLineLength {
                            throw AynaError.apiError(message: "Malformed stream: line exceeds maximum length")
                        }

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
                        .aiService,
                        level: .info,
                        message: "AzureOpenAIProvider: Stream task cancelled"
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
        attempt: Int = 0
    ) {
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Service temporarily unavailable. Please try again in \(seconds)s."
                : "Service temporarily unavailable. Please try again shortly."
            callbacks.onError(AynaError.apiError(message: message))
            return
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
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
                    callbacks.onError(AynaError.invalidResponse(detail: nil))
                    return
                }

                guard let data else {
                    callbacks.onError(AynaError.invalidResponse(detail: nil))
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                        NetworkCircuitBreaker.recordFailure(key: circuitKey)
                    }
                    let message = self?.extractAPIErrorMessage(from: data, statusCode: httpResponse.statusCode)
                        ?? "HTTP \(httpResponse.statusCode)"
                    callbacks.onError(AynaError.apiError(message: message))
                    return
                }

                NetworkCircuitBreaker.recordSuccess(key: circuitKey)

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let errorDict = json?["error"] as? [String: Any],
                       let message = errorDict["message"] as? String
                    {
                        callbacks.onError(AynaError.apiError(message: message))
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
                                source: "nonstream.azure",
                                metadata: ["phase": "final"]
                            )
                            for segment in textSegments where !segment.isEmpty {
                                callbacks.onChunk(segment)
                            }
                        }

                        callbacks.onComplete()
                    } else {
                        callbacks.onError(AynaError.invalidResponse(detail: nil))
                    }
                } catch {
                    callbacks.onError(error)
                }
            }
        }
        task.resume()
    }

    // MARK: - Error Handling

    private func handleHTTPError(bytes: URLSession.AsyncBytes, statusCode: Int, request _: URLRequest) async -> String {
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
            return extractAPIErrorMessage(from: errorData, statusCode: statusCode)
        }

        return getHTTPErrorMessage(statusCode: statusCode)
    }

    private nonisolated func getHTTPErrorMessage(statusCode: Int) -> String {
        switch statusCode {
        case 400:
            "HTTP \(statusCode) - Invalid Azure deployment or API version."
        case 401:
            "HTTP \(statusCode) - Invalid API key. Check your Azure OpenAI key."
        case 403:
            "HTTP \(statusCode) - Access denied. Check your Azure OpenAI permissions."
        case 404:
            "HTTP \(statusCode) - Deployment not found. Check your Azure deployment name."
        case 429:
            "Too many requests. Please wait a minute before trying again."
        case 500, 502, 503, 504:
            "Server error (\(statusCode)). Please try again in a moment."
        default:
            "HTTP \(statusCode)"
        }
    }

    private nonisolated func extractAPIErrorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(200))
        }

        return getHTTPErrorMessage(statusCode: statusCode)
    }

    private func handleStreamError(
        error: Error,
        attempt: Int,
        hasReceivedData: Bool,
        request: URLRequest,
        callbacks: AIProviderStreamCallbacks,
        circuitKey: String
    ) async {
        if shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData) {
            await delay(for: attempt)
            await MainActor.run {
                streamResponse(request: request, callbacks: callbacks, circuitKey: circuitKey, attempt: attempt + 1)
            }
        } else {
            await MainActor.run {
                self.currentStreamTask = nil
                if let urlError = error as? URLError, urlError.code == .timedOut {
                    callbacks.onError(AynaError.apiError(message:
                        "Request timed out. The model may be slow or overloaded. Please try again."))
                } else if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
                    callbacks.onError(AynaError.apiError(message:
                        "Network connection was lost. The server may have rejected the request."))
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
        AIRetryPolicy.shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData)
    }

    private func delay(for attempt: Int) async {
        await AIRetryPolicy.wait(for: attempt)
    }
}
