//
//  OpenAIService.swift
//  ayna
//
//  Created on 11/2/25.
//

import Combine
import Foundation
import os

// swiftlint:disable file_length
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

    @Published var customModels: [String] {
        didSet {
            AppPreferences.storage.set(customModels, forKey: "customModels")
        }
    }

    @Published var modelProviders: [String: AIProvider] {
        didSet {
            let encodedDict = modelProviders.mapValues { $0.rawValue }
            AppPreferences.storage.set(encodedDict, forKey: "modelProviders")
        }
    }

    @Published var modelEndpointTypes: [String: APIEndpointType] {
        didSet {
            let encodedDict = modelEndpointTypes.mapValues { $0.rawValue }
            AppPreferences.storage.set(encodedDict, forKey: "modelEndpointTypes")
        }
    }

    @Published var modelEndpoints: [String: String] {
        didSet {
            AppPreferences.storage.set(modelEndpoints, forKey: "modelEndpoints")
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
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120 // 2 minutes
            config.timeoutIntervalForResource = 300 // 5 minutes
            self.urlSession = URLSession(configuration: config)
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
        guard let endpoint else { return false }
        return endpoint.lowercased().contains("openai.azure.com")
    }

    private func sanitizedBaseEndpoint(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func percentEncodedDeployment(_ deployment: String) -> String {
        deployment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deployment
    }

    private func azureChatCompletionsURL(baseEndpoint: String, deployment: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return
            "\(cleanBase)/openai/deployments/\(encodedDeployment)/chat/completions?api-version=\(azureAPIVersion)"
    }

    private func azureResponsesURL(baseEndpoint: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        return "\(cleanBase)/openai/v1/responses?api-version=\(azureAPIVersion)"
    }

    private func azureImagesURL(baseEndpoint: String, deployment: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return
            "\(cleanBase)/openai/deployments/\(encodedDeployment)/images/generations?api-version=\(azureAPIVersion)"
    }

    private func appendPathIfNeeded(_ endpoint: String, path: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(endpoint)
        if cleanBase.hasSuffix(path) || cleanBase.contains(path) {
            return cleanBase
        }
        return "\(cleanBase)\(path.hasPrefix("/") ? "" : "/")\(path)"
    }

    // Get API key for a specific model, falling back to global key if not set
    func getAPIKey(for model: String?) -> String {
        guard let model else { return apiKey }
        return modelAPIKeys[model] ?? apiKey
    }

    private func getAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) -> String {
        let effectiveProvider = provider ?? self.provider

        // Check for custom endpoint first (for OpenAI provider)
        if effectiveProvider == .openai {
            let modelName = deploymentName ?? selectedModel
            if let (customEndpoint, normalizedModel) = customEndpoint(for: modelName) {
                if isAzureEndpoint(customEndpoint) {
                    return azureChatCompletionsURL(baseEndpoint: customEndpoint, deployment: normalizedModel)
                }
                return appendPathIfNeeded(customEndpoint, path: "/v1/chat/completions")
            }
        }

        switch effectiveProvider {
        case .openai:
            return openAIURL
        case .appleIntelligence:
            return "" // Not used for Apple Intelligence
        case .aikit:
            // AIKit provides OpenAI-compatible endpoint on localhost
            return "http://localhost:8080/v1/chat/completions"
        }
    }

    private func getResponsesAPIURL(deploymentName: String? = nil, provider: AIProvider? = nil) -> String {
        let effectiveProvider = provider ?? self.provider

        // Check for custom endpoint first (for OpenAI provider)
        if effectiveProvider == .openai {
            let modelName = deploymentName ?? selectedModel
            if let (customEndpoint, _) = customEndpoint(for: modelName) {
                if isAzureEndpoint(customEndpoint) {
                    return azureResponsesURL(baseEndpoint: customEndpoint)
                }
                return appendPathIfNeeded(customEndpoint, path: "/v1/responses")
            }
        }

        switch effectiveProvider {
        case .openai:
            return "https://api.openai.com/v1/responses"
        case .appleIntelligence:
            return "" // Not used for Apple Intelligence
        case .aikit:
            // AIKit provides OpenAI-compatible endpoint on localhost
            return "http://localhost:8080/v1/responses"
        }
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

    // Image generation handles standard OpenAI endpoints plus Azure-compatible custom endpoints.
    // swiftlint:disable:next function_body_length
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
        let modelAPIKey = getAPIKey(for: requestModel)

        guard !modelAPIKey.isEmpty else {
            onError(OpenAIError.missingAPIKey)
            return
        }

        let effectiveProvider = modelProviders[requestModel] ?? provider

        guard effectiveProvider == .openai else {
            onError(OpenAIError.unsupportedProvider)
            return
        }

        let endpointInfo = customEndpoint(for: requestModel)
        let usesAzureEndpoint = endpointInfo.flatMap { isAzureEndpoint($0.endpoint) } ?? false

        let imageURL: String =
            if let endpointInfo {
                if usesAzureEndpoint {
                    azureImagesURL(baseEndpoint: endpointInfo.endpoint, deployment: endpointInfo.model)
                } else {
                    appendPathIfNeeded(endpointInfo.endpoint, path: "/v1/images/generations")
                }
            } else {
                "https://api.openai.com/v1/images/generations"
            }

        guard let url = URL(string: imageURL) else {
            onError(OpenAIError.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if usesAzureEndpoint {
            if !modelAPIKey.isEmpty {
                request.setValue(modelAPIKey, forHTTPHeaderField: "api-key")
            }
        } else if !modelAPIKey.isEmpty {
            request.setValue("Bearer \(modelAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] =
            if usesAzureEndpoint {
                [
                    "prompt": prompt,
                    "size": imageSize,
                    "quality": imageQuality,
                    "n": 1
                ]
            } else {
                [
                    "prompt": prompt,
                    "model": requestModel,
                    "size": imageSize,
                    "quality": imageQuality,
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

        urlSession.dataTask(with: request) { [weak self] data, _, error in
            if let error {
                DispatchQueue.main.async {
                    if self?.shouldRetry(error: error, attempt: attempt) == true {
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .info,
                            message: "⚠️ Retrying image generation (attempt \(attempt + 1))",
                            metadata: ["error": error.localizedDescription]
                        )
                        Task {
                            await self?.delay(for: attempt)
                            await MainActor.run {
                                self?.generateImage(
                                    prompt: prompt,
                                    model: model,
                                    onComplete: onComplete,
                                    onError: onError,
                                    attempt: attempt + 1
                                )
                            }
                        }
                        return
                    }
                    onError(error)
                }
                return
            }

            guard let data else {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .error,
                    message: "No data received"
                )
                DispatchQueue.main.async {
                    onError(OpenAIError.noData)
                }
                return
            }

            // Parse response
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Check for error response
                    if let errorDict = json["error"] as? [String: Any],
                       let code = errorDict["code"] as? String,
                       let message = errorDict["message"] as? String
                    {
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .error,
                            message: "API error",
                            metadata: ["code": code, "message": message]
                        )
                        DispatchQueue.main.async {
                            if code == "contentFilter" {
                                onError(OpenAIError.contentFiltered(message))
                            } else {
                                onError(OpenAIError.apiError(message))
                            }
                        }
                        return
                    }

                    // Parse successful response: { "data": [{ "b64_json": "..." }] } or { "data": [{ "url": "..." }] }
                    if let dataArray = json["data"] as? [[String: Any]],
                       let firstItem = dataArray.first
                    {
                        if let b64String = firstItem["b64_json"] as? String,
                           let imageData = Data(base64Encoded: b64String)
                        {
                            DispatchQueue.main.async {
                                onComplete(imageData)
                            }
                        } else if let urlString = firstItem["url"] as? String,
                                  let url = URL(string: urlString)
                        {
                            // Download image from URL if b64_json is missing
                            Task {
                                do {
                                    let (data, _) = try await URLSession.shared.data(from: url)
                                    await MainActor.run {
                                        onComplete(data)
                                    }
                                } catch {
                                    await MainActor.run {
                                        onError(error)
                                    }
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                onError(OpenAIError.invalidResponse)
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            onError(OpenAIError.invalidResponse)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    onError(error)
                }
            }
        }.resume()
    }

    // MARK: - Helper Methods for sendMessage

    private func buildMessagePayload(from message: Message) -> [String: Any] {
        var payload: [String: Any] = ["role": message.role.rawValue]

        // Handle tool role messages (tool results)
        if message.role == .tool {
            payload["content"] = message.content
            // Tool messages need tool_call_id from the assistant's tool call
            if let toolCalls = message.toolCalls, let firstToolCall = toolCalls.first {
                payload["tool_call_id"] = firstToolCall.id
            }
            return payload
        }

        // Handle assistant messages with tool calls
        if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            // Assistant message that made tool calls
            if !message.content.isEmpty {
                payload["content"] = message.content
            } else {
                payload["content"] = "" // Empty content when only tool calls
            }

            // Add tool_calls array
            let toolCallsArray = toolCalls.compactMap { toolCall -> [String: Any]? in
                // Convert AnyCodable arguments to JSON string safely
                var argumentsDict: [String: Any] = [:]
                for (key, anyCodable) in toolCall.arguments {
                    argumentsDict[key] = anyCodable.value
                }

                guard let argumentsJSON = try? JSONSerialization.data(withJSONObject: argumentsDict, options: []),
                      let argumentsString = String(data: argumentsJSON, encoding: .utf8)
                else {
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .error,
                        message: "Failed to encode arguments for tool call",
                        metadata: ["tool": toolCall.toolName]
                    )
                    return nil
                }

                return [
                    "id": toolCall.id,
                    "type": "function",
                    "function": [
                        "name": toolCall.toolName,
                        "arguments": argumentsString
                    ]
                ]
            }

            if !toolCallsArray.isEmpty {
                payload["tool_calls"] = toolCallsArray
            }
            return payload
        }

        // Check if message has attachments (multimodal content)
        if let attachments = message.attachments, !attachments.isEmpty {
            var contentArray: [[String: Any]] = []

            // Add text content if present
            if !message.content.isEmpty {
                contentArray.append([
                    "type": "text",
                    "text": message.content
                ])
            }

            // Add image attachments
            for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                if let data = attachment.content {
                    let base64Image = data.base64EncodedString()
                    contentArray.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(attachment.mimeType);base64,\(base64Image)"
                        ],
                    ])
                }
            }

            payload["content"] = contentArray
        } else {
            // Simple text content
            payload["content"] = message.content
        }

        return payload
    }

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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set authentication header based on provider
        let modelAPIKey = getAPIKey(for: requestModel)
        switch effectiveProvider {
        case .openai:
            if usesAzureEndpoint {
                if !modelAPIKey.isEmpty {
                    request.setValue(modelAPIKey, forHTTPHeaderField: "api-key")
                }
            } else if !modelAPIKey.isEmpty {
                request.setValue("Bearer \(modelAPIKey)", forHTTPHeaderField: "Authorization")
            }
        case .appleIntelligence, .aikit:
            break // No authentication needed
        }

        // Build message payloads using helper method
        let messagePayloads: [[String: Any]] = messages.map { buildMessagePayload(from: $0) }

        let body: [String: Any] = [
            "messages": messagePayloads,
            "model": requestModel,
            "stream": stream
        ]

        var finalBody = body

        // Add tools if provided
        if let tools, !tools.isEmpty {
            finalBody["tools"] = tools
            finalBody["tool_choice"] = "auto"
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: finalBody)

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

    private func buildResponsesInput(from messages: [Message]) -> [[String: Any]] {
        var inputArray: [[String: Any]] = []

        for message in messages {
            if message.role == .system {
                continue
            }

            var messageItem: [String: Any] = [
                "type": "message",
                "role": message.role.rawValue
            ]

            var contentArray: [[String: Any]] = []

            if !message.content.isEmpty {
                let contentType = message.role == .user ? "input_text" : "output_text"
                contentArray.append([
                    "type": contentType,
                    "text": message.content
                ])
            }

            if let attachments = message.attachments, !attachments.isEmpty, message.role == .user {
                for attachment in attachments where attachment.mimeType.starts(with: "image/") {
                    if let data = attachment.content {
                        let base64Data = data.base64EncodedString()
                        contentArray.append([
                            "type": "input_image",
                            "image_url": "data:\(attachment.mimeType);base64,\(base64Data)",
                        ])
                    }
                }
            }

            messageItem["content"] = contentArray
            inputArray.append(messageItem)
        }

        return inputArray
    }

    private func deliverResponsesOutput(
        _ outputArray: [[String: Any]],
        onChunk: @escaping (String) -> Void,
        onReasoning: ((String) -> Void)?
    ) {
        for outputItem in outputArray {
            let itemType = outputItem["type"] as? String

            if itemType == "reasoning" {
                if let summaryArray = outputItem["summary"] as? [[String: Any]],
                   let onReasoning
                {
                    for summaryPart in summaryArray {
                        if let type = summaryPart["type"] as? String,
                           type == "summary_text",
                           let text = summaryPart["text"] as? String
                        {
                            onReasoning(text)
                        }
                    }
                }
            } else if itemType == "message",
                      let content = outputItem["content"] as? [[String: Any]]
            {
                for contentPart in content {
                    if let type = contentPart["type"] as? String,
                       type == "output_text",
                       let text = contentPart["text"] as? String
                    {
                        onChunk(text)
                    }
                }
            }
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if usesAzureEndpoint {
            if !modelAPIKey.isEmpty {
                request.setValue(modelAPIKey, forHTTPHeaderField: "api-key")
            }
        } else if !modelAPIKey.isEmpty {
            request.setValue("Bearer \(modelAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let inputArray = buildResponsesInput(from: messages)

        let body: [String: Any] = [
            "model": model,
            "input": inputArray,
            "reasoning": ["summary": "auto"],
            "text": ["verbosity": "medium"]
        ]

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData
        } catch {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "❌ Failed to encode Responses API body",
                metadata: ["model": model]
            )
            onError(error)
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
                        self?.deliverResponsesOutput(outputArray, onChunk: onChunk, onReasoning: onReasoning)
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

    private struct StreamCallbacks {
        let onChunk: @Sendable (String) -> Void
        let onComplete: @Sendable () -> Void
        let onError: @Sendable (Error) -> Void
        let onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?
        let onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
        let onReasoning: (@Sendable (String) -> Void)?
    }

    private struct StreamLineResult {
        let shouldComplete: Bool
        let toolCallBuffer: [String: Any]
        let toolCallId: String
        let content: String?
        let reasoning: String?
    }

    private func getHTTPErrorMessage(statusCode: Int, requestURL: URL?) -> String {
        if statusCode == 400 {
            if requestURL?.absoluteString.lowercased().contains("openai.azure.com") == true {
                return "HTTP \(statusCode) - Invalid Azure deployment or API version (\(azureAPIVersion))."
            }
            return "HTTP \(statusCode) - Invalid request. Check your model name and parameters."
        }

        return "HTTP \(statusCode)"
    }

    private func extractTextSegments(
        from contentField: Any,
        source: String,
        metadata: [String: String] = [:]
    ) -> [String] {
        if let stringContent = contentField as? String {
            return [stringContent]
        }

        if let contentArray = contentField as? [[String: Any]] {
            DiagnosticsLogger.log(
                .openAIService,
                level: .debug,
                message: "🧩 Received structured content array",
                metadata: mergedMetadata(metadata, additions: ["source": source, "parts": "\(contentArray.count)"])
            )

            var segments: [String] = []
            for (index, part) in contentArray.enumerated() {
                guard let type = part["type"] as? String else {
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .debug,
                        message: "⚠️ Structured content part missing type",
                        metadata: mergedMetadata(metadata, additions: ["source": source, "index": "\(index)"])
                    )
                    continue
                }

                if let text = part["text"] as? String, !text.isEmpty {
                    segments.append(text)
                    continue
                }

                if let nested = part["content"] {
                    let nestedMetadata = mergedMetadata(
                        metadata,
                        additions: ["source": source, "parentType": type, "parentIndex": "\(index)"]
                    )
                    segments.append(contentsOf: extractTextSegments(from: nested, source: source, metadata: nestedMetadata))
                    continue
                }

                DiagnosticsLogger.log(
                    .openAIService,
                    level: .debug,
                    message: "⚠️ Structured content part missing text",
                    metadata: mergedMetadata(
                        metadata,
                        additions: [
                            "source": source,
                            "type": type,
                            "index": "\(index)"
                        ]
                    )
                )
            }

            return segments
        }

        if let singlePart = contentField as? [String: Any] {
            return extractTextSegments(from: [singlePart], source: source, metadata: metadata)
        }

        if !(contentField is NSNull) {
            DiagnosticsLogger.log(
                .openAIService,
                level: .debug,
                message: "⚠️ Unsupported content payload",
                metadata: mergedMetadata(
                    metadata,
                    additions: ["source": source, "payloadType": "\(type(of: contentField))"]
                )
            )
        }

        return []
    }

    private func mergedMetadata(
        _ metadata: [String: String],
        additions: [String: String]
    ) -> [String: String] {
        var combined = metadata
        for (key, value) in additions {
            combined[key] = value
        }
        return combined
    }

    private func processStreamLine(
        _ line: String,
        toolCallBuffer: [String: Any],
    toolCallId: String,
    onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
    onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
    onReasoning _: (@Sendable (String) -> Void)? = nil
    ) async -> StreamLineResult {
        var updatedToolCallBuffer = toolCallBuffer
        var updatedToolCallId = toolCallId
        var extractedContent: String?
        var extractedReasoning: String?
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedLine.hasPrefix("data: ") {
            let jsonString = String(trimmedLine.dropFirst(6))

            if jsonString == "[DONE]" {
                return StreamLineResult(
                    shouldComplete: true,
                    toolCallBuffer: updatedToolCallBuffer,
                    toolCallId: updatedToolCallId,
                    content: nil,
                    reasoning: nil
                ) // Signal completion
            }

            if let jsonData = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let delta = firstChoice["delta"] as? [String: Any]
            {
                // Handle regular content
                if let contentField = delta["content"], !(contentField is NSNull) {
                    let textSegments = extractTextSegments(
                        from: contentField,
                        source: "stream.chat",
                        metadata: ["phase": "delta"]
                    )

                    if !textSegments.isEmpty {
                        extractedContent = textSegments.joined()
                    }
                }

                // Handle reasoning content (for o1/o3 models)
                let reasoningContent =
                    delta["reasoning_content"] as? String
                        ?? delta["reasoning"] as? String
                        ?? delta["thought"] as? String

                if let reasoning = reasoningContent {
                    extractedReasoning = reasoning
                }

                // Handle tool calls
                if let toolCalls = delta["tool_calls"] as? [[String: Any]],
                   let toolCall = toolCalls.first
                {
                    if let id = toolCall["id"] as? String {
                        updatedToolCallId = id
                    }
                    if let function = toolCall["function"] as? [String: Any] {
                        if let name = function["name"] as? String {
                            updatedToolCallBuffer["name"] = name
                        }
                        if let argsChunk = function["arguments"] as? String {
                            let currentArgs = updatedToolCallBuffer["arguments"] as? String ?? ""
                            updatedToolCallBuffer["arguments"] = currentArgs + argsChunk
                        }
                    }
                }

                // Check if tool call is complete
                if let finishReason = firstChoice["finish_reason"] as? String,
                   finishReason == "tool_calls",
                   let toolName = updatedToolCallBuffer["name"] as? String,
                   let argsString = updatedToolCallBuffer["arguments"] as? String,
                   let argsData = argsString.data(using: .utf8),
                   let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    let currentToolCallId = updatedToolCallId

                    // Notify about tool call request (for proper flow)
                    if let onToolCallRequested {
                        await MainActor.run {
                            onToolCallRequested(currentToolCallId, toolName, arguments)
                        }
                    }
                    // Legacy support: still execute inline if old callback provided
                    else if let onToolCall {
                        let result = await onToolCall(currentToolCallId, toolName, arguments)
                        let toolOutput = "\n\n[Tool: \(toolName)]\n\(result)\n"
                        extractedContent = (extractedContent ?? "") + toolOutput
                    }

                    // Clear buffer for next tool call
                    updatedToolCallBuffer = [:]
                    updatedToolCallId = ""
                }
            }
        }
        return StreamLineResult(
            shouldComplete: false,
            toolCallBuffer: updatedToolCallBuffer,
            toolCallId: updatedToolCallId,
            content: extractedContent,
            reasoning: extractedReasoning
        )
    }

    private func streamResponse(
        request: URLRequest,
        callbacks: StreamCallbacks,
        attempt: Int = 0
    ) {
        let task = Task {
            var hasReceivedData = false
            do {
                let (bytes, response) = try await urlSession.bytes(for: request)

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
                var toolCallBuffer: [String: Any] = [:]
                var toolCallId = ""

                // Batching buffers
                var contentBuffer = ""
                var reasoningBuffer = ""
                var lastUpdateTime = Date()

                for try await byte in bytes {
                    hasReceivedData = true
                    // Check if task was cancelled
                    if Task.isCancelled {
                        DiagnosticsLogger.log(
                            .openAIService,
                            level: .info,
                            message: "Stream task cancelled; stopping iteration"
                        )
                        await MainActor.run {
                            self.currentStreamTask = nil
                        }
                        return
                    }

                    buffer.append(byte)

                    // Check if we have a newline (UTF-8: 0x0A)
                    if byte == 0x0A {
                        if let line = String(data: buffer, encoding: .utf8) {
                            let result = await processStreamLine(
                                line,
                                toolCallBuffer: toolCallBuffer,
                                toolCallId: toolCallId,
                                onToolCall: callbacks.onToolCall,
                                onToolCallRequested: callbacks.onToolCallRequested
                            )
                            toolCallBuffer = result.toolCallBuffer
                            toolCallId = result.toolCallId

                            if let content = result.content {
                                contentBuffer += content
                            }
                            if let reasoning = result.reasoning {
                                reasoningBuffer += reasoning
                            }

                            if result.shouldComplete {
                                // Flush remaining buffers
                                await MainActor.run {
                                    if !contentBuffer.isEmpty { callbacks.onChunk(contentBuffer) }
                                    if !reasoningBuffer.isEmpty { callbacks.onReasoning?(reasoningBuffer) }
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
                await MainActor.run {
                    if !contentBuffer.isEmpty { callbacks.onChunk(contentBuffer) }
                    if !reasoningBuffer.isEmpty { callbacks.onReasoning?(reasoningBuffer) }
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
                            let textSegments = (self?.extractTextSegments(
                                from: contentField,
                                source: "nonstream.chat",
                                metadata: ["phase": "final"]
                            )) ?? []

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

    // Retry configuration
    private let maxRetries = 3
    private let initialRetryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 8.0

    private func shouldRetry(error: Error, attempt: Int, hasReceivedData: Bool = false) -> Bool {
        guard attempt < maxRetries else { return false }
        guard !hasReceivedData else { return false }

        // Check for cancellation
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return false
        }
        if (error as NSError).code == NSURLErrorCancelled {
            return false
        }

        // Check for specific error types to retry
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        if let openAIError = error as? OpenAIError {
            switch openAIError {
            case let .apiError(message):
                if message.contains("429") || message.contains("500") || message.contains("502") || message.contains("503") || message.contains("504") {
                    return true
                }
            default:
                return false
            }
        }

        return false
    }

    private func delay(for attempt: Int) async {
        let delay = min(initialRetryDelay * pow(2.0, Double(attempt)), maxRetryDelay)
        let jitter = Double.random(in: 0 ... 0.1)
        try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
    }

    enum OpenAIError: LocalizedError {
        case missingAPIKey
        case missingModel
        case invalidResponse
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
}

// Keychain Helper

// swiftlint:enable type_body_length
