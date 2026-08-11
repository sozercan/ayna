import Foundation

/// User intent for requesting provider reasoning.
///
/// Automatic mode only sends reasoning parameters when Ayna can identify a
/// first-party model and request dialect conservatively. Explicit mode allows
/// custom endpoints and deployment aliases to opt in without relying on their
/// names. Provider Default omits controls, while Off emits a provider disable
/// directive only when Ayna knows that the configured model supports one.
enum ReasoningActivationMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case disabled
    case explicitlyDisabled
    case enabled

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .disabled: "Provider Default"
        case .explicitlyDisabled: "Off"
        case .enabled: "On"
        }
    }
}

/// Union of reasoning effort values currently used by supported providers.
/// Individual models may accept only a subset, so automatic mode never invents
/// an effort value and explicit selections are treated as user overrides.
enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var displayName: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Maximum"
        }
    }

    static let anthropicValues: [ReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
}

enum OpenAIReasoningMode: String, Codable, CaseIterable, Sendable {
    case standard
    case pro

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .pro: "Pro"
        }
    }
}

enum OpenAIReasoningContext: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case currentTurn = "current_turn"
    case allTurns = "all_turns"

    var displayName: String {
        switch self {
        case .automatic: "Model Default"
        case .currentTurn: "Current Turn"
        case .allTurns: "All Turns"
        }
    }

    var wireValue: String? {
        self == .automatic ? nil : rawValue
    }
}

enum ReasoningSummaryPreference: String, Codable, CaseIterable, Sendable {
    case none
    case automatic = "auto"
    case concise
    case detailed

    var displayName: String {
        switch self {
        case .none: "None"
        case .automatic: "Automatic"
        case .concise: "Concise"
        case .detailed: "Detailed"
        }
    }

    var wireValue: String? {
        self == .none ? nil : rawValue
    }
}

enum AnthropicThinkingMode: String, Codable, CaseIterable, Sendable {
    case adaptive
    case extended

    var displayName: String {
        switch self {
        case .adaptive: "Adaptive"
        case .extended: "Extended (Legacy)"
        }
    }
}

enum AnthropicThinkingDisplay: String, Codable, CaseIterable, Sendable {
    case providerDefault
    case summarized
    case omitted

    var displayName: String {
        switch self {
        case .providerDefault: "Provider Default"
        case .summarized: "Show Summary"
        case .omitted: "Hide Summary"
        }
    }

    var wireValue: String? {
        self == .providerDefault ? nil : rawValue
    }
}

/// Persisted reasoning settings for one configured model.
struct ModelReasoningConfiguration: Codable, Equatable, Sendable {
    static let minimumLegacyBudgetTokens = 1024
    static let defaultLegacyBudgetTokens = 4096

    var activation: ReasoningActivationMode
    var effort: ReasoningEffort?
    var openAIMode: OpenAIReasoningMode?
    var openAIContext: OpenAIReasoningContext
    var summary: ReasoningSummaryPreference
    var anthropicMode: AnthropicThinkingMode
    var anthropicDisplay: AnthropicThinkingDisplay
    var legacyBudgetTokens: Int

    init(
        activation: ReasoningActivationMode = .automatic,
        effort: ReasoningEffort? = nil,
        openAIMode: OpenAIReasoningMode? = nil,
        openAIContext: OpenAIReasoningContext = .automatic,
        summary: ReasoningSummaryPreference = .automatic,
        anthropicMode: AnthropicThinkingMode = .adaptive,
        anthropicDisplay: AnthropicThinkingDisplay = .providerDefault,
        legacyBudgetTokens: Int = defaultLegacyBudgetTokens
    ) {
        self.activation = activation
        self.effort = effort
        self.openAIMode = openAIMode
        self.openAIContext = openAIContext
        self.summary = summary
        self.anthropicMode = anthropicMode
        self.anthropicDisplay = anthropicDisplay
        self.legacyBudgetTokens = max(legacyBudgetTokens, Self.minimumLegacyBudgetTokens)
    }

    static let automatic = ModelReasoningConfiguration()
}

/// Provider request dialect selected after combining persisted user intent with
/// the configured provider, endpoint, and conservative first-party inference.
enum ResolvedReasoningDialect: String, Codable, Equatable, Sendable {
    case openAIChat
    case openAIResponses
    case anthropicDisabled
    case anthropicAdaptive
    case anthropicExtended
}

