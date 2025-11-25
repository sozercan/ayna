//
//  OpenAIService.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
import Foundation
import os

// swiftlint:disable type_body_length
// This service intentionally aggregates every provider workflow until we extract dedicated modules.

enum AIProvider: String, CaseIterable, Codable {
    case openai = "OpenAI"
    case appleIntelligence = "Apple Intelligence"
    case aikit = "AIKit"

    var displayName: String { rawValue }
}

enum APIEndpointType: String, CaseIterable, Codable {
    case chatCompletions = "Chat Completions"
    case responses = "Responses"
    case imageGeneration = "Image Generation"

    var displayName: String { rawValue }
}

@MainActor
class OpenAIService: ObservableObject {
    static let shared = OpenAIService()
    static var keychain: KeychainStoring = KeychainStorage.shared

    private enum KeychainKeys {
        static let globalAPIKey = "openai_api_key"
        static let modelAPIKeys = "model_api_keys"
    }

    @Published var apiKey: String {
        didSet {
            saveAPIKey()
        }
    }

    @Published var selectedModel: String {
        didSet {
            AppPreferences.storage.set(selectedModel, forKey: "selectedModel")
            // Sync with AIKitService if this is an AIKit model
            if modelProviders[selectedModel] == .aikit {
                #if os(macOS)
                    AIKitService.shared.selectModelByName(selectedModel)
                #endif
            }
        }
    }

    // Track current task for cancellation
    private var currentTask: URLSessionDataTask?
    private var currentStreamTask: Task<Void, Never>?

    @Published var provider: AIProvider {
        didSet {
            AppPreferences.storage.set(provider.rawValue, forKey: "aiProvider")
        }
    }

    private let openAIURL = "https://api.openai.com/v1/chat/completions"
    private let azureAPIVersion = "2025-04-01-preview"

    // Custom URLSession with longer timeout for slow models
    private let urlSession: URLSession

    // Image generation service
    private let imageService: OpenAIImageService

