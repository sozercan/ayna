import Foundation

/// Provider-aware presentation policy for per-model reasoning settings.
///
/// The activation control is always rendered by the settings UI. Additional
/// fields are exposed only when they map to the configured provider dialect.
struct ModelReasoningSettingsPresentation: Equatable, Sendable {
    let isActivationEnabled: Bool
    let activationOptions: [ReasoningActivationMode]
    let effortOptions: [ReasoningEffort]
    let openAIModeOptions: [OpenAIReasoningMode]
    let openAIContextOptions: [OpenAIReasoningContext]
    let summaryOptions: [ReasoningSummaryPreference]
    let anthropicModeOptions: [AnthropicThinkingMode]
    let showsEffort: Bool
    let showsOpenAIMode: Bool
    let showsOpenAIContext: Bool
    let showsSummary: Bool
    let showsAnthropicMode: Bool
    let showsAnthropicDisplay: Bool
    let showsLegacyBudget: Bool
    let unavailableDescription: String?

    init(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        endpoint: String?,
        configuration: ModelReasoningConfiguration
    ) {
        guard provider != .appleIntelligence, endpointType != .imageGeneration else {
            isActivationEnabled = false
            activationOptions = [.automatic, .disabled, .enabled]
            effortOptions = []
            openAIModeOptions = []
            openAIContextOptions = []
            summaryOptions = []
            anthropicModeOptions = []
            showsEffort = false
            showsOpenAIMode = false
            showsOpenAIContext = false
            showsSummary = false
            showsAnthropicMode = false
            showsAnthropicDisplay = false
            showsLegacyBudget = false
            unavailableDescription = provider == .appleIntelligence
                ? "Apple Intelligence does not expose provider reasoning request controls."
                : "Reasoning request controls are unavailable for image generation models."
            return
        }

        isActivationEnabled = true
        let modelPolicy = ReasoningCapabilityResolver.modelPolicy(
            model: model,
            provider: provider,
            endpointType: endpointType,
            anthropicMode: configuration.anthropicMode
        )
        let supportsExplicitDisable = switch modelPolicy?.explicitDisableSupport {
        case .supported?, .supportedWithEfforts?:
            true
        case .unknown?, .unsupported?, nil:
            false
        }
        activationOptions = ReasoningActivationMode.allCases.filter {
            $0 != .explicitlyDisabled || supportsExplicitDisable
        }

        let capabilities = configuration.activation == .explicitlyDisabled
            ? modelPolicy
            : ReasoningCapabilityResolver.capabilities(
                model: model,
                provider: provider,
                endpointType: endpointType,
                endpoint: endpoint,
                configuration: configuration
            )
        guard let capabilities else {
            effortOptions = []
            openAIModeOptions = []
            openAIContextOptions = []
            summaryOptions = []
            anthropicModeOptions = []
            showsEffort = false
            showsOpenAIMode = false
            showsOpenAIContext = false
            showsSummary = false
            showsAnthropicMode = false
            showsAnthropicDisplay = false
            showsLegacyBudget = false
            unavailableDescription = configuration.activation == .automatic
                ? "Automatic reasoning is unavailable for this model or endpoint. Choose On to configure provider-compatible controls."
                : nil
            return
        }

        let disableEfforts: [ReasoningEffort] = switch capabilities.explicitDisableSupport {
        case .supported where provider == .anthropic:
            capabilities.supportedEfforts
        case let .supportedWithEfforts(efforts) where provider == .anthropic:
            efforts
        case .unknown, .unsupported, .supported, .supportedWithEfforts:
            []
        }
        effortOptions = configuration.activation == .explicitlyDisabled
            ? disableEfforts
            : capabilities.supportedEfforts
        openAIModeOptions = capabilities.supportedOpenAIModes
        openAIContextOptions = capabilities.supportedOpenAIContexts
        summaryOptions = capabilities.supportedSummaries
        anthropicModeOptions = capabilities.supportedAnthropicModes
        let showsEnabledControls = configuration.activation != .explicitlyDisabled
        showsEffort = !effortOptions.isEmpty
        showsOpenAIMode = showsEnabledControls && !capabilities.supportedOpenAIModes.isEmpty
        showsOpenAIContext = showsEnabledControls && !capabilities.supportedOpenAIContexts.isEmpty
        showsSummary = showsEnabledControls && !capabilities.supportedSummaries.isEmpty
        showsAnthropicMode = provider == .anthropic &&
            configuration.activation == .enabled &&
            capabilities.supportedAnthropicModes.count > 1
        showsAnthropicDisplay = showsEnabledControls && provider == .anthropic
        showsLegacyBudget = showsEnabledControls && capabilities.dialect == .anthropicExtended
        unavailableDescription = nil
    }