struct ResolvedReasoningConfiguration: Codable, Equatable, Sendable {
    let dialect: ResolvedReasoningDialect
    let effort: ReasoningEffort?
    let openAIMode: OpenAIReasoningMode?
    let openAIContext: OpenAIReasoningContext
    let summary: ReasoningSummaryPreference
    let anthropicDisplay: AnthropicThinkingDisplay
    let legacyBudgetTokens: Int

    var requiresOpaqueStateReplay: Bool {
        switch dialect {
        case .openAIResponses, .anthropicAdaptive, .anthropicExtended:
            true
        case .openAIChat, .anthropicDisabled:
            false
        }
    }
}

/// Request controls that Ayna can safely expose for one configured model.
///
/// Automatic mode returns a profile only for conservatively recognized
/// first-party models. Explicit mode falls back to provider-level controls so
/// custom deployment names and compatible gateways can opt in deliberately.
struct ReasoningCapabilityProfile: Equatable, Sendable {
    let dialect: ResolvedReasoningDialect
    let supportedEfforts: [ReasoningEffort]
    let supportedSummaries: [ReasoningSummaryPreference]
    let supportedOpenAIContexts: [OpenAIReasoningContext]
    let supportedOpenAIModes: [OpenAIReasoningMode]
    let supportedAnthropicModes: [AnthropicThinkingMode]
    let providerDefaultBehavior: ReasoningProviderDefaultBehavior
    let explicitDisableSupport: ReasoningExplicitDisableSupport
    let chatCompletionsToolPolicy: OpenAIChatCompletionsToolPolicy

    init(
        dialect: ResolvedReasoningDialect,
        supportedEfforts: [ReasoningEffort],
        supportedSummaries: [ReasoningSummaryPreference],
        supportedOpenAIContexts: [OpenAIReasoningContext],
        supportedOpenAIModes: [OpenAIReasoningMode],
        supportedAnthropicModes: [AnthropicThinkingMode],
        providerDefaultBehavior: ReasoningProviderDefaultBehavior = .unknown,
        explicitDisableSupport: ReasoningExplicitDisableSupport = .unknown,
        chatCompletionsToolPolicy: OpenAIChatCompletionsToolPolicy = .unrestricted
    ) {
        self.dialect = dialect
        self.supportedEfforts = supportedEfforts
        self.supportedSummaries = supportedSummaries
        self.supportedOpenAIContexts = supportedOpenAIContexts
        self.supportedOpenAIModes = supportedOpenAIModes
        self.supportedAnthropicModes = supportedAnthropicModes
        self.providerDefaultBehavior = providerDefaultBehavior
        self.explicitDisableSupport = explicitDisableSupport
        self.chatCompletionsToolPolicy = chatCompletionsToolPolicy
    }

    func allowsChatCompletionsTools(with effort: ReasoningEffort?) -> Bool {
        chatCompletionsToolPolicy.allowsTools(with: effort)
    }

    func chatCompletionsEffort(
        requested effort: ReasoningEffort?,
        hasTools: Bool
    ) -> ReasoningEffort? {
        guard hasTools else { return effort }
        switch chatCompletionsToolPolicy {
        case .providerDefined, .unrestricted:
            return effort
        case let .requiresExplicitEffort(requiredEffort):
            return requiredEffort
        }
    }
}

enum ReasoningProviderDefaultBehavior: String, Codable, Equatable, Sendable {
    case unknown
    case disabled
    case enabled
    case alwaysEnabled
}

enum ReasoningExplicitDisableSupport: Equatable, Sendable {
    case unknown
    case unsupported
    case supported
    case supportedWithEfforts([ReasoningEffort])
}

enum OpenAIChatCompletionsToolPolicy: Equatable, Sendable {
    case providerDefined
    case unrestricted
    case requiresExplicitEffort(ReasoningEffort)

    func allowsTools(with effort: ReasoningEffort?) -> Bool {
        switch self {
        case .providerDefined, .unrestricted:
            true
        case let .requiresExplicitEffort(requiredEffort):
            effort == requiredEffort
        }
    }
}

