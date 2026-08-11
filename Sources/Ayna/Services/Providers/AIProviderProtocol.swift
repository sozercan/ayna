//
//  AIProviderProtocol.swift
//  ayna
//
//  Created on 12/11/25.
//

import Foundation

/// Anthropic-specific reasoning controls for a request.
///
/// Adaptive thinking lets the model decide when and how much to think. Legacy
/// enabled thinking reserves a fixed token budget and can opt in to the
/// interleaved-thinking beta explicitly for models that support it.
enum AnthropicReasoningConfiguration: Equatable, Sendable {
    enum Effort: String, Codable, CaseIterable, Sendable {
        case low
        case medium
        case high
        case xhigh
        case max
    }

    enum Display: String, Codable, CaseIterable, Sendable {
        case summarized
        case omitted
    }

    case disabled(effort: Effort? = nil)
    case adaptive(
        effort: Effort? = nil,
        display: Display? = nil
    )
    case enabled(
        budgetTokens: Int,
        interleaved: Bool = false,
        effort: Effort? = nil,
        display: Display? = nil
    )

    var effort: Effort? {
        switch self {
        case let .disabled(effort):
            effort
        case let .adaptive(effort, _), let .enabled(_, _, effort, _):
            effort
        }
    }

    var display: Display? {
        switch self {
        case .disabled:
            nil
        case let .adaptive(_, display), let .enabled(_, _, _, display):
            display
        }
    }

    var usesInterleavedThinkingBeta: Bool {
        guard case let .enabled(_, interleaved, _, _) = self else {
            return false
        }
        return interleaved
    }
}

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

    /// Typed Anthropic reasoning controls. When present, this takes precedence
    /// over the legacy `thinkingBudget` compatibility parameter.
    let anthropicReasoning: AnthropicReasoningConfiguration?

    init(
        model: String,
        apiKey: String,
        customEndpoint: String? = nil,
        azureAPIVersion: String = "2025-04-01-preview",
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        thinkingBudget: Int? = nil,
        anthropicReasoning: AnthropicReasoningConfiguration? = nil
    ) {
        self.model = model
        self.apiKey = apiKey
        self.customEndpoint = customEndpoint
        self.azureAPIVersion = azureAPIVersion
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinkingBudget = thinkingBudget
        self.anthropicReasoning = anthropicReasoning ?? thinkingBudget.map {
            .enabled(budgetTokens: $0)
        }
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
    let onReasoningContinuation: (@Sendable (ReasoningContinuationState) -> Void)?

    init(
        onChunk: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onToolCall: (@Sendable (String, String, [String: Any]) async -> String)? = nil,
        onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        onReasoningContinuation: (@Sendable (ReasoningContinuationState) -> Void)? = nil
    ) {
        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onError = onError
        self.onToolCall = onToolCall
        self.onToolCallRequested = onToolCallRequested
        self.onReasoning = onReasoning
        self.onReasoningContinuation = onReasoningContinuation
    }
}

/// Protocol defining the request-scoped provider interface used by Anthropic.
///
/// OpenAI-compatible providers are routed directly through `AIService`; this
/// abstraction remains for Anthropic request ownership and test injection.
protocol AIProviderProtocol: AnyObject, Sendable {
    /// The provider type this implementation handles
    @MainActor
    var providerType: AIProvider { get }

    /// Whether this provider requires an API key
    @MainActor
    var requiresAPIKey: Bool { get }

    /// Send a chat message to the provider
    ///
    /// - Parameters:
    ///   - messages: The conversation history
    ///   - config: Provider-specific configuration
    ///   - stream: Whether to stream the response
    ///   - tools: Optional tool definitions for function calling
    ///   - callbacks: Callbacks for handling the response
    @MainActor
    func sendMessage(
        messages: [Message],
        config: AIProviderRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    )

    /// Cancel any in-progress request
    @MainActor
    func cancelRequest()

    /// Check if the provider is ready to handle requests
    ///
    /// - Parameters:
    ///   - config: The request configuration to validate
    /// - Returns: nil if ready, or an error describing why not ready
    @MainActor
    func validateConfiguration(_ config: AIProviderRequestConfig) -> Error?
}

/// Default implementations for AIProviderProtocol
extension AIProviderProtocol {
    @MainActor
    func validateConfiguration(_ config: AIProviderRequestConfig) -> Error? {
        if requiresAPIKey, config.apiKey.isEmpty {
            return AynaError.missingAPIKey(provider: String(describing: providerType))
        }
        if config.model.isEmpty {
            return AynaError.noModelSelected
        }
        return nil
    }
}