    @Published var customModels: [String] {
        didSet {
            AppPreferences.storage.set(customModels, forKey: "customModels")
            // iCloud sync disabled for free developer account
            // NSUbiquitousKeyValueStore.default.set(customModels, forKey: "customModels")
            // NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    @Published var modelProviders: [String: AIProvider] {
        didSet {
            let encodedDict = modelProviders.mapValues { $0.rawValue }
            AppPreferences.storage.set(encodedDict, forKey: "modelProviders")
            // iCloud sync disabled for free developer account
            // NSUbiquitousKeyValueStore.default.set(encodedDict, forKey: "modelProviders")
            // NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    @Published var modelEndpointTypes: [String: APIEndpointType] {
        didSet {
            let encodedDict = modelEndpointTypes.mapValues { $0.rawValue }
            AppPreferences.storage.set(encodedDict, forKey: "modelEndpointTypes")
            // iCloud sync disabled for free developer account
            // NSUbiquitousKeyValueStore.default.set(encodedDict, forKey: "modelEndpointTypes")
            // NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    @Published var modelEndpoints: [String: String] {
        didSet {
            AppPreferences.storage.set(modelEndpoints, forKey: "modelEndpoints")
            // iCloud sync disabled for free developer account
            // NSUbiquitousKeyValueStore.default.set(modelEndpoints, forKey: "modelEndpoints")
            // NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    @Published var modelAPIKeys: [String: String] {
        didSet {
            persistModelAPIKeys()
        }
    }

    // Image generation settings
    @Published var imageSize: String {
        didSet {
            AppPreferences.storage.set(imageSize, forKey: "imageSize")
        }
    }

    @Published var imageQuality: String {
        didSet {
            AppPreferences.storage.set(imageQuality, forKey: "imageQuality")
        }
    }

    @Published var outputFormat: String {
        didSet {
            AppPreferences.storage.set(outputFormat, forKey: "outputFormat")
        }
    }

    @Published var outputCompression: Int {
        didSet {
            AppPreferences.storage.set(outputCompression, forKey: "outputCompression")
        }
    }

    enum ModelCapability {
        case chat
        case imageGeneration
    }

    init(urlSession: URLSession? = nil) {
        if let session = urlSession {
            self.urlSession = session
            imageService = OpenAIImageService(urlSession: session)
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120 // 2 minutes
            config.timeoutIntervalForResource = 300 // 5 minutes
            self.urlSession = URLSession(configuration: config)
            imageService = OpenAIImageService(urlSession: self.urlSession)
        }
        // Load custom models first
        let loadedCustomModels: [String] = if let savedModels = AppPreferences.storage.array(forKey: "customModels") as? [String] {
            savedModels
        } else {
            []
        }
        customModels = loadedCustomModels

        // Load model providers mapping
        let loadedProviders: [String: AIProvider] = if let savedProviders = AppPreferences.storage.dictionary(forKey: "modelProviders")
            as? [String: String]
        {
            savedProviders.compactMapValues { AIProvider(rawValue: $0) }
        } else {
            // Default all initial models to OpenAI
            Dictionary(
                uniqueKeysWithValues: loadedCustomModels.map { ($0, AIProvider.openai) })
        }
        modelProviders = loadedProviders

        // Load model endpoint types mapping
        let loadedEndpointTypes: [String: APIEndpointType] = if let savedEndpointTypes = AppPreferences.storage.dictionary(forKey: "modelEndpointTypes")
            as? [String: String]
        {
            savedEndpointTypes.compactMapValues { APIEndpointType(rawValue: $0) }
        } else {
            // Default all models to Chat Completions
            Dictionary(
                uniqueKeysWithValues: loadedCustomModels.map { ($0, APIEndpointType.chatCompletions) })
        }
        modelEndpointTypes = loadedEndpointTypes

        // Load custom endpoints mapping
        let loadedEndpoints: [String: String] = if let savedEndpoints = AppPreferences.storage.dictionary(forKey: "modelEndpoints")
            as? [String: String]
        {
            savedEndpoints
        } else {
            [:]
        }
        modelEndpoints = loadedEndpoints

        // Load per-model API keys
        modelAPIKeys = OpenAIService.loadModelAPIKeys()

        // Load selected model, ensure it exists in custom models
        let savedSelectedModel = AppPreferences.storage.string(forKey: "selectedModel") ?? ""
        if loadedCustomModels.contains(savedSelectedModel) {
            selectedModel = savedSelectedModel
        } else if let firstModel = loadedCustomModels.first {
            selectedModel = firstModel
        } else {
            selectedModel = ""
        }

        // Initialize API key
        apiKey = OpenAIService.loadGlobalAPIKey()

        // Initialize provider
        if let providerString = AppPreferences.storage.string(forKey: "aiProvider"),
           let savedProvider = AIProvider(rawValue: providerString)
        {
            provider = savedProvider
        } else {
            provider = .openai
        }

        // Initialize image generation settings
        imageSize = AppPreferences.storage.string(forKey: "imageSize") ?? "1024x1024"
        imageQuality = AppPreferences.storage.string(forKey: "imageQuality") ?? "medium"
        outputFormat = AppPreferences.storage.string(forKey: "outputFormat") ?? "png"
        outputCompression =
            AppPreferences.storage.integer(forKey: "outputCompression") == 0
                ? 100 : AppPreferences.storage.integer(forKey: "outputCompression")

        // iCloud sync disabled for free developer account
        // setupiCloudSync()
    }

    private func saveAPIKey() {
        do {
            if apiKey.isEmpty {
                try OpenAIService.keychain.removeValue(for: KeychainKeys.globalAPIKey)
            } else {
                try OpenAIService.keychain.setString(apiKey, for: KeychainKeys.globalAPIKey)
            }
        } catch {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "Failed to persist API key",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func persistModelAPIKeys() {
        do {
            try OpenAIService.storeModelAPIKeys(modelAPIKeys)
        } catch {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "Failed to persist model API keys",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private static func loadGlobalAPIKey() -> String {
        do {
            if let storedKey = try keychain.string(for: KeychainKeys.globalAPIKey) {
                return storedKey
            }
        } catch {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "Unable to read API key from Keychain",
                metadata: ["error": error.localizedDescription]
            )
        }
        return ""
    }

    private static func loadModelAPIKeys() -> [String: String] {
        do {
            if let data = try keychain.data(for: KeychainKeys.modelAPIKeys) {
                do {
                    return try JSONDecoder().decode([String: String].self, from: data)
                } catch {
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .error,
                        message: "Failed to decode model API keys from Keychain",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        } catch {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "Unable to read model API keys from Keychain",
                metadata: ["error": error.localizedDescription]
            )
        }
        return [:]
    }

    private static func storeModelAPIKeys(_ dictionary: [String: String]) throws {
        if dictionary.isEmpty {
            try keychain.removeValue(for: KeychainKeys.modelAPIKeys)
            return
        }

        let data = try JSONEncoder().encode(dictionary)
        try keychain.setData(data, for: KeychainKeys.modelAPIKeys)
    }

    private func normalizedModelName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func customEndpoint(for modelName: String?) -> (endpoint: String, model: String)? {
        guard let normalizedName = normalizedModelName(modelName),
              let endpoint = modelEndpoints[normalizedName]?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty
        else {
            return nil
        }

        return (endpoint, normalizedName)
    }

    private func isAzureEndpoint(_ endpoint: String?) -> Bool {
        OpenAIEndpointResolver.isAzureEndpoint(endpoint)
    }

    // Get API key for a specific model, falling back to global key if not set
    func getAPIKey(for model: String?) -> String {
        guard let model else { return apiKey }
        return modelAPIKeys[model] ?? apiKey
    }

    private func getAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) -> String {
        let effectiveProvider = provider ?? self.provider
        let modelName = deploymentName ?? selectedModel
        let endpointInfo = customEndpoint(for: modelName)

        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: modelName,
            provider: effectiveProvider,
            customEndpoint: endpointInfo?.endpoint,
            azureAPIVersion: azureAPIVersion
        )

        return OpenAIEndpointResolver.chatCompletionsURL(for: config)
    }

    private func getResponsesAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) -> String {
        let effectiveProvider = provider ?? self.provider
        let modelName = deploymentName ?? selectedModel
        let endpointInfo = customEndpoint(for: modelName)

        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: modelName,
            provider: effectiveProvider,
            customEndpoint: endpointInfo?.endpoint,
            azureAPIVersion: azureAPIVersion
        )

        return OpenAIEndpointResolver.responsesURL(for: config)
    }

    func getModelCapability(_ model: String) -> ModelCapability {
        // Check the endpoint type setting for this model
        if let endpointType = modelEndpointTypes[model] {
            switch endpointType {
            case .imageGeneration:
                return .imageGeneration
            case .chatCompletions, .responses:
                return .chat
            }
        }
        // Default to chat if no setting found
        return .chat
    }

    func cancelCurrentRequest() {
        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "Canceling current request"
        )
        currentTask?.cancel()
        currentTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "Request cancellation initiated"
        )
    }

    /// Generates an image from a text prompt.
    /// Delegates to OpenAIImageService for the actual network request.
    func generateImage(
        prompt: String,
        model: String? = nil,
        onComplete: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        attempt: Int = 0
    ) {
        let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestModel.isEmpty else {
            onError(OpenAIError.missingModel)
            return
        }

        let effectiveProvider = modelProviders[requestModel] ?? provider
        let endpointInfo = customEndpoint(for: requestModel)

        let requestConfig = OpenAIImageService.RequestConfig(
            model: requestModel,
            apiKey: getAPIKey(for: requestModel),
            provider: effectiveProvider,
            customEndpoint: endpointInfo?.endpoint,
            azureAPIVersion: azureAPIVersion
        )

        let imageConfig = OpenAIImageService.ImageConfig(
            size: imageSize,
            quality: imageQuality,
            outputFormat: outputFormat,
            outputCompression: outputCompression
        )

        imageService.generateImage(
            prompt: prompt,
            requestConfig: requestConfig,
            imageConfig: imageConfig,
            onComplete: onComplete,
            onError: onError,
            attempt: attempt
        )
    }

    // MARK: - Helper Methods for sendMessage

    private func validateProviderSettings(for provider: AIProvider, model: String?) throws {
        guard providerRequiresAPIKey(provider) else { return }

        if !isAPIKeyConfigured(for: provider, model: model) {
            throw OpenAIError.missingAPIKey
        }
    }

    func sendMessage(
        messages: [Message],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = true,
        tools: [[String: Any]]? = nil,
        conversationId: UUID? = nil,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = nil,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) {
        #if !os(iOS)
            if UITestEnvironment.isEnabled {
                simulateUITestResponse(
                    messages: messages,
                    stream: stream,
                    onChunk: onChunk,
                    onComplete: onComplete
                )
                return
            }
        #endif

        let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestModel.isEmpty else {
            onError(OpenAIError.missingModel)
            return
        }
        let effectiveProvider = modelProviders[requestModel] ?? provider
        let endpointInfo = customEndpoint(for: requestModel)
        let usesAzureEndpoint = endpointInfo.map { isAzureEndpoint($0.endpoint) } ?? false

        // Handle Apple Intelligence separately
        if effectiveProvider == .appleIntelligence {
            if #available(macOS 26.0, iOS 26.0, *) {
                handleAppleIntelligenceRequest(
                    messages: messages,
                    temperature: temperature,
                    stream: stream,
                    conversationId: conversationId,
                    onChunk: onChunk,
                    onComplete: onComplete,
                    onError: onError
                )
            } else {
                onError(OpenAIError.apiError("Apple Intelligence requires macOS 26.0 or iOS 26.0 or later"))
            }
            return
        }

        // Validate provider settings
        do {
            try validateProviderSettings(for: effectiveProvider, model: requestModel)
        } catch {
            onError(error)
            return
        }

        // Check if this model should use the responses API
        let endpointType = modelEndpointTypes[requestModel] ?? .chatCompletions
        if endpointType == .responses {
            responsesAPIRequest(
                messages: messages,
                model: requestModel,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onReasoning: onReasoning
            )
            return
        }

        // Build API request
        let apiURL = getAPIURL(deploymentName: requestModel, provider: effectiveProvider)

        guard let url = URL(string: apiURL) else {
            onError(OpenAIError.invalidURL)
            return
        }

        let modelAPIKey = getAPIKey(for: requestModel)
        let needsAuth = effectiveProvider == .openai

        guard
            let request = OpenAIRequestBuilder.createChatCompletionsRequest(
                url: url,
                messages: messages,
                model: requestModel,
                stream: stream,
                tools: tools,
                apiKey: needsAuth ? modelAPIKey : "",
                isAzure: usesAzureEndpoint
            )
        else {
            onError(OpenAIError.invalidRequest)
            return
        }

        if stream {
            let callbacks = StreamCallbacks(
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning
            )
            streamResponse(request: request, callbacks: callbacks)
        } else {
            nonStreamResponse(
                request: request, onChunk: onChunk, onComplete: onComplete, onError: onError,
                onToolCall: onToolCall, onReasoning: onReasoning
            )
        }
    }

    private func simulateUITestResponse(
        messages: [Message],
        stream: Bool,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let fallback = "Mock response"
        let userContent = messages.last(where: { $0.role == .user })?.content ?? fallback

        // Handle title generation
        if userContent.starts(with: "Generate a very short title") {
            // Extract the original content from the prompt
            // Prompt format: ... starts with: "CONTENT". Only respond ...
            if let range = userContent.range(of: "starts with: \""),
               let endRange = userContent.range(of: "\". Only respond")
            {
                let content = String(userContent[range.upperBound ..< endRange.lowerBound])
                // Return just the content as the title (or a shortened version)
                let title = String(content.prefix(50))
                onChunk(title)
                onComplete()
                return
            }
        }

        let response = "UI Test Response: \(userContent)"

        let deliverResponse = {
            onChunk(response)
            onComplete()
        }

        if stream {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: deliverResponse)
        } else {
            DispatchQueue.main.async(execute: deliverResponse)
        }
    }