enum ReasoningCapabilityResolver {
    static func capabilities(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        endpoint: String?,
        configuration: ModelReasoningConfiguration
    ) -> ReasoningCapabilityProfile? {
        guard endpointType != .imageGeneration,
              provider != .appleIntelligence
        else {
            return nil
        }

        switch configuration.activation {
        case .automatic:
            return automaticCapabilities(
                model: model,
                provider: provider,
                endpointType: endpointType,
                endpoint: endpoint
            )
        case .enabled:
            return explicitlyEnabledCapabilities(
                model: model,
                provider: provider,
                endpointType: endpointType,
                anthropicMode: configuration.anthropicMode
            )
        case .disabled, .explicitlyDisabled:
            return nil
        }
    }

    static func modelPolicy(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        anthropicMode: AnthropicThinkingMode = .adaptive
    ) -> ReasoningCapabilityProfile? {
        knownCapabilities(
            model: model,
            provider: provider,
            endpointType: endpointType,
            anthropicMode: anthropicMode
        )
    }

    static func resolve(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        endpoint: String?,
        configuration: ModelReasoningConfiguration
    ) -> ResolvedReasoningConfiguration? {
        guard endpointType != .imageGeneration,
              provider != .appleIntelligence
        else {
            return nil
        }

        if configuration.activation == .explicitlyDisabled {
            return explicitDisableConfiguration(
                model: model,
                provider: provider,
                endpointType: endpointType,
                requestedEffort: configuration.effort,
                anthropicMode: configuration.anthropicMode,
                anthropicDisplay: configuration.anthropicDisplay,
                legacyBudgetTokens: configuration.legacyBudgetTokens
            )
        }

        let capabilities: ReasoningCapabilityProfile? = switch configuration.activation {
        case .disabled, .explicitlyDisabled:
            nil
        case .enabled:
            explicitlyEnabledCapabilities(
                model: model,
                provider: provider,
                endpointType: endpointType,
                anthropicMode: configuration.anthropicMode
            )
        case .automatic:
            automaticCapabilities(
                model: model,
                provider: provider,
                endpointType: endpointType,
                endpoint: endpoint
            )
        }

        guard let capabilities else { return nil }
        let effort = configuration.effort.flatMap {
            capabilities.supportedEfforts.contains($0) ? $0 : nil
        }
        let summary = safeSummary(configuration.summary, capabilities: capabilities)
        let openAIContext = !capabilities.supportedOpenAIContexts.contains(configuration.openAIContext)
            ? .automatic
            : configuration.openAIContext
        let openAIMode = configuration.openAIMode.flatMap {
            capabilities.supportedOpenAIModes.contains($0) ? $0 : nil
        }

        return ResolvedReasoningConfiguration(
            dialect: capabilities.dialect,
            effort: effort,
            openAIMode: openAIMode,
            openAIContext: openAIContext,
            summary: summary,
            anthropicDisplay: configuration.anthropicDisplay,
            legacyBudgetTokens: max(
                configuration.legacyBudgetTokens,
                ModelReasoningConfiguration.minimumLegacyBudgetTokens
            )
        )
    }

    private static func explicitDisableConfiguration(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        requestedEffort: ReasoningEffort?,
        anthropicMode: AnthropicThinkingMode,
        anthropicDisplay: AnthropicThinkingDisplay,
        legacyBudgetTokens: Int
    ) -> ResolvedReasoningConfiguration? {
        guard let capabilities = knownCapabilities(
            model: model,
            provider: provider,
            endpointType: endpointType,
            anthropicMode: anthropicMode
        ) else {
            return nil
        }

        let effort: ReasoningEffort?
        switch capabilities.explicitDisableSupport {
        case .supported:
            effort = provider == .openai
                ? ReasoningEffort.none
                : requestedEffort.flatMap { capabilities.supportedEfforts.contains($0) ? $0 : nil }
        case let .supportedWithEfforts(supportedEfforts):
            effort = requestedEffort.flatMap { supportedEfforts.contains($0) ? $0 : nil }
        case .unknown, .unsupported:
            return nil
        }

        return ResolvedReasoningConfiguration(
            dialect: provider == .anthropic ? .anthropicDisabled : capabilities.dialect,
            effort: effort,
            openAIMode: nil,
            openAIContext: .automatic,
            summary: .none,
            anthropicDisplay: anthropicDisplay,
            legacyBudgetTokens: max(
                legacyBudgetTokens,
                ModelReasoningConfiguration.minimumLegacyBudgetTokens
            )
        )
    }

