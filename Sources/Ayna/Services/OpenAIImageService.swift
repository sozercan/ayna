//
//  OpenAIImageService.swift
//  ayna
//
//  Created on 11/24/25.
//

import Foundation
import os

/// Service responsible for image generation via OpenAI-compatible APIs.
/// Handles both standard OpenAI and Azure OpenAI image endpoints.
final class OpenAIImageService: @unchecked Sendable {
    private struct RequestHandleState: Sendable {
        var isActive = true
        var cancellations: [@Sendable () -> Void] = []
    }

    private struct GenerationContext: Sendable {
        let requestHandle: RequestHandle
        let onComplete: @Sendable (Data) -> Void
        let onError: @Sendable (Error) -> Void
    }

    /// Owns every transport and retry spawned by one logical image request.
    ///
    /// The handle is installed by `AIService` before the request starts so Stop can
    /// synchronously fence callbacks, cancel an active URLSession task, and prevent
    /// a retry or image download from starting after cancellation.
    final class RequestHandle: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: RequestHandleState())

        var isActive: Bool {
            state.withLock { $0.isActive }
        }

        func resume(_ task: URLSessionTask) {
            let shouldResume = state.withLock { state -> Bool in
                guard state.isActive else { return false }
                state.cancellations.append { task.cancel() }
                return true
            }

            if shouldResume {
                task.resume()
            } else {
                task.cancel()
            }
        }

        func run(_ operation: @escaping @Sendable () async -> Void) {
            let task = Task {
                guard !Task.isCancelled else { return }
                await operation()
            }
            let shouldContinue = state.withLock { state -> Bool in
                guard state.isActive else { return false }
                state.cancellations.append { task.cancel() }
                return true
            }
            if !shouldContinue {
                task.cancel()
            }
        }

        func finish() {
            state.withLock { state in
                state.isActive = false
                state.cancellations.removeAll()
            }
        }

        func cancel() {
            let cancellations = state.withLock { state -> [@Sendable () -> Void] in
                guard state.isActive else { return [] }
                state.isActive = false
                defer { state.cancellations.removeAll() }
                return state.cancellations
            }
            cancellations.forEach { $0() }
        }
    }

    // MARK: - Configuration

    struct ImageConfig {
        let size: String
        let quality: String
        let outputFormat: String
        let outputCompression: Int

        static let `default` = ImageConfig(
            size: "1024x1024",
            quality: "medium",
            outputFormat: "png",
            outputCompression: 100
        )
    }

    struct RequestConfig {
        let model: String
        let apiKey: String
        let provider: AIProvider
        let customEndpoint: String?
        let azureAPIVersion: String
    }

    // MARK: - Properties

    private let urlSession: URLSession
    private let retryDelay: @Sendable (Int) async -> Void

    // MARK: - Initialization

    init(
        urlSession: URLSession? = nil,
        retryDelay: @escaping @Sendable (Int) async -> Void = { attempt in
            await AIRetryPolicy.wait(for: attempt)
        }
    ) {
        self.retryDelay = retryDelay
        if let session = urlSession {
            self.urlSession = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 300
            self.urlSession = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// Generates an image from a text prompt.
    /// - Parameters:
    ///   - prompt: The text description of the image to generate
    ///   - requestConfig: Configuration for the API request (model, key, endpoint)
    ///   - imageConfig: Image generation settings (size, quality)
    ///   - onComplete: Callback with the generated image data
    ///   - onError: Callback with any error that occurred
    ///   - attempt: Current retry attempt (internal use)
    func generateImage(
        prompt: String,
        requestConfig: RequestConfig,
        imageConfig: ImageConfig = .default,
        requestHandle: RequestHandle,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        attempt: Int = 0
    ) {
        // Validate provider
        guard requestConfig.provider == .openai else {
            onError(AynaError.unsupportedProvider(provider: requestConfig.provider.rawValue, operation: "image generation"))
            return
        }

        // Validate API key only for OpenAI-hosted and Azure endpoints. Custom OpenAI-compatible
        // image proxies may intentionally rely on local/network authentication instead.
        guard !requestConfig.requiresAPIKey || !requestConfig.apiKey.isEmpty else {
            onError(AynaError.missingAPIKey(provider: "OpenAI"))
            return
        }

        // Resolve endpoint URL
        let endpointConfig = OpenAIEndpointResolver.EndpointConfig(
            modelName: requestConfig.model,
            provider: requestConfig.provider,
            customEndpoint: requestConfig.customEndpoint,
            azureAPIVersion: requestConfig.azureAPIVersion
        )
        let imageURL: String
        do {
            imageURL = try OpenAIEndpointResolver.imageGenerationURL(for: endpointConfig)
        } catch {
            onError(error)
            return
        }

        guard let url = URL(string: imageURL) else {
            onError(AynaError.invalidEndpoint(imageURL))
            return
        }

        // Build request
        let usesAzureEndpoint = OpenAIEndpointResolver.isAzureEndpoint(requestConfig.customEndpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set authentication header when required/configured.
        if usesAzureEndpoint {
            request.setValue(requestConfig.apiKey, forHTTPHeaderField: "api-key")
        } else if !requestConfig.apiKey.isEmpty {
            request.setValue("Bearer \(requestConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Build request body
        let body: [String: Any] = if usesAzureEndpoint {
            [
                "prompt": prompt,
                "size": imageConfig.size,
                "quality": imageConfig.quality,
                "n": 1
            ]
        } else {
            [
                "prompt": prompt,
                "model": requestConfig.model,
                "size": imageConfig.size,
                "quality": imageConfig.quality,
                "n": 1,
                "response_format": "b64_json"
            ]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onError(error)
            return
        }

        // Execute request
        let context = GenerationContext(
            requestHandle: requestHandle,
            onComplete: onComplete,
            onError: onError
        )
        executeRequest(request, context: context, attempt: attempt)
    }

    // MARK: - Private Methods

    private func executeRequest(
        _ request: URLRequest,
        context: GenerationContext,
        attempt: Int
    ) {
        let requestHandle = context.requestHandle
        guard requestHandle.isActive else { return }

        let circuitKey = NetworkCircuitBreaker.key(for: request.url, label: "openai.image")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Image generation temporarily unavailable. Please try again in \(seconds)s."
                : "Image generation temporarily unavailable. Please try again shortly."
            requestHandle.run { @MainActor in
                guard requestHandle.isActive else { return }
                context.onError(AynaError.apiError(message: message))
            }
            return
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard requestHandle.isActive else { return }

            if let error {
                if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }
                self?.handleError(
                    error,
                    request: request,
                    context: context,
                    attempt: attempt
                )
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    context.onError(AynaError.invalidResponse(detail: nil))
                }
                return
            }

            guard let data else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "No data received from image generation"
                )
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    context.onError(AynaError.invalidResponse(detail: "No data received"))
                }
                return
            }

            guard httpResponse.statusCode == 200 else {
                if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }

                let message: String = {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorDict = json["error"] as? [String: Any],
                       let errorMessage = errorDict["message"] as? String
                    {
                        return errorMessage
                    }
                    return "HTTP \(httpResponse.statusCode)"
                }()

                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    context.onError(AynaError.apiError(message: message))
                }
                return
            }

            NetworkCircuitBreaker.recordSuccess(key: circuitKey)

            self?.parseResponse(data, context: context)
        }
        requestHandle.resume(task)
    }

    private func handleError(
        _ error: Error,
        request: URLRequest,
        context: GenerationContext,
        attempt: Int
    ) {
        let requestHandle = context.requestHandle
        let retryDelay = retryDelay
        requestHandle.run { @MainActor [weak self] in
            guard requestHandle.isActive else { return }
            if AIRetryPolicy.shouldRetry(error: error, attempt: attempt) {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "⚠️ Retrying image generation (attempt \(attempt + 1))",
                    metadata: ["error": error.localizedDescription]
                )
                await retryDelay(attempt)
                guard requestHandle.isActive, !Task.isCancelled else { return }
                self?.executeRequest(request, context: context, attempt: attempt + 1)
                return
            }
            context.onError(error)
        }
    }

    private func parseResponse(
        _ data: Data,
        context: GenerationContext
    ) {
        let requestHandle = context.requestHandle
        guard requestHandle.isActive else { return }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    context.onError(AynaError.invalidResponse(detail: nil))
                }
                return
            }

            // Check for error response
            if let errorDict = json["error"] as? [String: Any],
               let code = errorDict["code"] as? String,
               let message = errorDict["message"] as? String
            {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "API error in image generation",
                    metadata: ["code": code, "message": message]
                )
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    if code == "contentFilter" {
                        context.onError(AynaError.contentFiltered(reason: message))
                    } else {
                        context.onError(AynaError.apiError(message: message))
                    }
                }
                return
            }

            guard let dataArray = json["data"] as? [[String: Any]],
                  let firstItem = dataArray.first
            else {
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    context.onError(AynaError.invalidResponse(detail: nil))
                }
                return
            }

            if let b64String = firstItem["b64_json"] as? String,
               let imageData = Data(base64Encoded: b64String)
            {
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    context.onComplete(imageData)
                }
                return
            }

            if let urlString = firstItem["url"] as? String,
               let url = URL(string: urlString)
            {
                downloadImage(from: url, context: context)
                return
            }

            requestHandle.run { @MainActor in
                guard requestHandle.isActive else { return }
                context.onError(AynaError.invalidResponse(detail: nil))
            }
        } catch {
            requestHandle.run { @MainActor in
                guard requestHandle.isActive else { return }
                context.onError(error)
            }
        }
    }

    private func downloadImage(
        from url: URL,
        context: GenerationContext,
        attempt: Int = 0
    ) {
        let requestHandle = context.requestHandle
        requestHandle.run { [weak self] in
            guard let self, requestHandle.isActive else { return }
            do {
                let (imageData, response) = try await self.urlSession.data(from: url)
                guard requestHandle.isActive, !Task.isCancelled else { return }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.handleDownloadError(
                        AynaError.invalidResponse(detail: "Image download returned no HTTP response"),
                        url: url,
                        context: context,
                        attempt: attempt
                    )
                    return
                }
                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    self.handleDownloadError(
                        AynaError.httpError(statusCode: httpResponse.statusCode, message: nil),
                        url: url,
                        context: context,
                        attempt: attempt
                    )
                    return
                }
                guard !imageData.isEmpty else {
                    self.handleDownloadError(
                        AynaError.invalidResponse(detail: "Image download returned empty data"),
                        url: url,
                        context: context,
                        attempt: attempt
                    )
                    return
                }
                guard Self.isSupportedImageData(imageData) else {
                    self.handleDownloadError(
                        AynaError.invalidResponse(detail: "Image download returned unsupported data"),
                        url: url,
                        context: context,
                        attempt: attempt
                    )
                    return
                }
                await MainActor.run {
                    guard requestHandle.isActive else { return }
                    context.onComplete(imageData)
                }
            } catch let error as CancellationError {
                guard requestHandle.isActive else { return }
                self.handleDownloadError(error, url: url, context: context, attempt: attempt)
            } catch let error as URLError where error.code == .cancelled {
                guard requestHandle.isActive else { return }
                self.handleDownloadError(error, url: url, context: context, attempt: attempt)
            } catch {
                self.handleDownloadError(error, url: url, context: context, attempt: attempt)
            }
        }
    }

    private func handleDownloadError(
        _ error: Error,
        url: URL,
        context: GenerationContext,
        attempt: Int
    ) {
        let requestHandle = context.requestHandle
        let retryDelay = retryDelay
        requestHandle.run { @MainActor [weak self] in
            guard requestHandle.isActive else { return }
            if AIRetryPolicy.shouldRetry(error: error, attempt: attempt) {
                await retryDelay(attempt)
                guard requestHandle.isActive, !Task.isCancelled else { return }
                self?.downloadImage(from: url, context: context, attempt: attempt + 1)
                return
            }
            context.onError(error)
        }
    }

    private static func isSupportedImageData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return true
        }
        if bytes.count >= 4,
           bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47
        {
            return true
        }
        if bytes.count >= 4,
           bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38
        {
            return true
        }
        return bytes.count >= 12 &&
            bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
            bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50
    }

    // MARK: - Image Editing

    /// Edits an image based on a prompt and source image.
    /// Uses the /v1/images/edits endpoint to modify existing images.
    /// - Parameters:
    ///   - prompt: The text description of the desired edit
    ///   - sourceImage: The source image data to edit (PNG format recommended)
    ///   - requestConfig: Configuration for the API request (model, key, endpoint)
    ///   - imageConfig: Image generation settings (size, quality)
    ///   - onComplete: Callback with the edited image data
    ///   - onError: Callback with any error that occurred
    func editImage(
        prompt: String,
        sourceImage: Data,
        requestConfig: RequestConfig,
        imageConfig: ImageConfig = .default,
        requestHandle: RequestHandle,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        // Validate provider
        guard requestConfig.provider == .openai else {
            onError(AynaError.unsupportedProvider(provider: requestConfig.provider.rawValue, operation: "image generation"))
            return
        }

        // Validate API key only for OpenAI-hosted and Azure endpoints. Custom OpenAI-compatible
        // image proxies may intentionally rely on local/network authentication instead.
        guard !requestConfig.requiresAPIKey || !requestConfig.apiKey.isEmpty else {
            onError(AynaError.missingAPIKey(provider: "OpenAI"))
            return
        }

        // Resolve endpoint URL
        let endpointConfig = OpenAIEndpointResolver.EndpointConfig(
            modelName: requestConfig.model,
            provider: requestConfig.provider,
            customEndpoint: requestConfig.customEndpoint,
            azureAPIVersion: requestConfig.azureAPIVersion
        )
        let editURL: String
        do {
            editURL = try OpenAIEndpointResolver.imageEditURL(for: endpointConfig)
        } catch {
            onError(error)
            return
        }

        guard let url = URL(string: editURL) else {
            onError(AynaError.invalidEndpoint(editURL))
            return
        }

        // Build multipart form request
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Set authentication header when required/configured.
        let usesAzureEndpoint = OpenAIEndpointResolver.isAzureEndpoint(requestConfig.customEndpoint)
        if usesAzureEndpoint {
            request.setValue(requestConfig.apiKey, forHTTPHeaderField: "api-key")
        } else if !requestConfig.apiKey.isEmpty {
            request.setValue("Bearer \(requestConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Build multipart body
        var body = Data()

        // Add image field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image[]\"; filename=\"image.png\"\r\n".utf8))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        body.append(sourceImage)
        body.append(Data("\r\n".utf8))

        // Add prompt field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".utf8))
        body.append(Data(prompt.utf8))
        body.append(Data("\r\n".utf8))

        // Add model field (not needed for Azure - deployment is in URL)
        if !usesAzureEndpoint {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
            body.append(Data(requestConfig.model.utf8))
            body.append(Data("\r\n".utf8))
        }

        // Add size field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"size\"\r\n\r\n".utf8))
        body.append(Data(imageConfig.size.utf8))
        body.append(Data("\r\n".utf8))

        // Add quality field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"quality\"\r\n\r\n".utf8))
        body.append(Data(imageConfig.quality.utf8))
        body.append(Data("\r\n".utf8))

        // End boundary
        body.append(Data("--\(boundary)--\r\n".utf8))

        request.httpBody = body

        // Execute request
        executeEditRequest(
            request,
            requestHandle: requestHandle,
            onComplete: onComplete,
            onError: onError
        )
    }

    private func executeEditRequest(
        _ request: URLRequest,
        requestHandle: RequestHandle,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        attempt: Int = 0
    ) {
        guard requestHandle.isActive else { return }
        let retryDelay = retryDelay

        let circuitKey = NetworkCircuitBreaker.key(for: request.url, label: "openai.image.edit")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Image editing temporarily unavailable. Please try again in \(seconds)s."
                : "Image editing temporarily unavailable. Please try again shortly."
            requestHandle.run { @MainActor in
                guard requestHandle.isActive else { return }
                onError(AynaError.apiError(message: message))
            }
            return
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard requestHandle.isActive else { return }

            if let error {
                if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }
                if AIRetryPolicy.shouldRetry(error: error, attempt: attempt) {
                    requestHandle.run { @MainActor [weak self] in
                        await retryDelay(attempt)
                        guard requestHandle.isActive, !Task.isCancelled else { return }
                        self?.executeEditRequest(
                            request,
                            requestHandle: requestHandle,
                            onComplete: onComplete,
                            onError: onError,
                            attempt: attempt + 1
                        )
                    }
                } else {
                    requestHandle.run { @MainActor in
                        guard requestHandle.isActive else { return }
                        onError(error)
                    }
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    onError(AynaError.invalidResponse(detail: nil))
                }
                return
            }

            guard let data else {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .error,
                    message: "No data received from image editing"
                )
                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    onError(AynaError.invalidResponse(detail: "No data received"))
                }
                return
            }

            guard httpResponse.statusCode == 200 else {
                if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }

                let message: String = {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorDict = json["error"] as? [String: Any],
                       let errorMessage = errorDict["message"] as? String
                    {
                        return errorMessage
                    }
                    return "HTTP \(httpResponse.statusCode)"
                }()

                requestHandle.run { @MainActor in
                    guard requestHandle.isActive else { return }
                    onError(AynaError.apiError(message: message))
                }
                return
            }

            NetworkCircuitBreaker.recordSuccess(key: circuitKey)

            let context = GenerationContext(
                requestHandle: requestHandle,
                onComplete: onComplete,
                onError: onError
            )
            self?.parseResponse(data, context: context)
        }
        requestHandle.resume(task)
    }
}

private extension OpenAIImageService.RequestConfig {
    var requiresAPIKey: Bool {
        OpenAIEndpointResolver.customEndpointRequiresAPIKey(customEndpoint)
    }
}
