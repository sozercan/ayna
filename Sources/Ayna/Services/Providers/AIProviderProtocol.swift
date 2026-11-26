import Foundation

struct AIProviderRequestConfig: Sendable {
    let model: String
    let apiKey: String
    let customEndpoint: String?
    let azureAPIVersion: String

    let maxTokens: Int?

    let temperature: Double?

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

protocol AIProviderProtocol: AnyObject, Sendable {
    @MainActor
    var providerType: AIProvider { get }

    @MainActor
    var requiresAPIKey: Bool { get }

    @MainActor
    func sendMessage(
        messages: [Message],
        config: AIProviderRequestConfig,
        stream: Bool,
        tools: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    )

    @MainActor
    func cancelRequest()

    @MainActor
    func validateConfiguration(_ config: AIProviderRequestConfig) -> Error?
}

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