    private static func safeSummary(
        _ requested: ReasoningSummaryPreference,
        capabilities: ReasoningCapabilityProfile
    ) -> ReasoningSummaryPreference {
        if capabilities.supportedSummaries.contains(requested) {
            return requested
        }
        if capabilities.supportedSummaries.contains(.automatic) {
            return .automatic
        }
        return .none
    }

    private static func explicitlyEnabledCapabilities(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        anthropicMode: AnthropicThinkingMode
    ) -> ReasoningCapabilityProfile? {
        if let knownCapabilities = knownCapabilities(
            model: model,
            provider: provider,
            endpointType: endpointType,
            anthropicMode: anthropicMode
        ) {
            return knownCapabilities
        }

        // A recognized first-party model must not fall through to the generic
        // compatible-provider profile when its documented endpoint is not
        // supported. Custom deployment names and aliases remain explicit opt-ins.
        if provider == .openai, isKnownOpenAIModel(model) {
            return nil
        }

        return providerFallbackCapabilities(
            provider: provider,
            endpointType: endpointType,
            anthropicMode: anthropicMode
        )
    }

    private static func providerFallbackCapabilities(
        provider: AIProvider,
        endpointType: APIEndpointType,
        anthropicMode: AnthropicThinkingMode
    ) -> ReasoningCapabilityProfile? {
        switch provider {
        case .openai:
            switch endpointType {
            case .chatCompletions:
                ReasoningCapabilityProfile(
                    dialect: .openAIChat,
                    supportedEfforts: ReasoningEffort.allCases,
                    supportedSummaries: [],
                    supportedOpenAIContexts: [],
                    supportedOpenAIModes: [],
                    supportedAnthropicModes: [],
                    providerDefaultBehavior: .unknown,
                    explicitDisableSupport: .unknown,
                    chatCompletionsToolPolicy: .providerDefined
                )
            case .responses:
                ReasoningCapabilityProfile(
                    dialect: .openAIResponses,
                    supportedEfforts: ReasoningEffort.allCases,
                    supportedSummaries: ReasoningSummaryPreference.allCases,
                    supportedOpenAIContexts: OpenAIReasoningContext.allCases,
                    supportedOpenAIModes: OpenAIReasoningMode.allCases,
                    supportedAnthropicModes: [],
                    providerDefaultBehavior: .unknown,
                    explicitDisableSupport: .unknown,
                    chatCompletionsToolPolicy: .providerDefined
                )
            case .imageGeneration: nil
            }
        case .anthropic:
            ReasoningCapabilityProfile(
                dialect: anthropicMode == .adaptive ? .anthropicAdaptive : .anthropicExtended,
                supportedEfforts: ReasoningEffort.anthropicValues,
                supportedSummaries: [],
                supportedOpenAIContexts: [],
                supportedOpenAIModes: [],
                supportedAnthropicModes: AnthropicThinkingMode.allCases,
                providerDefaultBehavior: .unknown,
                explicitDisableSupport: .unknown,
                chatCompletionsToolPolicy: .providerDefined
            )
        case .appleIntelligence:
            nil
        }
    }

    private static func automaticCapabilities(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        endpoint: String?
    ) -> ReasoningCapabilityProfile? {
        switch provider {
        case .openai:
            guard isOfficialOpenAIEndpoint(endpoint) else {
                return nil
            }
            return knownOpenAICapabilities(model: model, endpointType: endpointType)
        case .anthropic:
            guard isOfficialAnthropicEndpoint(endpoint) else {
                return nil
            }
            return knownAnthropicCapabilities(model: model, requestedMode: nil)
        case .appleIntelligence:
            return nil
        }
    }

    private static func knownCapabilities(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        anthropicMode: AnthropicThinkingMode
    ) -> ReasoningCapabilityProfile? {
        switch provider {
        case .openai:
            knownOpenAICapabilities(model: model, endpointType: endpointType)
        case .anthropic:
            knownAnthropicCapabilities(model: model, requestedMode: anthropicMode)
        case .appleIntelligence:
            nil
        }
    }

