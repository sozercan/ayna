//
//  AIProviderProtocol.swift
//  ayna
//
//  Created on 12/11/25.
//

import Foundation

/// Configuration for an AI provider request
struct AIProviderRequestConfig: Sendable {
    let model: String
    let apiKey: String
    let customEndpoint: String?
    let azureAPIVersion: String

    /// Maximum tokens to generate (optional, provider-specific defaults apply)
    let maxTokens: Int?

    /// Temperature for response generation (optional, provider defaults apply)
    let temperature: Double?

    /// Budget tokens for extended thinking (Anthropic only)
    let thinkingBudget: Int?

    init(
        model: String,
        apiKey: String,
        customEndpoint: String? = nil,
        azureAPIVersion: String = "2025-04-01-preview",
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        thinkingBudget: Int? = nil
    ) {
        self.model = model
        self.apiKey = apiKey
        self.customEndpoint = customEndpoint
        self.azureAPIVersion = azureAPIVersion
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinkingBudget = thinkingBudget
    }
}

/// Callbacks for streaming AI responses
struct AIProviderStreamCallbacks: Sendable {
    let onChunk: @Sendable (String) -> Void
    let onComplete: @Sendable () -> Void
    let onError: @Sendable (Error) -> Void
    let onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?
    let onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    let onReasoning: (@Sendable (String) -> Void)?

    init(
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = nil,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) {
        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onError = onError
        self.onToolCall = onToolCall
        self.onToolCallRequested = onToolCallRequested
        self.onReasoning = onReasoning
    }
}

/// Protocol defining the interface for AI providers
///
/// Each provider (OpenAI, GitHub Models, etc.) implements this protocol
/// to handle chat completions with their specific API requirements.
@MainActor
protocol AIProviderProtocol: AnyObject, Sendable {
    /// The provider type this implementation handles
    var providerType: AIProvider { get }

    /// Whether this provider requires an API key
    var requiresAPIKey: Bool { get }

    /// Send a chat message to the provider
    ///
    /// - Parameters:
    ///   - messages: The conversation history
    ///   - config: Provider-specific configuration
    ///   - stream: Whether to stream the response
    ///   - tools: Optional tool definitions for function calling
    ///   - callbacks: Callbacks for handling the response
    func sendMessage(
        messages: [Message],
        config: AIProviderRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    )

    /// Cancel any in-progress request
    func cancelRequest()

    /// Check if the provider is ready to handle requests
    ///
    /// - Parameters:
    ///   - config: The request configuration to validate
    /// - Returns: nil if ready, or an error describing why not ready
    func validateConfiguration(_ config: AIProviderRequestConfig) -> Error?
}

/// Default implementations for AIProviderProtocol
extension AIProviderProtocol {
    func validateConfiguration(_ config: AIProviderRequestConfig) -> Error? {
        if requiresAPIKey, config.apiKey.isEmpty {
            return AIService.AIError.missingAPIKey
        }
        if config.model.isEmpty {
            return AIService.AIError.missingModel
        }
        return nil
    }
}

/// Provider factory for creating provider instances
enum AIProviderFactory {
    /// Create a provider instance for the given type
    ///
    /// - Parameters:
    ///   - type: The provider type to create
    ///   - urlSession: URLSession to use for network requests
    /// - Returns: An instance of the appropriate provider
    @MainActor
    static func createProvider(for type: AIProvider, urlSession: URLSession) -> AIProviderProtocol {
        switch type {
        case .openai:
            OpenAIProvider(urlSession: urlSession)
        case .githubModels:
            GitHubModelsProvider(urlSession: urlSession)
        case .appleIntelligence:
            // Apple Intelligence is handled separately by its dedicated service
            // Return OpenAI provider as fallback (should not be used)
            OpenAIProvider(urlSession: urlSession)
        case .anthropic:
            AnthropicProvider(urlSession: urlSession)
        }
    }
}
