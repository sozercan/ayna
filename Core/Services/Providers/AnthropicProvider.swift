//
//  AnthropicProvider.swift
//  ayna
//
//  Created on 1/30/26.
//

import Foundation
import os

/// Provider implementation for Anthropic (Claude) API
///
/// Handles:
/// - Direct Anthropic API (api.anthropic.com)
/// - Custom endpoints (Azure, proxies)
/// - Extended thinking with streaming thinking blocks
/// - Tool use for MCP integration
/// - Vision/image attachments
@MainActor
final class AnthropicProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .anthropic
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
        // Resolve endpoint URL
        let url: URL
        do {
            url = try AnthropicEndpointResolver.messagesURL(customEndpoint: config.customEndpoint)
        } catch {
            DiagnosticsLogger.log(
                .anthropicService,
                level: .error,
                message: "❌ Invalid Anthropic endpoint",
                metadata: ["error": error.localizedDescription]
            )
            callbacks.onError(error)
            return
        }

        let circuitKey = NetworkCircuitBreaker.key(for: url, label: "anthropic.messages")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Anthropic service temporarily unavailable. Please try again in \(seconds)s."
                : "Anthropic service temporarily unavailable. Please try again shortly."
            callbacks.onError(AynaError.apiError(message: message))
            return
        }

        // Determine beta headers based on model
        var betaHeaders: [String] = []
        if let thinkingBudget = config.thinkingBudget, thinkingBudget >= 1024 {
            // Enable interleaved thinking for Claude 4+ models
            let model = config.model.lowercased()
            if model.contains("claude-4") || model.contains("claude-opus-4") || model.contains("claude-sonnet-4") {
                betaHeaders.append("interleaved-thinking-2025-05-14")
            }
        }

        // Build request configuration
        let requestConfig = AnthropicRequestConfig(
            model: config.model,
            apiKey: config.apiKey,
            customEndpoint: config.customEndpoint,
            maxTokens: config.maxTokens ?? 4096,
            budgetTokens: config.thinkingBudget,
            betaHeaders: betaHeaders
        )

        // Build request
        var request: URLRequest
        do {
            request = try AnthropicRequestBuilder.createMessagesRequest(
                url: url,
                messages: messages,
                config: requestConfig,
                stream: stream,
                tools: tools
            )
        } catch {
            DiagnosticsLogger.log(
                .anthropicService,
                level: .error,
                message: "❌ Failed to build Anthropic request",
                metadata: ["error": error.localizedDescription]
            )
            callbacks.onError(error)
            return
        }

        // Set timeout
        request.timeoutInterval = 120

        DiagnosticsLogger.log(
            .anthropicService,
            level: .info,
            message: "🌐 AnthropicProvider: Starting request",
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

    // MARK: - Streaming Response

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
                ? "Anthropic service temporarily unavailable. Please try again in \(seconds)s."
                : "Anthropic service temporarily unavailable. Please try again shortly."
            callbacks.onError(AynaError.apiError(message: message))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            var hasReceivedData = false

            DiagnosticsLogger.log(
                .anthropicService,
                level: .debug,
                message: "🚀 Starting stream task",
                metadata: ["url": request.url?.absoluteString ?? "(nil)"]
            )

            do {
                try await withTaskCancellationHandler {
                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .debug,
                        message: "📡 Awaiting stream response..."
                    )
                    let (bytes, response) = try await urlSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        DiagnosticsLogger.log(
                            .anthropicService,
                            level: .error,
                            message: "❌ Invalid response type from Anthropic"
                        )
                        throw AynaError.apiError(message: "Invalid Anthropic response")
                    }

                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .info,
                        message: "📥 Anthropic HTTP response received",
                        metadata: ["statusCode": "\(httpResponse.statusCode)"]
                    )

                    guard httpResponse.statusCode == 200 else {
                        let errorMessage = await handleHTTPError(
                            bytes: bytes,
                            statusCode: httpResponse.statusCode
                        )

                        DiagnosticsLogger.log(
                            .anthropicService,
                            level: .error,
                            message: "❌ Anthropic API error",
                            metadata: [
                                "statusCode": "\(httpResponse.statusCode)",
                                "error": errorMessage
                            ]
                        )

                        if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                            NetworkCircuitBreaker.recordFailure(key: circuitKey)
                        }

                        throw AynaError.apiError(message: errorMessage)
                    }

                    NetworkCircuitBreaker.recordSuccess(key: circuitKey)

                    // Create parser without direct callbacks - we batch updates instead
                    // The parser returns content/reasoning in the result, and we flush via flushBuffers
                    let parser = AnthropicStreamParser(
                        onChunk: nil, // Don't call directly, use buffered approach
                        onReasoning: nil, // Don't call directly, use buffered approach
                        onToolCallRequested: { id, name, input in
                            callbacks.onToolCallRequested?(id, name, input)
                        },
                        onComplete: nil, // We handle completion in the main loop
                        onError: { error in callbacks.onError(error) }
                    )

                    var buffer = Data()
                    var contentBuffer = ""
                    var reasoningBuffer = ""
                    var lastUpdateTime = CFAbsoluteTimeGetCurrent()
                    var lineCount = 0

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if !hasReceivedData {
                            DiagnosticsLogger.log(
                                .anthropicService,
                                level: .debug,
                                message: "📥 First byte received in stream"
                            )
                        }
                        hasReceivedData = true
                        buffer.append(byte)

                        // Process line when we hit newline
                        if byte == 0x0A {
                            lineCount += 1
                            if let line = String(data: buffer, encoding: .utf8) {
                                if lineCount <= 5 || lineCount % 50 == 0 {
                                    DiagnosticsLogger.log(
                                        .anthropicService,
                                        level: .debug,
                                        message: "📜 Processing SSE line",
                                        metadata: [
                                            "lineNumber": "\(lineCount)",
                                            "preview": String(line.prefix(80))
                                        ]
                                    )
                                }
                                let result = parser.processLine(line)

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
                        .anthropicService,
                        level: .info,
                        message: "AnthropicProvider: Stream task cancelled"
                    )
                }
            } catch is CancellationError {
                DiagnosticsLogger.log(
                    .anthropicService,
                    level: .info,
                    message: "🛑 Stream cancelled"
                )
                await MainActor.run { self.currentStreamTask = nil }
            } catch {
                DiagnosticsLogger.log(
                    .anthropicService,
                    level: .error,
                    message: "❌ Stream error caught",
                    metadata: [
                        "error": error.localizedDescription,
                        "type": String(describing: type(of: error))
                    ]
                )
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

    // MARK: - Non-Streaming Response

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
                ? "Anthropic service temporarily unavailable. Please try again in \(seconds)s."
                : "Anthropic service temporarily unavailable. Please try again shortly."
            callbacks.onError(AynaError.apiError(message: message))
            return
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                if let error {
                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .error,
                        message: "❌ Anthropic network error (non-stream)",
                        metadata: ["error": error.localizedDescription]
                    )
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
                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .error,
                        message: "❌ Invalid response type (non-stream)"
                    )
                    callbacks.onError(AynaError.apiError(message: "Invalid Anthropic response"))
                    return
                }

                DiagnosticsLogger.log(
                    .anthropicService,
                    level: .info,
                    message: "📥 Anthropic HTTP response received (non-stream)",
                    metadata: ["statusCode": "\(httpResponse.statusCode)"]
                )

                guard let data else {
                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .error,
                        message: "❌ Empty response data (non-stream)"
                    )
                    callbacks.onError(AynaError.apiError(message: "Empty Anthropic response"))
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                        NetworkCircuitBreaker.recordFailure(key: circuitKey)
                    }
                    let message = self?.extractAPIErrorMessage(from: data, statusCode: httpResponse.statusCode)
                        ?? "HTTP \(httpResponse.statusCode)"

                    // Log raw response body for debugging auth errors
                    let rawBody = String(data: data, encoding: .utf8) ?? "(non-UTF8 data)"
                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .error,
                        message: "❌ Anthropic API error (non-stream)",
                        metadata: [
                            "statusCode": "\(httpResponse.statusCode)",
                            "error": message,
                            "rawBody": String(rawBody.prefix(500))
                        ]
                    )
                    callbacks.onError(AynaError.apiError(message: message))
                    return
                }

                NetworkCircuitBreaker.recordSuccess(key: circuitKey)

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    // Debug: Log raw response structure
                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .debug,
                        message: "📦 Anthropic response parsed",
                        metadata: [
                            "type": json?["type"] as? String ?? "(nil)",
                            "hasContent": "\(json?["content"] != nil)",
                            "contentType": "\(type(of: json?["content"] ?? "(nil)"))",
                            "keys": json?.keys.joined(separator: ", ") ?? "(nil)"
                        ]
                    )

                    // Check for error response
                    if let errorType = json?["type"] as? String, errorType == "error" {
                        let errorObj = json?["error"] as? [String: Any]
                        let message = errorObj?["message"] as? String ?? "Anthropic API error"
                        callbacks.onError(AynaError.apiError(message: message))
                        return
                    }

                    // Parse content blocks
                    if let content = json?["content"] as? [[String: Any]] {
                        DiagnosticsLogger.log(
                            .anthropicService,
                            level: .debug,
                            message: "📄 Parsing content blocks",
                            metadata: ["blockCount": "\(content.count)"]
                        )

                        for block in content {
                            guard let blockType = block["type"] as? String else { continue }

                            switch blockType {
                            case "text":
                                if let text = block["text"] as? String {
                                    DiagnosticsLogger.log(
                                        .anthropicService,
                                        level: .debug,
                                        message: "📝 Text block received",
                                        metadata: ["length": "\(text.count)"]
                                    )
                                    callbacks.onChunk(text)
                                }
                            case "thinking":
                                if let thinking = block["thinking"] as? String {
                                    callbacks.onReasoning?(thinking)
                                }
                            case "tool_use":
                                if let toolId = block["id"] as? String,
                                   let toolName = block["name"] as? String,
                                   let toolInput = block["input"] as? [String: Any]
                                {
                                    callbacks.onToolCallRequested?(toolId, toolName, toolInput)
                                }
                            default:
                                DiagnosticsLogger.log(
                                    .anthropicService,
                                    level: .debug,
                                    message: "⚠️ Unknown block type",
                                    metadata: ["type": blockType]
                                )
                                break
                            }
                        }
                    } else {
                        DiagnosticsLogger.log(
                            .anthropicService,
                            level: .error,
                            message: "⚠️ No content array in response"
                        )
                    }

                    DiagnosticsLogger.log(
                        .anthropicService,
                        level: .debug,
                        message: "✅ Non-stream response complete"
                    )
                    callbacks.onComplete()
                } catch {
                    callbacks.onError(error)
                }
            }
        }
        task.resume()
    }

    // MARK: - Error Handling

    private func handleHTTPError(bytes: URLSession.AsyncBytes, statusCode: Int) async -> String {
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
            "Anthropic: Invalid request. Check your model name and parameters."
        case 401:
            "Anthropic API key invalid or missing."
        case 403:
            "Anthropic: Forbidden. Check your API key permissions."
        case 404:
            "Anthropic: Model not found. Check your model name."
        case 429:
            "Anthropic: Too many requests. Please wait before trying again."
        case 500, 502, 503, 504:
            "Anthropic server error (\(statusCode)). Please try again in a moment."
        case 529:
            "Anthropic: API is overloaded. Please try again later."
        default:
            "Anthropic: HTTP \(statusCode)"
        }
    }

    private nonisolated func extractAPIErrorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Anthropic error format: {"type": "error", "error": {"type": "...", "message": "..."}}
            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String
            {
                // Add Anthropic prefix for clarity
                if statusCode == 401 {
                    return "Anthropic API key invalid or missing."
                }
                if statusCode == 429 {
                    return "Anthropic: Too many requests. Please wait before trying again."
                }
                return "Anthropic: \(message)"
            }
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return "Anthropic: \(String(text.prefix(200)))"
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
                        "Anthropic request timed out. The model may be slow or overloaded. Please try again."))
                } else if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
                    callbacks.onError(AynaError.apiError(message:
                        "Network connection was lost. The Anthropic server may have rejected the request."))
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