    private static func knownOpenAICapabilities(
        model: String,
        endpointType: APIEndpointType
    ) -> ReasoningCapabilityProfile? {
        guard endpointType != .imageGeneration else { return nil }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return knownGPT5Capabilities(model: normalized, endpointType: endpointType) ??
            knownOpenAIReasoningSeriesCapabilities(model: normalized, endpointType: endpointType)
    }

    // The exact-ID switch intentionally keeps the documented GPT-5 catalog together.
    // swiftlint:disable:next function_body_length
    private static func knownGPT5Capabilities(
        model: String,
        endpointType: APIEndpointType
    ) -> ReasoningCapabilityProfile? {
        switch model {
        case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.none, .low, .medium, .high, .xhigh, .max],
                responsesEfforts: [.none, .low, .medium, .high, .xhigh, .max],
                responseContexts: OpenAIReasoningContext.allCases,
                responseModes: OpenAIReasoningMode.allCases,
                providerDefaultBehavior: .enabled,
                chatToolPolicy: .requiresExplicitEffort(.none)
            )

        case "gpt-5.6-cyber":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [],
                supportsSummary: false,
                providerDefaultBehavior: .alwaysEnabled
            )

        case "gpt-5.5", "gpt-5.5-2026-04-23":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.none, .low, .medium, .high, .xhigh],
                responsesEfforts: [.none, .low, .medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "gpt-5.5-pro", "gpt-5.5-pro-2026-04-23":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "gpt-5.4",
             "gpt-5.4-2026-03-05",
             "gpt-5.4-mini",
             "gpt-5.4-mini-2026-03-17",
             "gpt-5.4-nano",
             "gpt-5.4-nano-2026-03-17":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.none, .low, .medium, .high, .xhigh],
                responsesEfforts: [.none, .low, .medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .disabled
            )

        case "gpt-5.4-pro", "gpt-5.4-pro-2026-03-05":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "gpt-5.3-codex":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.low, .medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "gpt-5.2", "gpt-5.2-2025-12-11":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.none, .low, .medium, .high, .xhigh],
                responsesEfforts: [.none, .low, .medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .disabled
            )

        case "gpt-5.2-pro", "gpt-5.2-pro-2025-12-11":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "gpt-5.2-codex":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.low, .medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "gpt-5.1", "gpt-5.1-2025-11-13":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.none, .low, .medium, .high],
                responsesEfforts: [.none, .low, .medium, .high],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .disabled
            )

        case "gpt-5.1-codex", "gpt-5.1-codex-mini":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.none, .low, .medium, .high],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .disabled
            )

        case "gpt-5.1-codex-max":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.none, .low, .medium, .high, .xhigh],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .disabled
            )

        case "gpt-5",
             "gpt-5-2025-08-07",
             "gpt-5-mini",
             "gpt-5-mini-2025-08-07",
             "gpt-5-nano",
             "gpt-5-nano-2025-08-07":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.minimal, .low, .medium, .high],
                responsesEfforts: [.minimal, .low, .medium, .high],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "gpt-5-pro", "gpt-5-pro-2025-10-06":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.high],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .alwaysEnabled
            )

        case "gpt-5-codex":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.low, .medium, .high],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        default:
            nil
        }
    }

    private static func knownOpenAIReasoningSeriesCapabilities(
        model: String,
        endpointType: APIEndpointType
    ) -> ReasoningCapabilityProfile? {
        switch model {
        case "o1-mini", "o1-mini-2024-09-12":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [],
                responsesEfforts: nil,
                supportsSummary: false,
                providerDefaultBehavior: .alwaysEnabled
            )

        case "o1", "o1-2024-12-17":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.low, .medium, .high],
                responsesEfforts: [.low, .medium, .high],
                supportsSummary: false,
                providerDefaultBehavior: .enabled
            )

        case "o1-pro", "o1-pro-2025-03-19":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [],
                supportsSummary: false,
                providerDefaultBehavior: .alwaysEnabled
            )

        case "o3", "o3-2025-04-16":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.low, .medium, .high],
                responsesEfforts: [.low, .medium, .high],
                providerDefaultBehavior: .enabled
            )

        case "o3-mini", "o3-mini-2025-01-31":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.low, .medium, .high],
                responsesEfforts: [.low, .medium, .high],
                providerDefaultBehavior: .enabled
            )

        case "o3-pro", "o3-pro-2025-06-10":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [],
                supportsSummary: false,
                providerDefaultBehavior: .alwaysEnabled
            )

        case "o4-mini", "o4-mini-2025-04-16":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: [.low, .medium, .high],
                responsesEfforts: [.low, .medium, .high],
                providerDefaultBehavior: .enabled
            )

        case "codex-mini-latest":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [.low, .medium, .high],
                responseContexts: [.automatic, .currentTurn],
                providerDefaultBehavior: .enabled
            )

        case "o3-deep-research",
             "o3-deep-research-2025-06-26",
             "o4-mini-deep-research",
             "o4-mini-deep-research-2025-06-26":
            openAIProfile(
                endpointType: endpointType,
                chatEfforts: nil,
                responsesEfforts: [],
                supportsSummary: false,
                providerDefaultBehavior: .alwaysEnabled
            )

        default:
            nil
        }
    }

    private static func isKnownOpenAIModel(_ model: String) -> Bool {
        knownOpenAICapabilities(model: model, endpointType: .chatCompletions) != nil ||
            knownOpenAICapabilities(model: model, endpointType: .responses) != nil
    }

    private static func openAIProfile(
        endpointType: APIEndpointType,
        chatEfforts: [ReasoningEffort]?,
        responsesEfforts: [ReasoningEffort]?,
        supportsSummary: Bool = true,
        responseContexts: [OpenAIReasoningContext] = [],
        responseModes: [OpenAIReasoningMode] = [],
        providerDefaultBehavior: ReasoningProviderDefaultBehavior = .unknown,
        chatToolPolicy: OpenAIChatCompletionsToolPolicy = .unrestricted
    ) -> ReasoningCapabilityProfile? {
        let dialect: ResolvedReasoningDialect
        let efforts: [ReasoningEffort]
        let summaries: [ReasoningSummaryPreference]
        let contexts: [OpenAIReasoningContext]
        let modes: [OpenAIReasoningMode]

        switch endpointType {
        case .chatCompletions:
            guard let chatEfforts else { return nil }
            dialect = .openAIChat
            efforts = chatEfforts
            summaries = []
            contexts = []
            modes = []
        case .responses:
            guard let responsesEfforts else { return nil }
            dialect = .openAIResponses
            efforts = responsesEfforts
            summaries = supportsSummary ? [.none, .automatic] : []
            contexts = responseContexts
            modes = responseModes
        case .imageGeneration:
            return nil
        }

        return ReasoningCapabilityProfile(
            dialect: dialect,
            supportedEfforts: efforts,
            supportedSummaries: summaries,
            supportedOpenAIContexts: contexts,
            supportedOpenAIModes: modes,
            supportedAnthropicModes: [],
            providerDefaultBehavior: providerDefaultBehavior,
            explicitDisableSupport: efforts.contains(.none) ? .supported : .unsupported,
            chatCompletionsToolPolicy: dialect == .openAIChat ? chatToolPolicy : .unrestricted
        )
    }

    private enum AnthropicThinkingSupport: Equatable {
        case adaptiveOnly
        case adaptiveAndExtended
        case extendedOnly

        var modes: [AnthropicThinkingMode] {
            switch self {
            case .adaptiveOnly:
                [.adaptive]
            case .adaptiveAndExtended:
                AnthropicThinkingMode.allCases
            case .extendedOnly:
                [.extended]
            }
        }

        func resolvedMode(requested: AnthropicThinkingMode?) -> AnthropicThinkingMode {
            if let requested, modes.contains(requested) {
                return requested
            }
            return self == .extendedOnly ? .extended : .adaptive
        }
    }

    private static func knownAnthropicCapabilities(
        model: String,
        requestedMode: AnthropicThinkingMode?
    ) -> ReasoningCapabilityProfile? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let support: AnthropicThinkingSupport
        let efforts: [ReasoningEffort]
        let providerDefaultBehavior: ReasoningProviderDefaultBehavior
        let explicitDisableSupport: ReasoningExplicitDisableSupport

        switch normalized {
        case "claude-fable-5",
             "claude-mythos-5":
            support = .adaptiveOnly
            efforts = [.low, .medium, .high, .xhigh, .max]
            providerDefaultBehavior = .alwaysEnabled
            explicitDisableSupport = .unsupported

        case "claude-mythos-preview":
            support = .adaptiveAndExtended
            efforts = [.low, .medium, .high, .max]
            providerDefaultBehavior = .alwaysEnabled
            explicitDisableSupport = .unsupported

        case "claude-opus-5":
            support = .adaptiveOnly
            efforts = [.low, .medium, .high, .xhigh, .max]
            providerDefaultBehavior = .enabled
            explicitDisableSupport = .supportedWithEfforts([.low, .medium, .high])

        case "claude-sonnet-5":
            support = .adaptiveOnly
            efforts = [.low, .medium, .high, .xhigh, .max]
            providerDefaultBehavior = .enabled
            explicitDisableSupport = .supported

        case "claude-opus-4-8",
             "claude-opus-4-7":
            support = .adaptiveOnly
            efforts = [.low, .medium, .high, .xhigh, .max]
            providerDefaultBehavior = .disabled
            explicitDisableSupport = .supported

        case "claude-opus-4-6",
             "claude-sonnet-4-6":
            support = .adaptiveAndExtended
            efforts = [.low, .medium, .high, .max]
            providerDefaultBehavior = .disabled
            explicitDisableSupport = .supported

        case "claude-opus-4-5",
             "claude-opus-4-5-20251101":
            support = .extendedOnly
            efforts = [.low, .medium, .high]
            providerDefaultBehavior = .disabled
            explicitDisableSupport = .supported

        case "claude-haiku-4-5",
             "claude-haiku-4-5-20251001",
             "claude-sonnet-4-5",
             "claude-sonnet-4-5-20250929":
            support = .extendedOnly
            efforts = []
            providerDefaultBehavior = .disabled
            explicitDisableSupport = .supported

        default:
            return nil
        }

        let mode = support.resolvedMode(requested: requestedMode)
        return ReasoningCapabilityProfile(
            dialect: mode == .adaptive ? .anthropicAdaptive : .anthropicExtended,
            supportedEfforts: efforts,
            supportedSummaries: [],
            supportedOpenAIContexts: [],
            supportedOpenAIModes: [],
            supportedAnthropicModes: support.modes,
            providerDefaultBehavior: providerDefaultBehavior,
            explicitDisableSupport: explicitDisableSupport,
            chatCompletionsToolPolicy: .unrestricted
        )
    }

    private static func isOfficialOpenAIEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint = normalizedEndpoint(endpoint) else { return true }
        return endpoint == "api.openai.com"
    }

    private static func isOfficialAnthropicEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint = normalizedEndpoint(endpoint) else { return true }
        return endpoint == "api.anthropic.com"
    }

    private static func normalizedEndpoint(_ endpoint: String?) -> String? {
        guard let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        if let host = URL(string: trimmed)?.host?.lowercased() {
            return host
        }
        return trimmed.lowercased()
    }
}

