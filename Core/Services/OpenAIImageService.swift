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

    // MARK: - Initialization

    init(urlSession: URLSession? = nil) {
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
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        attempt: Int = 0
    ) {
        // Validate provider
        guard requestConfig.provider == .openai else {
            onError(OpenAIService.OpenAIError.unsupportedProvider)
            return
        }

        // Validate API key
        guard !requestConfig.apiKey.isEmpty else {
            onError(OpenAIService.OpenAIError.missingAPIKey)
            return
        }

        // Resolve endpoint URL
        let endpointConfig = OpenAIEndpointResolver.EndpointConfig(
            modelName: requestConfig.model,
            provider: requestConfig.provider,
            customEndpoint: requestConfig.customEndpoint,
            azureAPIVersion: requestConfig.azureAPIVersion
        )
        let imageURL = OpenAIEndpointResolver.imageGenerationURL(for: endpointConfig)

        guard let url = URL(string: imageURL) else {
            onError(OpenAIService.OpenAIError.invalidURL)
            return
        }

        // Build request
        let usesAzureEndpoint = OpenAIEndpointResolver.isAzureEndpoint(requestConfig.customEndpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set authentication header
        if usesAzureEndpoint {
            request.setValue(requestConfig.apiKey, forHTTPHeaderField: "api-key")
        } else {
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
        executeRequest(
            request,
            prompt: prompt,
            requestConfig: requestConfig,
            imageConfig: imageConfig,
            onComplete: onComplete,
            onError: onError,
            attempt: attempt
        )
    }

    // MARK: - Private Methods

    private func executeRequest(
        _ request: URLRequest,
        prompt: String,
        requestConfig: RequestConfig,
        imageConfig: ImageConfig,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        attempt: Int
    ) {
        let circuitKey = NetworkCircuitBreaker.key(for: request.url, label: "openai.image")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Image generation temporarily unavailable. Please try again in \(seconds)s."
                : "Image generation temporarily unavailable. Please try again shortly."
            Task { @MainActor in
                onError(OpenAIService.OpenAIError.apiError(message))
            }
            return
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }
                self?.handleError(
                    error,
                    prompt: prompt,
                    requestConfig: requestConfig,
                    imageConfig: imageConfig,
                    onComplete: onComplete,
                    onError: onError,
                    attempt: attempt
                )
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.invalidResponse)
                }
                return
            }

            guard let data else {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .error,
                    message: "No data received from image generation"
                )
                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.noData)
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

                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.apiError(message))
                }
                return
            }

            NetworkCircuitBreaker.recordSuccess(key: circuitKey)

            self?.parseResponse(data, onComplete: onComplete, onError: onError)
        }.resume()
    }

    private func handleError(
        _ error: Error,
        prompt: String,
        requestConfig: RequestConfig,
        imageConfig: ImageConfig,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        attempt: Int
    ) {
        Task { @MainActor [weak self] in
            if OpenAIRetryPolicy.shouldRetry(error: error, attempt: attempt) {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .info,
                    message: "⚠️ Retrying image generation (attempt \(attempt + 1))",
                    metadata: ["error": error.localizedDescription]
                )
                await OpenAIRetryPolicy.wait(for: attempt)
                self?.generateImage(
                    prompt: prompt,
                    requestConfig: requestConfig,
                    imageConfig: imageConfig,
                    onComplete: onComplete,
                    onError: onError,
                    attempt: attempt + 1
                )
                return
            }
            onError(error)
        }
    }

    private func parseResponse(
        _ data: Data,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.invalidResponse)
                }
                return
            }

            // Check for error response
            if let errorDict = json["error"] as? [String: Any],
               let code = errorDict["code"] as? String,
               let message = errorDict["message"] as? String
            {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .error,
                    message: "API error in image generation",
                    metadata: ["code": code, "message": message]
                )
                Task { @MainActor in
                    if code == "contentFilter" {
                        onError(OpenAIService.OpenAIError.contentFiltered(message))
                    } else {
                        onError(OpenAIService.OpenAIError.apiError(message))
                    }
                }
                return
            }

            // Parse successful response
            guard let dataArray = json["data"] as? [[String: Any]],
                  let firstItem = dataArray.first
            else {
                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.invalidResponse)
                }
                return
            }

            // Try b64_json first (preferred)
            if let b64String = firstItem["b64_json"] as? String,
               let imageData = Data(base64Encoded: b64String)
            {
                Task { @MainActor in
                    onComplete(imageData)
                }
                return
            }

            // Fall back to URL download
            if let urlString = firstItem["url"] as? String,
               let url = URL(string: urlString)
            {
                Task {
                    do {
                        let (imageData, _) = try await URLSession.shared.data(from: url)
                        await MainActor.run {
                            onComplete(imageData)
                        }
                    } catch {
                        await MainActor.run {
                            onError(error)
                        }
                    }
                }
                return
            }

            Task { @MainActor in
                onError(OpenAIService.OpenAIError.invalidResponse)
            }
        } catch {
            Task { @MainActor in
                onError(error)
            }
        }
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
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        // Validate provider
        guard requestConfig.provider == .openai else {
            onError(OpenAIService.OpenAIError.unsupportedProvider)
            return
        }

        // Validate API key
        guard !requestConfig.apiKey.isEmpty else {
            onError(OpenAIService.OpenAIError.missingAPIKey)
            return
        }

        // Resolve endpoint URL
        let endpointConfig = OpenAIEndpointResolver.EndpointConfig(
            modelName: requestConfig.model,
            provider: requestConfig.provider,
            customEndpoint: requestConfig.customEndpoint,
            azureAPIVersion: requestConfig.azureAPIVersion
        )
        let editURL = OpenAIEndpointResolver.imageEditURL(for: endpointConfig)

        guard let url = URL(string: editURL) else {
            onError(OpenAIService.OpenAIError.invalidURL)
            return
        }

        // Build multipart form request
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Set authentication header
        let usesAzureEndpoint = OpenAIEndpointResolver.isAzureEndpoint(requestConfig.customEndpoint)
        if usesAzureEndpoint {
            request.setValue(requestConfig.apiKey, forHTTPHeaderField: "api-key")
        } else {
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
        executeEditRequest(request, onComplete: onComplete, onError: onError)
    }

    private func executeEditRequest(
        _ request: URLRequest,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        let circuitKey = NetworkCircuitBreaker.key(for: request.url, label: "openai.image.edit")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Image editing temporarily unavailable. Please try again in \(seconds)s."
                : "Image editing temporarily unavailable. Please try again shortly."
            Task { @MainActor in
                onError(OpenAIService.OpenAIError.apiError(message))
            }
            return
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }
                Task { @MainActor in
                    onError(error)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.invalidResponse)
                }
                return
            }

            guard let data else {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .error,
                    message: "No data received from image editing"
                )
                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.noData)
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

                Task { @MainActor in
                    onError(OpenAIService.OpenAIError.apiError(message))
                }
                return
            }

            NetworkCircuitBreaker.recordSuccess(key: circuitKey)

            self?.parseResponse(data, onComplete: onComplete, onError: onError)
        }.resume()
    }
}
