//
//  OpenAIProvider.swift
//  ayna
//
//  Created on 12/11/25.
//

import Foundation

/// Provider implementation for OpenAI and Azure OpenAI APIs
///
/// Handles:
/// - Standard OpenAI API (api.openai.com)
/// - Azure OpenAI deployments
/// - Custom OpenAI-compatible endpoints
@MainActor
final class OpenAIProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .openai
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
        let apiURL = resolveEndpointURL(config: config)

        guard let url = URL(string: apiURL) else {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "❌ Invalid URL",
                metadata: ["url": apiURL]
            )
            callbacks.onError(OpenAIService.OpenAIError.invalidURL)
            return
        }

        let usesAzureEndpoint = OpenAIEndpointResolver.isAzureEndpoint(config.customEndpoint)

        guard let request = OpenAIRequestBuilder.createChatCompletionsRequest(
            url: url,
            messages: messages,
            model: config.model,
            stream: stream,
            tools: tools,
            apiKey: config.apiKey,
            isAzure: usesAzureEndpoint,
            isGitHubModels: false
        ) else {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "❌ Failed to create request"
            )
            callbacks.onError(OpenAIService.OpenAIError.invalidRequest)
            return
        }

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "🌐 OpenAIProvider: Starting request",
            metadata: [
                "url": url.absoluteString,
                "model": config.model,
                "stream": "\(stream)",
                "isAzure": "\(usesAzureEndpoint)"
            ]
        )

        if stream {
            streamResponse(request: request, callbacks: callbacks)
        } else {
            nonStreamResponse(request: request, callbacks: callbacks)
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

    private func streamResponse(request: URLRequest, callbacks: AIProviderStreamCallbacks, attempt: Int = 0) {
        currentStreamTask?.cancel()

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
                        let errorMessage = await handleHTTPError(
                            bytes: bytes,
                            statusCode: httpResponse.statusCode,
                            request: request
                        )
                        throw OpenAIService.OpenAIError.apiError(errorMessage)
                    }

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
                        message: "OpenAIProvider: Stream task cancelled"
                    )
                }
            } catch is CancellationError {
                await MainActor.run { self.currentStreamTask = nil }
            } catch {
                await handleStreamError(
                    error: error,
                    attempt: attempt,
                    hasReceivedData: hasReceivedData,
                    request: request,
                    callbacks: callbacks
                )
            }
        }
        currentStreamTask = task
    }

    private func nonStreamResponse(request: URLRequest, callbacks: AIProviderStreamCallbacks, attempt: Int = 0) {
        let task = urlSession.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                if let error {
                    if self?.shouldRetry(error: error, attempt: attempt) == true {
                        Task {
                            await self?.delay(for: attempt)
                            await MainActor.run {
                                self?.nonStreamResponse(request: request, callbacks: callbacks, attempt: attempt + 1)
                            }
                        }
                        return
                    }
                    callbacks.onError(error)
                    return
                }

                guard let data else {
                    callbacks.onError(OpenAIService.OpenAIError.invalidResponse)
                    return
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
                                source: "nonstream.openai",
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

    private func handleHTTPError(bytes: URLSession.AsyncBytes, statusCode: Int, request: URLRequest) async -> String {
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

        return getHTTPErrorMessage(statusCode: statusCode, requestURL: request.url)
    }

    private nonisolated func getHTTPErrorMessage(statusCode: Int, requestURL: URL?) -> String {
        switch statusCode {
        case 400:
            if requestURL?.absoluteString.lowercased().contains("openai.azure.com") == true {
                return "HTTP \(statusCode) - Invalid Azure deployment or API version."
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

    private nonisolated func extractAPIErrorMessage(from data: Data, statusCode: Int) -> String {
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
        callbacks: AIProviderStreamCallbacks
    ) async {
        if shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData) {
            await delay(for: attempt)
            await MainActor.run {
                streamResponse(request: request, callbacks: callbacks, attempt: attempt + 1)
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

    private func delay(for attempt: Int) async {
        await OpenAIRetryPolicy.wait(for: attempt)
    }
}
