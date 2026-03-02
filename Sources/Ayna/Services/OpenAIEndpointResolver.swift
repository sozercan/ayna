//
//  OpenAIEndpointResolver.swift
//  ayna
//
//  Created on 11/24/25.
//

import Foundation

/// Stateless helper that resolves API endpoint URLs for various providers.
/// Extracts the complex URL-building logic from AIService for better testability.
enum OpenAIEndpointResolver {
    // MARK: - Configuration

    struct EndpointConfig {
        let modelName: String
        let provider: AIProvider
        let customEndpoint: String?
        let azureAPIVersion: String

        init(
            modelName: String,
            provider: AIProvider,
            customEndpoint: String? = nil,
            azureAPIVersion: String = "2025-04-01-preview"
        ) {
            self.modelName = modelName
            self.provider = provider
            self.customEndpoint = customEndpoint
            self.azureAPIVersion = azureAPIVersion
        }
    }

    // MARK: - Default Endpoints

    private static let openAIChatURL = "https://api.openai.com/v1/chat/completions"
    private static let openAIResponsesURL = "https://api.openai.com/v1/responses"
    private static let openAIImagesURL = "https://api.openai.com/v1/images/generations"
    private static let openAIImageEditsURL = "https://api.openai.com/v1/images/edits"
    private static let githubModelsChatURL = "https://models.github.ai/inference/chat/completions"

    // MARK: - Public API

    /// Resolves the chat completions endpoint URL.
    static func chatCompletionsURL(for config: EndpointConfig) -> String {
        switch config.provider {
        case .openai:
            resolveOpenAIChatURL(config)
        case .githubModels:
            githubModelsChatURL
        case .appleIntelligence:
            "" // Not used for Apple Intelligence
        case .anthropic:
            "" // Anthropic uses its own endpoint resolver
        }
    }

    /// Resolves the responses API endpoint URL.
    static func responsesURL(for config: EndpointConfig) -> String {
        switch config.provider {
        case .openai:
            resolveOpenAIResponsesURL(config)
        case .githubModels:
            "" // GitHub Models doesn't support the Responses API
        case .appleIntelligence:
            "" // Not used for Apple Intelligence
        case .anthropic:
            "" // Anthropic uses its own endpoint resolver
        }
    }

    /// Resolves the image generation endpoint URL.
    static func imageGenerationURL(for config: EndpointConfig) -> String {
        guard config.provider == .openai || config.provider == .githubModels else {
            return "" // Only OpenAI and GitHub Models support image generation
        }

        // GitHub Models doesn't support image generation yet
        if config.provider == .githubModels {
            return ""
        }

        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIImagesURL
        }

        if isAzureEndpoint(customEndpoint) {
            return azureImagesURL(
                baseEndpoint: customEndpoint,
                deployment: config.modelName,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(customEndpoint, path: "/v1/images/generations")
    }

    /// Resolves the image editing endpoint URL.
    static func imageEditURL(for config: EndpointConfig) -> String {
        guard config.provider == .openai else {
            return "" // Only OpenAI supports image editing
        }

        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIImageEditsURL
        }

        if isAzureEndpoint(customEndpoint) {
            return azureImageEditsURL(
                baseEndpoint: customEndpoint,
                deployment: config.modelName,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(customEndpoint, path: "/v1/images/edits")
    }

    /// Checks if the given endpoint is an Azure OpenAI endpoint.
    static func isAzureEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint else { return false }
        return endpoint.lowercased().contains("openai.azure.com")
    }

    // MARK: - Private Helpers

    private static func resolveOpenAIChatURL(_ config: EndpointConfig) -> String {
        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIChatURL
        }

        if isAzureEndpoint(customEndpoint) {
            return azureChatCompletionsURL(
                baseEndpoint: customEndpoint,
                deployment: config.modelName,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(customEndpoint, path: "/v1/chat/completions")
    }

    private static func resolveOpenAIResponsesURL(_ config: EndpointConfig) -> String {
        guard let customEndpoint = config.customEndpoint,
              !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return openAIResponsesURL
        }

        if isAzureEndpoint(customEndpoint) {
            return azureResponsesURL(
                baseEndpoint: customEndpoint,
                apiVersion: config.azureAPIVersion
            )
        }

        return appendPathIfNeeded(customEndpoint, path: "/v1/responses")
    }

    // MARK: - URL Building Helpers

    private static func sanitizedBaseEndpoint(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func percentEncodedDeployment(_ deployment: String) -> String {
        deployment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deployment
    }

    private static func azureChatCompletionsURL(
        baseEndpoint: String,
        deployment: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return "\(cleanBase)/openai/deployments/\(encodedDeployment)/chat/completions?api-version=\(apiVersion)"
    }

    private static func azureResponsesURL(
        baseEndpoint: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        // Azure OpenAI Responses API doesn't use the /v1/ prefix
        return "\(cleanBase)/openai/responses?api-version=\(apiVersion)"
    }

    private static func azureImagesURL(
        baseEndpoint: String,
        deployment: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return "\(cleanBase)/openai/deployments/\(encodedDeployment)/images/generations?api-version=\(apiVersion)"
    }

    private static func azureImageEditsURL(
        baseEndpoint: String,
        deployment: String,
        apiVersion: String
    ) -> String {
        let cleanBase = sanitizedBaseEndpoint(baseEndpoint)
        let encodedDeployment = percentEncodedDeployment(deployment)
        return "\(cleanBase)/openai/deployments/\(encodedDeployment)/images/edits?api-version=\(apiVersion)"
    }

    private static func appendPathIfNeeded(_ endpoint: String, path: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(endpoint)
        if cleanBase.hasSuffix(path) || cleanBase.contains(path) {
            return cleanBase
        }
        return "\(cleanBase)\(path.hasPrefix("/") ? "" : "/")\(path)"
    }
}