    // The Responses API flow handles multimodal payload assembly in one place for debugging clarity.
    // swiftlint:disable superfluous_disable_command
    // swiftlint:disable:next function_body_length
    private func responsesAPIRequest(
        messages: [Message],
        model: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        onReasoning: ((String) -> Void)? = nil,
        attempt: Int = 0
    ) {
        // Check if this model has a provider override
        let effectiveProvider = modelProviders[model] ?? provider
        let endpointInfo = customEndpoint(for: model)
        let usesAzureEndpoint = endpointInfo.map { isAzureEndpoint($0.endpoint) } ?? false

        // Apple Intelligence doesn't support the responses API
        if effectiveProvider == .appleIntelligence {
            onError(OpenAIError.apiError("Apple Intelligence doesn't support the Responses API endpoint"))
            return
        }

        let requestModel = model
        let modelAPIKey = getAPIKey(for: requestModel)
        let apiURL = getResponsesAPIURL(deploymentName: model, provider: effectiveProvider)

        guard let url = URL(string: apiURL) else {
            onError(OpenAIError.invalidURL)
            return
        }

        guard
            let request = OpenAIRequestBuilder.createResponsesRequest(
                url: url,
                messages: messages,
                model: model,
                apiKey: modelAPIKey,
                isAzure: usesAzureEndpoint
            )
        else {
            onError(OpenAIError.invalidRequest)
            return
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                // Clear the task reference
                self?.currentTask = nil

                if let error {
                    // Don't report error if it was cancelled
                    if (error as NSError).code == NSURLErrorCancelled {
                        return
                    }

                    if self?.shouldRetry(error: error, attempt: attempt) == true {
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .info,
                            message: "⚠️ Retrying responses API request (attempt \(attempt + 1))",
                            metadata: ["error": error.localizedDescription]
                        )
                        Task {
                            await self?.delay(for: attempt)
                            await MainActor.run {
                                self?.responsesAPIRequest(
                                    messages: messages,
                                    model: model,
                                    onChunk: onChunk,
                                    onComplete: onComplete,
                                    onError: onError,
                                    onReasoning: onReasoning,
                                    attempt: attempt + 1
                                )
                            }
                        }
                        return
                    }

                    onError(error)
                    return
                }

                guard let data else {
                    onError(OpenAIError.noData)
                    return
                }

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let errorDict = json?["error"] as? [String: Any],
                       let message = errorDict["message"] as? String
                    {
                        onError(OpenAIError.apiError(message))
                        return
                    }

                    if let outputArray = json?["output"] as? [[String: Any]] {
                        OpenAIRequestBuilder.deliverResponsesOutput(
                            outputArray,
                            onChunk: onChunk,
                            onReasoning: onReasoning
                        )
                    }

                    onComplete()
                } catch {
                    onError(error)
                }
            }
        }

        // Store and start the task
        currentTask = task
        task.resume()
    }

    // swiftlint:enable superfluous_disable_command

    // MARK: - Helper Methods for streamResponse

    private nonisolated func getHTTPErrorMessage(statusCode: Int, requestURL: URL?) -> String {
        if statusCode == 400 {
            if requestURL?.absoluteString.lowercased().contains("openai.azure.com") == true {
                return "HTTP \(statusCode) - Invalid Azure deployment or API version (\(azureAPIVersion))."
            }
            return "HTTP \(statusCode) - Invalid request. Check your model name and parameters."
        }

        return "HTTP \(statusCode)"
    }

    private func streamResponse(
        request: URLRequest,
        callbacks: StreamCallbacks,
        attempt: Int = 0
    ) {
        let session = urlSession
        let task = Task.detached { [weak self] in
            guard let self else { return }
            var hasReceivedData = false
            do {
                let (bytes, response) = try await session.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let errorMessage = getHTTPErrorMessage(
                        statusCode: httpResponse.statusCode,
                        requestURL: request.url
                    )
                    throw OpenAIError.apiError(errorMessage)
                }

                var buffer = Data()
                var currentToolCallBuffer: [String: Any] = [:]
                var toolCallId = ""

                // Batching buffers
                var contentBuffer = ""
                var reasoningBuffer = ""
                var lastUpdateTime = Date()

                for try await byte in bytes {
                    hasReceivedData = true
                    // Check if task was cancelled
                    if Task.isCancelled {
                        await MainActor.run {
                            DiagnosticsLogger.log(
                                .openAIService,
                                level: .info,
                                message: "Stream task cancelled; stopping iteration"
                            )
                            self.currentStreamTask = nil
                        }
                        return
                    }

                    buffer.append(byte)

                    // Check if we have a newline (UTF-8: 0x0A)
                    if byte == 0x0A {
                        if let line = String(data: buffer, encoding: .utf8) {
                            let result = await OpenAIStreamParser.processStreamLine(
                                line,
                                toolCallBuffer: currentToolCallBuffer,
                                toolCallId: toolCallId,
                                onToolCall: callbacks.onToolCall,
                                onToolCallRequested: callbacks.onToolCallRequested
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
                                // Flush remaining buffers
                                let contentToSend = contentBuffer
                                let reasoningToSend = reasoningBuffer
                                await MainActor.run {
                                    if !contentToSend.isEmpty { callbacks.onChunk(contentToSend) }
                                    if !reasoningToSend.isEmpty { callbacks.onReasoning?(reasoningToSend) }
                                    self.currentStreamTask = nil
                                    callbacks.onComplete()
                                }
                                return
                            }

                            // Check if we should dispatch batch
                            if !contentBuffer.isEmpty || !reasoningBuffer.isEmpty {
                                let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdateTime)
                                if timeSinceLastUpdate > 0.05 || contentBuffer.count > 100 || reasoningBuffer.count > 100 {
                                    let contentToSend = contentBuffer
                                    let reasoningToSend = reasoningBuffer
                                    await MainActor.run {
                                        if !contentToSend.isEmpty { callbacks.onChunk(contentToSend) }
                                        if !reasoningToSend.isEmpty { callbacks.onReasoning?(reasoningToSend) }
                                    }
                                    contentBuffer = ""
                                    reasoningBuffer = ""
                                    lastUpdateTime = Date()
                                }
                            }
                        }
                        buffer.removeAll()
                    }
                }

                // Flush any remaining content
                let contentToSend = contentBuffer
                let reasoningToSend = reasoningBuffer
                await MainActor.run {
                    if !contentToSend.isEmpty { callbacks.onChunk(contentToSend) }
                    if !reasoningToSend.isEmpty { callbacks.onReasoning?(reasoningToSend) }
                    self.currentStreamTask = nil
                    callbacks.onComplete()
                }
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

    private func handleStreamError(
        error: Error,
        attempt: Int,
        hasReceivedData: Bool,
        request: URLRequest,
        callbacks: StreamCallbacks
    ) async {
        if shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData) {
            DiagnosticsLogger.log(
                .openAIService,
                level: .info,
                message: "⚠️ Retrying stream request (attempt \(attempt + 1))",
                metadata: ["error": error.localizedDescription]
            )
            await delay(for: attempt)
            await MainActor.run {
                streamResponse(
                    request: request,
                    callbacks: callbacks,
                    attempt: attempt + 1
                )
            }
        } else {
            await MainActor.run {
                self.currentStreamTask = nil
                // Check if it's a timeout error and provide a better message
                if let urlError = error as? URLError, urlError.code == .timedOut {
                    callbacks.onError(
                        OpenAIError.apiError(
                            "Request timed out. The model may be slow or overloaded. Please try again."))
                } else if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
                    callbacks.onError(
                        OpenAIError.apiError(
                            "Network connection was lost. The server may have rejected the request."))
                } else if (error as? CancellationError) != nil {
                    // Task was cancelled, don't report as error
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .info,
                        message: "Stream task cancelled via CancellationError"
                    )
                } else {
                    callbacks.onError(error)
                }
            }
        }
    }

    private func nonStreamResponse(
        request: URLRequest,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        attempt: Int = 0
    ) {
        let task = urlSession.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error {
                    if self?.shouldRetry(error: error, attempt: attempt) == true {
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .info,
                            message: "⚠️ Retrying non-stream request (attempt \(attempt + 1))",
                            metadata: ["error": error.localizedDescription]
                        )
                        Task {
                            await self?.delay(for: attempt)
                            await MainActor.run {
                                self?.nonStreamResponse(
                                    request: request,
                                    onChunk: onChunk,
                                    onComplete: onComplete,
                                    onError: onError,
                                    onToolCall: onToolCall,
                                    onReasoning: onReasoning,
                                    attempt: attempt + 1
                                )
                            }
                        }
                        return
                    }
                    onError(error)
                    return
                }

                guard let data else {
                    onError(OpenAIError.invalidResponse)
                    return
                }

                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let errorDict = json?["error"] as? [String: Any],
                       let message = errorDict["message"] as? String
                    {
                        onError(OpenAIError.apiError(message))
                        return
                    }

                    if let choices = json?["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any]
                    {
                        // Check for reasoning in various possible locations
                        var foundReasoning: String?
                        if let reasoning = message["reasoning"] as? String {
                            foundReasoning = reasoning
                        } else if let reasoning = message["reasoning_content"] as? String {
                            foundReasoning = reasoning
                        } else if let usage = json?["usage"] as? [String: Any],
                                  let details = usage["completion_tokens_details"] as? [String: Any],
                                  let reasoningTokens = details["reasoning_tokens"] as? Int, reasoningTokens > 0
                        {
                            // Show reasoning token count
                            foundReasoning = "💭 Reasoning tokens used: \(reasoningTokens)"
                        }

                        // Handle reasoning content if found
                        if let reasoning = foundReasoning, let onReasoning {
                            onReasoning(reasoning)
                        }

                        // Handle regular content
                        if let contentField = message["content"], !(contentField is NSNull) {
                            let textSegments = OpenAIStreamParser.extractTextSegments(
                                from: contentField,
                                source: "nonstream.chat",
                                metadata: ["phase": "final"]
                            )

                            for segment in textSegments where !segment.isEmpty {
                                onChunk(segment)
                            }
                        }

                        // Handle tool calls
                        if let toolCalls = message["tool_calls"] as? [[String: Any]],
                           let onToolCall
                        {
                            Task {
                                for toolCall in toolCalls {
                                    if let id = toolCall["id"] as? String,
                                       let function = toolCall["function"] as? [String: Any],
                                       let name = function["name"] as? String,
                                       let argsString = function["arguments"] as? String,
                                       let argsData = argsString.data(using: .utf8),
                                       let arguments = try? JSONSerialization.jsonObject(with: argsData)
                                       as? [String: Any]
                                    {
                                        let result = await onToolCall(id, name, arguments)
                                        await MainActor.run {
                                            onChunk("\n\n[Tool: \(name)]\n\(result)\n")
                                        }
                                    }
                                }
                                await MainActor.run {
                                    onComplete()
                                }
                            }
                            return
                        }

                        onComplete()
                    } else {
                        onError(OpenAIError.invalidResponse)
                    }
                } catch {
                    onError(error)
                }
            }
        }

        task.resume()
    }

    @available(macOS 26.0, *)
    private func handleAppleIntelligenceRequest(
        messages: [Message],
        temperature: Double?,
        stream: Bool,
        conversationId: UUID?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let service = AppleIntelligenceService.shared

        // Check availability
        guard service.isAvailable else {
            onError(OpenAIError.apiError(service.availabilityDescription()))
            return
        }

        // Extract system instructions (first system message if any)
        let systemInstructions =
            messages.first(where: { $0.role == .system })?.content
                ?? "You are a helpful assistant."

        // Get the last user message as the prompt
        guard let lastUserMessage = messages.last(where: { $0.role == .user }) else {
            onError(OpenAIError.apiError("No user message found"))
            return
        }

        // Use the provided conversation ID or a default
        let convId = conversationId?.uuidString ?? "default"

        let requestTemp = temperature ?? 0.7

        Task {
            if stream {
                await service.streamResponse(
                    conversationId: convId,
                    prompt: lastUserMessage.content,
                    systemInstructions: systemInstructions,
                    temperature: requestTemp,
                    onChunk: { chunk in
                        onChunk(chunk)
                    },
                    onComplete: {
                        onComplete()
                    },
                    onError: { error in
                        onError(error)
                    }
                )
            } else {
                await service.generateResponse(
                    conversationId: convId,
                    prompt: lastUserMessage.content,
                    systemInstructions: systemInstructions,
                    temperature: requestTemp,
                    onComplete: { response in
                        onChunk(response)
                        onComplete()
                    },
                    onError: { error in
                        onError(error)
                    }
                )
            }
        }
    }

    // Retry logic delegated to OpenAIRetryPolicy
    private func shouldRetry(error: Error, attempt: Int, hasReceivedData: Bool = false) -> Bool {
        OpenAIRetryPolicy.shouldRetry(
            error: error,
            attempt: attempt,
            hasReceivedData: hasReceivedData
        )
    }

    private func delay(for attempt: Int) async {
        await OpenAIRetryPolicy.wait(for: attempt)
    }

    enum OpenAIError: LocalizedError {
        case missingAPIKey
        case missingModel
        case invalidResponse
        case invalidRequest
        case apiError(String)
        case invalidURL
        case unsupportedProvider
        case noData
        case contentFiltered(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Please add your API key in Settings"
            case .missingModel:
                "Please add or select a model in Settings"
            case .invalidResponse:
                "Invalid response from API"
            case .invalidRequest:
                "Failed to build API request"
            case let .apiError(message):
                message
            case .invalidURL:
                "Invalid API endpoint URL"
            case .unsupportedProvider:
                "Image generation is only supported for OpenAI-compatible providers"
            case .noData:
                "No data received from API"
            case let .contentFiltered(message):
                "Content filtered: \(message)"
            }
        }
    }
}

