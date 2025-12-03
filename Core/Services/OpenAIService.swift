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
    case githubModels = "GitHub Models"
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
            // Only persist API key on iOS/macOS, not watchOS (Watch receives via WatchConnectivity)
            #if !os(watchOS)
                saveAPIKey()
            #endif
        }
    }

    @Published var selectedModel: String {
        didSet {
            // Only persist on iOS/macOS
            #if !os(watchOS)
                AppPreferences.storage.set(selectedModel, forKey: "selectedModel")
            #endif
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
    private var multiModelTask: Task<Void, Never>?
    #if !os(watchOS)
        private var appleIntelligenceTask: Task<Void, Never>?
    #endif

    @Published var provider: AIProvider {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(provider.rawValue, forKey: "aiProvider")
            #endif
        }
    }

    private let openAIURL = "https://api.openai.com/v1/chat/completions"
    private let azureAPIVersion = "2025-04-01-preview"

    // Custom URLSession with longer timeout for slow models
    private let urlSession: URLSession

    // Image generation service
    #if !os(watchOS)
        private let imageService: OpenAIImageService
    #endif

    @Published var customModels: [String] {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(customModels, forKey: "customModels")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(customModels, forKey: "customModels")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelProviders: [String: AIProvider] {
        didSet {
            #if !os(watchOS)
                let encodedDict = modelProviders.mapValues { $0.rawValue }
                AppPreferences.storage.set(encodedDict, forKey: "modelProviders")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(encodedDict, forKey: "modelProviders")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelEndpointTypes: [String: APIEndpointType] {
        didSet {
            #if !os(watchOS)
                let encodedDict = modelEndpointTypes.mapValues { $0.rawValue }
                AppPreferences.storage.set(encodedDict, forKey: "modelEndpointTypes")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(encodedDict, forKey: "modelEndpointTypes")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelEndpoints: [String: String] {
        didSet {
            #if !os(watchOS)
                AppPreferences.storage.set(modelEndpoints, forKey: "modelEndpoints")
                // iCloud sync disabled for free developer account
                // NSUbiquitousKeyValueStore.default.set(modelEndpoints, forKey: "modelEndpoints")
                // NSUbiquitousKeyValueStore.default.synchronize()
            #endif
        }
    }

    @Published var modelAPIKeys: [String: String] {
        didSet {
            #if !os(watchOS)
                persistModelAPIKeys()
            #endif
        }
    }

    /// Tracks which models use GitHub OAuth
    @Published var modelUsesGitHubOAuth: [String: Bool] {
        didSet {
            #if !os(watchOS)
                let dict = modelUsesGitHubOAuth.mapValues { $0 as NSNumber }
                AppPreferences.storage.set(dict, forKey: "modelUsesGitHubOAuth")
            #endif
        }
    }

    // Tavily web search settings (synced from iPhone on watchOS)
    #if os(watchOS)
        @Published var tavilyAPIKey: String = ""
        @Published var tavilyEnabled: Bool = false
    #endif

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
            #if !os(watchOS)
                imageService = OpenAIImageService(urlSession: session)
            #endif
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120 // 2 minutes
            config.timeoutIntervalForResource = 300 // 5 minutes
            self.urlSession = URLSession(configuration: config)
            #if !os(watchOS)
                imageService = OpenAIImageService(urlSession: self.urlSession)
            #endif
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

        // Load GitHub OAuth flags for models
        if let savedOAuthFlags = AppPreferences.storage.dictionary(forKey: "modelUsesGitHubOAuth") as? [String: NSNumber] {
            modelUsesGitHubOAuth = savedOAuthFlags.mapValues { $0.boolValue }
        } else {
            modelUsesGitHubOAuth = [:]
        }

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
    // For GitHub Models with OAuth, returns the OAuth token
    func getAPIKey(for model: String?) -> String {
        guard let model else { return apiKey }

        // Check if this model uses GitHub OAuth
        let usesOAuth = modelUsesGitHubOAuth[model] == true
        let isGitHubModel = modelProviders[model] == .githubModels

        DiagnosticsLogger.log(
            .openAIService,
            level: .debug,
            message: "🔑 Getting API key for model",
            metadata: [
                "model": model,
                "isGitHubModel": "\(isGitHubModel)",
                "usesOAuth": "\(usesOAuth)",
                "isAuthenticated": "\(GitHubOAuthService.shared.isAuthenticated)"
            ]
        )

        // For GitHub Models, always try OAuth token first if authenticated
        if isGitHubModel {
            if GitHubOAuthService.shared.isAuthenticated,
               let token = GitHubOAuthService.shared.getAccessToken(),
               !token.isEmpty
            {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .debug,
                    message: "🔑 Using GitHub OAuth token",
                    metadata: ["tokenPrefix": String(token.prefix(10)) + "..."]
                )
                return token
            } else {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .info,
                    message: "⚠️ GitHub OAuth not available, using stored API key"
                )
            }
        }

        return modelAPIKeys[model] ?? apiKey
    }

    /// Async version of getAPIKey that ensures the token is valid before returning.
    /// For GitHub Models with OAuth, this will refresh the token if it's expiring soon.
    /// Use this for critical API requests where you can await.
    func getValidAPIKey(for model: String?) async throws -> String {
        guard let model else { return apiKey }

        let isGitHubModel = modelProviders[model] == .githubModels

        // For GitHub Models, use the async method that handles refresh deduplication
        if isGitHubModel, GitHubOAuthService.shared.isAuthenticated {
            do {
                let token = try await GitHubOAuthService.shared.getValidAccessToken()
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .debug,
                    message: "🔑 Using validated GitHub OAuth token",
                    metadata: ["tokenPrefix": String(token.prefix(10)) + "..."]
                )
                return token
            } catch {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .error,
                    message: "❌ Failed to get valid GitHub token: \(error.localizedDescription)"
                )
                // Fall back to stored API key
            }
        }

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
        multiModelTask?.cancel()
        multiModelTask = nil
        #if !os(watchOS)
            appleIntelligenceTask?.cancel()
            appleIntelligenceTask = nil
        #endif
        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "Request cancellation initiated"
        )
    }

    #if !os(watchOS)
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
    #endif

    // MARK: - Helper Methods for sendMessage

    private func validateProviderSettings(for provider: AIProvider, model: String?) throws {
        guard providerRequiresAPIKey(provider) else { return }

        if !isAPIKeyConfigured(for: provider, model: model) {
            throw OpenAIError.missingAPIKey
        }
    }

    /// Checks if GitHub Models rate limit is currently blocking requests.
    /// Returns an error message if rate-limited, nil if requests can proceed.
    private func checkGitHubModelsRateLimit() -> String? {
        let oauthService = GitHubOAuthService.shared

        // Check if we have an active retry-after from a previous 429/403
        if let retryAfter = oauthService.retryAfterDate, retryAfter > Date() {
            let secondsRemaining = Int(retryAfter.timeIntervalSinceNow)
            if secondsRemaining > 60 {
                let minutesRemaining = secondsRemaining / 60
                return "Rate limited. Please wait \(minutesRemaining) minute\(minutesRemaining == 1 ? "" : "s")."
            } else if secondsRemaining > 0 {
                return "Rate limited. Please wait \(secondsRemaining) second\(secondsRemaining == 1 ? "" : "s")."
            }
        }

        // Check if rate limit is exhausted
        if let rateLimitInfo = oauthService.rateLimitInfo, rateLimitInfo.isExhausted {
            return "Rate limit exhausted. Resets \(rateLimitInfo.formattedReset)."
        }

        return nil
    }

    func sendMessage(
        messages: [Message],
        model: String? = nil,
        temperature: Double? = nil,
        stream: Bool = true,
        tools: [[String: Any]]? = nil,
        conversationId: UUID? = nil,
        isMultiModelRequest: Bool = false,
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = nil,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) {
        let requestModel = (model ?? selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "📤 sendMessage called",
            metadata: [
                "model": requestModel,
                "messagesCount": "\(messages.count)",
                "stream": "\(stream)",
                "hasTools": "\(tools != nil)"
            ]
        )

        #if !os(iOS) && !os(watchOS)
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

        guard !requestModel.isEmpty else {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "❌ Model is empty"
            )
            onError(OpenAIError.missingModel)
            return
        }
        let effectiveProvider = modelProviders[requestModel] ?? provider
        let endpointInfo = customEndpoint(for: requestModel)
        let usesAzureEndpoint = endpointInfo.map { isAzureEndpoint($0.endpoint) } ?? false

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "📤 Provider resolved",
            metadata: [
                "model": requestModel,
                "provider": effectiveProvider.rawValue,
                "hasCustomEndpoint": "\(endpointInfo != nil)",
                "isAzure": "\(usesAzureEndpoint)"
            ]
        )

        // Handle Apple Intelligence separately
        #if !os(watchOS)
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
        #else
            // Apple Intelligence is not available on watchOS
            if effectiveProvider == .appleIntelligence {
                onError(OpenAIError.apiError("Apple Intelligence is not available on Apple Watch"))
                return
            }
        #endif

        // Validate provider settings
        do {
            try validateProviderSettings(for: effectiveProvider, model: requestModel)
        } catch {
            onError(error)
            return
        }

        // Check GitHub Models rate limit before making request
        if effectiveProvider == .githubModels {
            if let rateLimitError = checkGitHubModelsRateLimit() {
                onError(OpenAIError.apiError(rateLimitError))
                return
            }
        }

        // Check if this model should use the responses API (not supported for GitHub Models)
        let endpointType = modelEndpointTypes[requestModel] ?? .chatCompletions
        if endpointType == .responses {
            if effectiveProvider == .githubModels {
                onError(OpenAIError.apiError("GitHub Models does not support the Responses API endpoint"))
                return
            }
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
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "❌ Invalid URL",
                metadata: ["url": apiURL]
            )
            onError(OpenAIError.invalidURL)
            return
        }

        let modelAPIKey = getAPIKey(for: requestModel)
        let needsAuth = effectiveProvider == .openai || effectiveProvider == .githubModels
        let isGitHubModels = effectiveProvider == .githubModels

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "📤 Building request",
            metadata: [
                "url": apiURL,
                "hasAPIKey": "\(!modelAPIKey.isEmpty)",
                "needsAuth": "\(needsAuth)",
                "isGitHubModels": "\(isGitHubModels)"
            ]
        )

        guard
            let request = OpenAIRequestBuilder.createChatCompletionsRequest(
                url: url,
                messages: messages,
                model: requestModel,
                stream: stream,
                tools: tools,
                apiKey: needsAuth ? modelAPIKey : "",
                isAzure: usesAzureEndpoint,
                isGitHubModels: isGitHubModels
            )
        else {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "❌ Failed to create request"
            )
            onError(OpenAIError.invalidRequest)
            return
        }

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "🌐 Starting stream request",
            metadata: [
                "url": url.absoluteString,
                "model": requestModel,
                "stream": "\(stream)"
            ]
        )

        if stream {
            let callbacks = StreamCallbacks(
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning
            )
            streamResponse(request: request, callbacks: callbacks, isMultiModelRequest: isMultiModelRequest)
        } else {
            nonStreamResponse(
                request: request, onChunk: onChunk, onComplete: onComplete, onError: onError,
                onToolCall: onToolCall, onReasoning: onReasoning
            )
        }
    }

    // MARK: - Multi-Model Parallel Requests

    /// Sends a message to multiple models in parallel using TaskGroup.
    /// Each model streams independently, and tool calls are deferred until the user selects a response.
    ///
    /// - Parameters:
    ///   - messages: The conversation history to send
    ///   - models: Array of model names to query in parallel
    ///   - temperature: Optional temperature override
    ///   - onChunk: Called with (modelName, chunk) for each streaming chunk
    ///   - onModelComplete: Called when a specific model finishes streaming
    ///   - onAllComplete: Called when all models have finished
    ///   - onError: Called with (modelName, error) when a model encounters an error
    ///   - onPendingToolCall: Called when a model requests a tool call (deferred until selection)
    ///   - onReasoning: Called with (modelName, reasoning) for reasoning content
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
    ) {
        // Validate we have models to query
        guard !models.isEmpty else {
            onError("", OpenAIError.missingModel)
            return
        }

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "🔀 Starting multi-model request",
            metadata: ["models": models.joined(separator: ", ")]
        )

        // Cancel any existing multi-model task
        multiModelTask?.cancel()

        // Use a TaskGroup to send requests in parallel
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for model in models {
                    group.addTask { [weak self] in
                        guard let self else { return }

                        // Check for cancellation before starting
                        if Task.isCancelled {
                            DiagnosticsLogger.log(
                                .openAIService,
                                level: .info,
                                message: "🛑 Multi-model task cancelled before starting model",
                                metadata: ["model": model]
                            )
                            return
                        }

                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            Task { @MainActor in
                                // Check for cancellation again on MainActor
                                if Task.isCancelled {
                                    continuation.resume()
                                    return
                                }

                                self.sendMessage(
                                    messages: messages,
                                    model: model,
                                    temperature: temperature,
                                    stream: true,
                                    tools: nil, // Tools disabled in multi-model mode - deferred
                                    conversationId: nil,
                                    isMultiModelRequest: true,
                                    onChunk: { chunk in
                                        onChunk(model, chunk)
                                    },
                                    onComplete: {
                                        DiagnosticsLogger.log(
                                            .openAIService,
                                            level: .info,
                                            message: "✅ Model completed in multi-model request",
                                            metadata: ["model": model]
                                        )
                                        onModelComplete(model)
                                        continuation.resume()
                                    },
                                    onError: { error in
                                        DiagnosticsLogger.log(
                                            .openAIService,
                                            level: .error,
                                            message: "❌ Model failed in multi-model request",
                                            metadata: ["model": model, "error": error.localizedDescription]
                                        )
                                        onError(model, error)
                                        continuation.resume()
                                    },
                                    onToolCall: nil, // Deferred - not executed during multi-model
                                    onToolCallRequested: { toolId, toolName, arguments in
                                        // Report the tool call as pending (will execute after selection)
                                        onPendingToolCall?(model, toolId, toolName, arguments)
                                    },
                                    onReasoning: { reasoning in
                                        onReasoning?(model, reasoning)
                                    }
                                )
                            }
                        }
                    }
                }
            }

            // Check for cancellation before calling onAllComplete
            if Task.isCancelled {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .info,
                    message: "🛑 Multi-model task cancelled, not calling onAllComplete"
                )
                return
            }

            // All models completed
            await MainActor.run {
                self.multiModelTask = nil
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .info,
                    message: "🏁 All models completed in multi-model request"
                )
                onAllComplete()
            }
        }
        multiModelTask = task
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
        switch statusCode {
        case 400:
            if requestURL?.absoluteString.lowercased().contains("openai.azure.com") == true {
                return "HTTP \(statusCode) - Invalid Azure deployment or API version (\(azureAPIVersion))."
            }
            return "HTTP \(statusCode) - Invalid request. Check your model name and parameters."
        case 429:
            return "Too many requests. Please wait a minute before trying again."
        case 403:
            if requestURL?.absoluteString.contains("models.github.ai") == true {
                return "Rate limit exceeded. GitHub Models has usage limits. Please wait a few minutes."
            }
            return "HTTP \(statusCode) - Forbidden. Check your API key permissions."
        case 500, 502, 503, 504:
            return "Server error (\(statusCode)). Please try again in a moment."
        default:
            return "HTTP \(statusCode)"
        }
    }

    /// Extracts error message from API response JSON, with special handling for rate limits
    private nonisolated func extractAPIErrorMessage(from data: Data, statusCode: Int) -> String {
        // Check for rate limit status codes first
        if statusCode == 429 {
            // Try to get more specific message, but provide friendly fallback
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                // Make the message more user-friendly
                if message.lowercased().contains("rate") || message.lowercased().contains("limit") {
                    return "Too many requests. Please wait a minute before trying again."
                }
                return message
            }
            return "Too many requests. Please wait a minute before trying again."
        }

        // Try to parse as JSON error response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI-style error: {"error": {"message": "..."}}
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                return message
            }
            // Simple message field: {"message": "..."}
            if let message = json["message"] as? String {
                return message
            }
            // GitHub Models style: {"error": "...", "error_description": "..."}
            if let errorDesc = json["error_description"] as? String {
                return errorDesc
            }
            if let error = json["error"] as? String {
                return error
            }
        }
        // Fall back to raw text if not JSON
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(200))
        }
        return "HTTP \(statusCode)"
    }

    /// Check if error body indicates rate limiting (for 403 responses)
    private nonisolated func isRateLimitErrorBody(_ data: Data) -> Bool {
        guard let errorString = String(data: data, encoding: .utf8) else { return false }
        let lowercased = errorString.lowercased()
        return lowercased.contains("rate limit") ||
            lowercased.contains("rate_limit") ||
            lowercased.contains("too many requests") ||
            lowercased.contains("ratelimit")
    }

    private func streamResponse(
        request: URLRequest,
        callbacks: StreamCallbacks,
        attempt: Int = 0,
        isMultiModelRequest: Bool = false
    ) {
        let session = urlSession

        // Cancel any existing stream task before starting a new one
        // Skip cancellation for multi-model requests to allow parallel streaming
        if currentStreamTask != nil && !isMultiModelRequest {
            DiagnosticsLogger.log(
                .openAIService,
                level: .info,
                message: "⚠️ Cancelling existing stream task before starting new one"
            )
            currentStreamTask?.cancel()
        }

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "🔄 Creating new stream task",
            metadata: ["url": request.url?.absoluteString ?? "unknown"]
        )

        let task = Task { [weak self] in
            guard let self else { return }
            var hasReceivedData = false

            do {
                // Use withTaskCancellationHandler to ensure proper cleanup
                try await withTaskCancellationHandler {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .error,
                            message: "❌ Invalid response type"
                        )
                        throw OpenAIError.invalidResponse
                    }

                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .info,
                        message: "📥 HTTP response received",
                        metadata: [
                            "statusCode": "\(httpResponse.statusCode)",
                            "url": request.url?.absoluteString ?? "unknown"
                        ]
                    )

                    guard httpResponse.statusCode == 200 else {
                        // Read the error response body for better error messages
                        var errorData = Data()
                        do {
                            for try await byte in bytes {
                                errorData.append(byte)
                                // Limit error body size to prevent memory issues
                                if errorData.count > 4096 { break }
                            }
                        } catch {
                            // Ignore errors reading error body
                        }

                        // Capture rate limit headers for GitHub Models (even on error)
                        if self.provider == .githubModels {
                            await MainActor.run {
                                GitHubOAuthService.shared.updateRateLimit(from: httpResponse)

                                // Check if this is a rate limit error (429 or 403 with rate limit message)
                                let statusCode = httpResponse.statusCode
                                if statusCode == 429 ||
                                    (statusCode == 403 && self.isRateLimitErrorBody(errorData))
                                {
                                    GitHubOAuthService.shared.updateRetryAfter(from: httpResponse)
                                }
                            }
                        }

                        let errorMessage: String = if !errorData.isEmpty {
                            self.extractAPIErrorMessage(from: errorData, statusCode: httpResponse.statusCode)
                        } else {
                            await MainActor.run {
                                self.getHTTPErrorMessage(
                                    statusCode: httpResponse.statusCode,
                                    requestURL: request.url
                                )
                            }
                        }

                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .error,
                            message: "❌ API error response",
                            metadata: [
                                "statusCode": "\(httpResponse.statusCode)",
                                "error": errorMessage,
                                "url": request.url?.absoluteString ?? "unknown"
                            ]
                        )
                        throw OpenAIError.apiError(errorMessage)
                    }

                    // Capture rate limit headers on success for GitHub Models
                    if self.provider == .githubModels {
                        await MainActor.run {
                            GitHubOAuthService.shared.updateRateLimit(from: httpResponse)
                            GitHubOAuthService.shared.clearRetryAfter()
                        }
                    }

                    var buffer = Data()
                    var currentToolCallBuffer: [String: Any] = [:]
                    var toolCallId = ""

                    // Batching buffers
                    var contentBuffer = ""
                    var reasoningBuffer = ""
                    var lastUpdateTime = CFAbsoluteTimeGetCurrent()
                    var totalBytesReceived = 0

                    for try await byte in bytes {
                        // Check for cancellation at each byte
                        try Task.checkCancellation()

                        hasReceivedData = true
                        totalBytesReceived += 1
                        buffer.append(byte)

                        // Log first byte received
                        if totalBytesReceived == 1 {
                            DiagnosticsLogger.log(
                                .openAIService,
                                level: .info,
                                message: "📦 First byte received from stream"
                            )
                        }

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
                                    let timeSinceLastUpdate = CFAbsoluteTimeGetCurrent() - lastUpdateTime
                                    if timeSinceLastUpdate > 0.05 || contentBuffer.count > 100 || reasoningBuffer.count > 100 {
                                        let contentToSend = contentBuffer
                                        let reasoningToSend = reasoningBuffer
                                        await MainActor.run {
                                            if !contentToSend.isEmpty { callbacks.onChunk(contentToSend) }
                                            if !reasoningToSend.isEmpty { callbacks.onReasoning?(reasoningToSend) }
                                        }
                                        contentBuffer = ""
                                        reasoningBuffer = ""
                                        lastUpdateTime = CFAbsoluteTimeGetCurrent()
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }

                    // Flush any remaining content
                    let contentToSend = contentBuffer
                    let reasoningToSend = reasoningBuffer
                    let receivedData = hasReceivedData
                    let bytesReceived = totalBytesReceived
                    await MainActor.run {
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .info,
                            message: "📊 Stream ended",
                            metadata: [
                                "totalBytesReceived": "\(bytesReceived)",
                                "hasReceivedData": "\(receivedData)",
                                "contentBufferLength": "\(contentToSend.count)",
                                "reasoningBufferLength": "\(reasoningToSend.count)"
                            ]
                        )

                        if !contentToSend.isEmpty { callbacks.onChunk(contentToSend) }
                        if !reasoningToSend.isEmpty { callbacks.onReasoning?(reasoningToSend) }
                        self.currentStreamTask = nil

                        // Log warning if no data was received but no error occurred
                        if !receivedData {
                            DiagnosticsLogger.log(
                                .openAIService,
                                level: .error,
                                message: "⚠️ Stream completed with no data received",
                                metadata: ["url": request.url?.absoluteString ?? "unknown"]
                            )
                        }

                        callbacks.onComplete()
                    }
                } onCancel: {
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .info,
                        message: "Stream task cancellation handler triggered"
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .info,
                        message: "Stream task cancelled via CancellationError"
                    )
                    self.currentStreamTask = nil
                }
            } catch {
                await handleStreamError(
                    error: error,
                    attempt: attempt,
                    hasReceivedData: hasReceivedData,
                    request: request,
                    callbacks: callbacks,
                    isMultiModelRequest: isMultiModelRequest
                )
            }
        }
        currentStreamTask = task
    }

    /// Parse Server-Sent Events data and deliver chunks (used for non-streaming fallback)
    private func parseSSEData(_ data: Data, callbacks: StreamCallbacks) {
        guard let text = String(data: data, encoding: .utf8) else {
            callbacks.onComplete()
            return
        }

        let lines = text.components(separatedBy: "\n")
        var currentToolCallBuffer: [String: Any] = [:]
        var toolCallId = ""

        for line in lines {
            // Skip empty lines and comments
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix(":") {
                continue
            }

            // Handle data: prefix
            if trimmedLine.hasPrefix("data:") {
                let jsonString = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                if jsonString == "[DONE]" {
                    callbacks.onComplete()
                    return
                }

                guard let jsonData = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first
                else {
                    continue
                }

                // Handle delta content
                if let delta = firstChoice["delta"] as? [String: Any] {
                    // Handle regular content
                    if let content = delta["content"] as? String, !content.isEmpty {
                        callbacks.onChunk(content)
                    }

                    // Handle reasoning content
                    if let reasoning = delta["reasoning"] as? String, !reasoning.isEmpty {
                        callbacks.onReasoning?(reasoning)
                    } else if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        callbacks.onReasoning?(reasoning)
                    }

                    // Handle tool calls
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for toolCall in toolCalls {
                            if let id = toolCall["id"] as? String {
                                toolCallId = id
                                currentToolCallBuffer = [:]
                            }
                            if let function = toolCall["function"] as? [String: Any] {
                                if let name = function["name"] as? String {
                                    currentToolCallBuffer["name"] = name
                                }
                                if let args = function["arguments"] as? String {
                                    let existing = currentToolCallBuffer["arguments"] as? String ?? ""
                                    currentToolCallBuffer["arguments"] = existing + args
                                }
                            }
                        }
                    }
                }

                // Check for finish_reason
                if let finishReason = firstChoice["finish_reason"] as? String {
                    if finishReason == "tool_calls",
                       let name = currentToolCallBuffer["name"] as? String,
                       let argsString = currentToolCallBuffer["arguments"] as? String
                    {
                        if let argsData = argsString.data(using: .utf8),
                           let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            callbacks.onToolCallRequested?(toolCallId, name, arguments)
                        }
                    }
                }
            }
        }

        callbacks.onComplete()
    }

    private func handleStreamError(
        error: Error,
        attempt: Int,
        hasReceivedData: Bool,
        request: URLRequest,
        callbacks: StreamCallbacks,
        isMultiModelRequest: Bool = false
    ) async {
        if shouldRetry(error: error, attempt: attempt, hasReceivedData: hasReceivedData) {
            // Get retry-after date for GitHub Models rate limits
            let retryAfterDate = (provider == .githubModels)
                ? await MainActor.run { GitHubOAuthService.shared.retryAfterDate }
                : nil

            DiagnosticsLogger.log(
                .openAIService,
                level: .info,
                message: "⚠️ Retrying stream request (attempt \(attempt + 1))",
                metadata: [
                    "error": error.localizedDescription,
                    "retryAfter": retryAfterDate?.description ?? "none"
                ]
            )
            await delay(for: attempt, retryAfterDate: retryAfterDate)
            await MainActor.run {
                streamResponse(
                    request: request,
                    callbacks: callbacks,
                    attempt: attempt + 1,
                    isMultiModelRequest: isMultiModelRequest
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

    #if !os(watchOS)
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

            // Cancel any existing Apple Intelligence task
            appleIntelligenceTask?.cancel()

            let task = Task {
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
            appleIntelligenceTask = task
        }
    #endif

    // Retry logic delegated to OpenAIRetryPolicy
    private func shouldRetry(error: Error, attempt: Int, hasReceivedData: Bool = false) -> Bool {
        OpenAIRetryPolicy.shouldRetry(
            error: error,
            attempt: attempt,
            hasReceivedData: hasReceivedData
        )
    }

    private func delay(for attempt: Int, retryAfterDate: Date? = nil) async {
        await OpenAIRetryPolicy.wait(for: attempt, retryAfterDate: retryAfterDate)
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
        case .openai, .githubModels:
            true
        }
    }

    var requiresAPIKey: Bool {
        providerRequiresAPIKey(provider)
    }

    var latestAzureAPIVersion: String { azureAPIVersion }

    private func isAPIKeyConfigured(for provider: AIProvider, model: String?) -> Bool {
        guard providerRequiresAPIKey(provider) else { return true }

        // For GitHub Models, check OAuth token first
        if provider == .githubModels {
            if GitHubOAuthService.shared.isAuthenticated,
               let token = GitHubOAuthService.shared.getAccessToken(),
               !token.isEmpty
            {
                return true
            }
        }

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

    /// Check if a specific model is ready to use (has API key or doesn't need one)
    func isModelConfigured(_ model: String) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return isAPIKeyConfigured }

        let modelProvider = modelProviders[trimmedModel] ?? provider
        return isAPIKeyConfigured(for: modelProvider, model: trimmedModel)
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
            #if os(iOS) || os(watchOS)
                // AIKit requires local Podman runtime, not available on iOS/watchOS
                if modelProviders[model] == .aikit {
                    return false
                }
            #endif
            #if os(watchOS)
                // Apple Intelligence requires on-device processing which isn't available on watchOS
                // The watch app makes API calls directly, not via iPhone relay
                if modelProviders[model] == .appleIntelligence {
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

// MARK: - Tool Management

extension OpenAIService {
    /// Returns all available tools for function calling, including built-in tools and MCP tools.
    /// This is a cross-platform method that returns Tavily on all platforms and MCP only on macOS.
    func getAllAvailableTools() -> [[String: Any]]? {
        var tools: [[String: Any]] = []

        // Add Tavily web search if available
        #if os(watchOS)
            // On watchOS, use synced settings stored in OpenAIService
            if tavilyEnabled, !tavilyAPIKey.isEmpty {
                tools.append(tavilyToolDefinition())
            }
        #else
            if TavilyService.shared.isAvailable {
                tools.append(TavilyService.shared.toolDefinition())
            }
        #endif

        // Add MCP tools (macOS only)
        #if os(macOS)
            let mcpTools = MCPServerManager.shared.getEnabledToolsAsOpenAIFunctions()
            tools.append(contentsOf: mcpTools)
        #endif

        return tools.isEmpty ? nil : tools
    }

    /// Checks if a tool call is for a built-in tool (like web_search) that we handle internally.
    /// - Parameter toolName: The name of the tool being called
    /// - Returns: True if this is a built-in tool we handle, false if it should be routed to MCP
    func isBuiltInTool(_ toolName: String) -> Bool {
        #if os(watchOS)
            return toolName == "web_search"
        #else
            return toolName == TavilyService.toolName
        #endif
    }

    /// Executes a built-in tool call and returns the result.
    /// - Parameters:
    ///   - toolName: The name of the tool to execute
    ///   - arguments: The arguments passed to the tool
    /// - Returns: The tool execution result as a string
    func executeBuiltInTool(name toolName: String, arguments: [String: Any]) async -> String {
        #if os(watchOS)
            switch toolName {
            case "web_search":
                return await executeWatchTavilySearch(arguments: arguments)
            default:
                return "Error: Unknown built-in tool '\(toolName)'"
            }
        #else
            switch toolName {
            case TavilyService.toolName:
                await TavilyService.shared.executeToolCall(arguments: arguments)
            default:
                "Error: Unknown built-in tool '\(toolName)'"
            }
        #endif
    }

    /// Executes a built-in tool call and returns both the result and citations (if any).
    /// - Parameters:
    ///   - toolName: The name of the tool to execute
    ///   - arguments: The arguments passed to the tool
    /// - Returns: Tuple of (result string, optional citations for inline display)
    func executeBuiltInToolWithCitations(
        name toolName: String,
        arguments: [String: Any]
    ) async -> (String, [CitationReference]?) {
        #if os(watchOS)
            // watchOS doesn't support citations yet
            let result = await executeBuiltInTool(name: toolName, arguments: arguments)
            return (result, nil)
        #else
            switch toolName {
            case TavilyService.toolName:
                let (result, citations) = await TavilyService.shared.executeToolCallWithCitations(arguments: arguments)
                return (result, citations.isEmpty ? nil : citations)
            default:
                return ("Error: Unknown built-in tool '\(toolName)'", nil)
            }
        #endif
    }

    #if os(watchOS)
        /// Returns the Tavily tool definition for watchOS
        private func tavilyToolDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": "web_search",
                    "description": "Search the web for current information. Use for recent events, prices, weather, or time-sensitive topics.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "The search query"
                            ],
                            "topic": [
                                "type": "string",
                                "enum": ["general", "news", "finance"],
                                "description": "Topic: news, finance, or general"
                            ],
                            "max_results": [
                                "type": "integer",
                                "description": "Results to return (1-5). Default 3.",
                                "minimum": 1,
                                "maximum": 5
                            ]
                        ] as [String: Any],
                        "required": ["query"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        /// Executes a Tavily web search on watchOS using the synced API key
        private func executeWatchTavilySearch(arguments: [String: Any]) async -> String {
            guard !tavilyAPIKey.isEmpty else {
                return "Error: Web search not configured. Please configure on iPhone."
            }

            guard let query = arguments["query"] as? String else {
                return "Error: Missing 'query' parameter for web search"
            }

            let topic = (arguments["topic"] as? String) ?? "general"
            let maxResults = min(max((arguments["max_results"] as? Int) ?? 3, 1), 5)

            // Build the Tavily API request
            let endpoint = "https://api.tavily.com/search"
            guard let url = URL(string: endpoint) else {
                return "Error: Invalid search endpoint"
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "api_key": tavilyAPIKey,
                "query": query,
                "topic": topic,
                "search_depth": "basic",
                "max_results": maxResults,
                "include_answer": true,
                "include_raw_content": false,
                "include_images": false
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await urlSession.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    return "Error: Invalid response from search"
                }

                switch httpResponse.statusCode {
                case 200:
                    // Parse and format the response
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return "Error: Failed to parse search results"
                    }
                    return formatTavilyResponse(json, maxResults: maxResults)
                case 401:
                    return "Error: Invalid API key. Please reconfigure on iPhone."
                case 429:
                    return "Error: Rate limit exceeded. Please try again later."
                default:
                    return "Error: Search failed (HTTP \(httpResponse.statusCode))"
                }
            } catch {
                return "Error searching the web: \(error.localizedDescription)"
            }
        }

        /// Formats the Tavily API response for the model
        private func formatTavilyResponse(_ json: [String: Any], maxResults: Int) -> String {
            var output = ""

            // Add AI-generated answer if available
            if let answer = json["answer"] as? String, !answer.isEmpty {
                output += "**Answer:** \(answer)\n\n"
            }

            // Add search results
            if let results = json["results"] as? [[String: Any]], !results.isEmpty {
                output += "**Sources:**\n"
                for (index, result) in results.prefix(maxResults).enumerated() {
                    let title = result["title"] as? String ?? "Untitled"
                    let url = result["url"] as? String ?? ""
                    var content = result["content"] as? String ?? ""

                    // Truncate long content
                    if content.count > 150 {
                        content = String(content.prefix(150)) + "..."
                    }

                    output += "\(index + 1). [\(title)](\(url))\n   \(content)\n\n"
                }
            } else {
                output = "No results found."
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    #endif
}

// Keychain Helper

// swiftlint:enable type_body_length