/// Opaque provider state that must be replayed unchanged to continue reasoning
/// across tool calls and later turns. This is intentionally distinct from the
/// user-visible reasoning summary stored in `Message.reasoning`.
struct ReasoningContinuationState: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable {
        case openAIResponses
        case anthropicMessages
    }

    let format: Format
    let items: [AnyCodable]
    let model: String?
    let requestConfiguration: ResolvedReasoningConfiguration?
    private let requestConfigurationCaptured: Bool?

    init(
        format: Format,
        items: [AnyCodable],
        model: String? = nil,
        requestConfiguration: ResolvedReasoningConfiguration? = nil,
        requestConfigurationCaptured: Bool? = nil
    ) {
        self.format = format
        self.items = items
        self.model = model
        self.requestConfiguration = requestConfiguration
        self.requestConfigurationCaptured = requestConfigurationCaptured ??
            (requestConfiguration == nil ? nil : true)
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    /// Whether the originating request's reasoning controls were captured.
    ///
    /// A captured `nil` configuration means the provider default was
    /// intentionally used. This must remain distinct from older continuation
    /// payloads that never recorded request configuration at all.
    var hasRequestConfigurationSnapshot: Bool {
        requestConfigurationCaptured == true || requestConfiguration != nil
    }

    func attaching(
        model: String,
        requestConfiguration: ResolvedReasoningConfiguration?
    ) -> ReasoningContinuationState {
        ReasoningContinuationState(
            format: format,
            items: items,
            model: model,
            requestConfiguration: requestConfiguration,
            requestConfigurationCaptured: true
        )
    }
}