extension OpenAIService {
    private func providerRequiresAPIKey(_ provider: AIProvider) -> Bool {
        switch provider {
        case .aikit, .appleIntelligence:
            false
        case .openai:
            true
        }
    }

    var requiresAPIKey: Bool {
        providerRequiresAPIKey(provider)
    }

    var latestAzureAPIVersion: String { azureAPIVersion }

    private func isAPIKeyConfigured(for provider: AIProvider, model: String?) -> Bool {
        guard providerRequiresAPIKey(provider) else { return true }

        if let model,
           let modelKey = modelAPIKeys[model]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelKey.isEmpty
        {
            return true
        }

        let trimmedGlobalKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGlobalKey.isEmpty {
            return true
        }

        return modelAPIKeys.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isAPIKeyConfigured: Bool {
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = trimmedModel.isEmpty ? nil : trimmedModel
        return isAPIKeyConfigured(for: provider, model: normalizedModel)
    }

    var configurationIssues: [String] {
        var issues: [String] = []
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = trimmedModel.isEmpty ? nil : trimmedModel
        let activeProvider = normalizedModel.flatMap { modelProviders[$0] } ?? provider

        if customModels.isEmpty {
            issues.append("Add at least one model in Settings > Model tab")
        } else if normalizedModel == nil {
            issues.append("Select a default model in Settings > Model tab")
        }

        if providerRequiresAPIKey(activeProvider),
           !isAPIKeyConfigured(for: activeProvider, model: normalizedModel)
        {
            issues.append("Add an API key for \(activeProvider.displayName)")
        }
        return issues
    }

    var usableModels: [String] {
        customModels.filter { model in
            #if os(iOS)
                if modelProviders[model] == .aikit {
                    return false
                }
            #endif
            return true
        }
    }

    private func setupiCloudSync() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(ubiquitousKeyValueStoreDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    @objc private func ubiquitousKeyValueStoreDidChange(notification _: NSNotification) {
        let store = NSUbiquitousKeyValueStore.default

        DispatchQueue.main.async {
            if let models = store.array(forKey: "customModels") as? [String] {
                self.customModels = models
            }

            if let providers = store.dictionary(forKey: "modelProviders") as? [String: String] {
                self.modelProviders = providers.compactMapValues { AIProvider(rawValue: $0) }
            }

            if let endpointTypes = store.dictionary(forKey: "modelEndpointTypes") as? [String: String] {
                self.modelEndpointTypes = endpointTypes.compactMapValues {
                    APIEndpointType(rawValue: $0)
                }
            }

            if let endpoints = store.dictionary(forKey: "modelEndpoints") as? [String: String] {
                self.modelEndpoints = endpoints
            }
        }
    }
}

// Keychain Helper

// swiftlint:enable type_body_length