    static func normalizedConfiguration(
        model: String,
        provider: AIProvider,
        endpointType: APIEndpointType,
        endpoint: String?,
        configuration: ModelReasoningConfiguration
    ) -> ModelReasoningConfiguration {
        var normalized = configuration
        var presentation = ModelReasoningSettingsPresentation(
            model: model,
            provider: provider,
            endpointType: endpointType,
            endpoint: endpoint,
            configuration: normalized
        )

        if !presentation.isActivationEnabled ||
            !presentation.activationOptions.contains(normalized.activation)
        {
            normalized.activation = .automatic
            presentation = ModelReasoningSettingsPresentation(
                model: model,
                provider: provider,
                endpointType: endpointType,
                endpoint: endpoint,
                configuration: normalized
            )
        }

        if let effort = normalized.effort,
           !presentation.effortOptions.contains(effort)
        {
            normalized.effort = nil
        }
        if let openAIMode = normalized.openAIMode,
           !presentation.openAIModeOptions.contains(openAIMode)
        {
            normalized.openAIMode = nil
        }
        if !presentation.openAIContextOptions.contains(normalized.openAIContext) {
            normalized.openAIContext = .automatic
        }
        if !presentation.summaryOptions.contains(normalized.summary) {
            normalized.summary = .automatic
        }
        if !presentation.anthropicModeOptions.contains(normalized.anthropicMode) {
            normalized.anthropicMode = presentation.anthropicModeOptions.first ?? .adaptive
        }
        normalized.legacyBudgetTokens = max(
            normalized.legacyBudgetTokens,
            ModelReasoningConfiguration.minimumLegacyBudgetTokens
        )
        return normalized
    }
}

struct ChatReasoningModelContext: Equatable, Sendable {
    let model: String
    let provider: AIProvider
    let endpointType: APIEndpointType
    let endpoint: String?
}

/// Capability intersection for one conversation's selected models.
///
/// A conversation stores one reasoning configuration, so multi-model controls
/// must expose only values that every selected model accepts.
struct ChatReasoningSettingsPresentation: Equatable, Sendable {
    let models: [ChatReasoningModelContext]
    let individualPresentations: [ModelReasoningSettingsPresentation]
    let isAvailable: Bool
    let activationOptions: [ReasoningActivationMode]
    let effortOptions: [ReasoningEffort]

    init(
        models: [ChatReasoningModelContext],
        configuration: ModelReasoningConfiguration
    ) {
        self.models = models
        let presentations = models.map { context in
            ModelReasoningSettingsPresentation(
                model: context.model,
                provider: context.provider,
                endpointType: context.endpointType,
                endpoint: context.endpoint,
                configuration: configuration
            )
        }
        individualPresentations = presentations
        isAvailable = !presentations.isEmpty && presentations.allSatisfy(\.isActivationEnabled)
        activationOptions = ReasoningActivationMode.allCases.filter { activation in
            !presentations.isEmpty && presentations.allSatisfy {
                $0.activationOptions.contains(activation)
            }
        }
        if let first = presentations.first?.effortOptions {
            effortOptions = first.filter { effort in
                presentations.dropFirst().allSatisfy { $0.effortOptions.contains(effort) }
            }
        } else {
            effortOptions = []
        }
    }

    func normalizedConfiguration(
        _ configuration: ModelReasoningConfiguration
    ) -> ModelReasoningConfiguration {
        guard let first = models.first else { return configuration }
        if models.count == 1 {
            return ModelReasoningSettingsPresentation.normalizedConfiguration(
                model: first.model,
                provider: first.provider,
                endpointType: first.endpointType,
                endpoint: first.endpoint,
                configuration: configuration
            )
        }

        var normalized = configuration
        if !activationOptions.contains(normalized.activation) {
            normalized.activation = .automatic
        }
        if let effort = normalized.effort, !effortOptions.contains(effort) {
            normalized.effort = nil
        }
        return normalized
    }
}

/// Effort stops offered by the composer's thinking-effort slider.
///
/// Automatic mode only sends reasoning parameters to verified first-party
/// endpoints. For custom endpoints (Azure, proxies, deployment aliases) the
/// slider still offers the efforts that an explicit "On" would allow, and
/// picking one opts the conversation in.
struct ChatReasoningEffortSelection: Equatable, Sendable {
    let options: [ReasoningEffort]
    /// True when choosing an effort must also switch activation to `.enabled`.
    let requiresOptIn: Bool

    init(models: [ChatReasoningModelContext], configuration: ModelReasoningConfiguration) {
        let current = ChatReasoningSettingsPresentation(models: models, configuration: configuration)
        guard current.isAvailable,
              current.effortOptions.isEmpty,
              configuration.activation == .automatic
        else {
            options = current.effortOptions
            requiresOptIn = false
            return
        }

        var enabled = configuration
        enabled.activation = .enabled
        options = ChatReasoningSettingsPresentation(models: models, configuration: enabled).effortOptions
        requiresOptIn = !options.isEmpty
    }

    func configuration(
        selecting effort: ReasoningEffort?,
        from configuration: ModelReasoningConfiguration
    ) -> ModelReasoningConfiguration {
        var updated = configuration
        updated.effort = effort
        if effort != nil, requiresOptIn {
            updated.activation = .enabled
        }
        return updated
    }
}

extension ModelReasoningConfiguration {
    /// Short label for the model selector, or `nil` when the conversation uses
    /// the model's default thinking behavior.
    var thinkingEffortBadge: String? {
        if activation == .explicitlyDisabled {
            return "Off"
        }
        return effort?.displayName
    }
}
