@testable import Ayna
import Testing

// SwiftFormat prefers descriptive Swift Testing function names.
// swiftlint:disable identifier_name

@Suite("Model reasoning settings presentation")
struct ModelReasoningSettingsPresentationTests {
    @Test
    func `OpenAI chat exposes effort without Responses-only fields`() {
        let presentation = ModelReasoningSettingsPresentation(
            model: "gpt-5",
            provider: .openai,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        )

        #expect(presentation.isActivationEnabled)
        #expect(!presentation.activationOptions.contains(.explicitlyDisabled))
        #expect(presentation.showsEffort)
        #expect(presentation.effortOptions == [.minimal, .low, .medium, .high])
        #expect(!presentation.showsOpenAIMode)
        #expect(!presentation.showsOpenAIContext)
        #expect(!presentation.showsSummary)
    }

    @Test
    func `OpenAI Responses exposes response reasoning fields`() {
        let presentation = ModelReasoningSettingsPresentation(
            model: "gpt-5.6",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: .automatic
        )

        #expect(presentation.showsEffort)
        #expect(presentation.activationOptions.contains(.explicitlyDisabled))
        #expect(presentation.effortOptions == [.none, .low, .medium, .high, .xhigh, .max])
        #expect(presentation.showsOpenAIMode)
        #expect(presentation.openAIModeOptions == OpenAIReasoningMode.allCases)
        #expect(presentation.showsOpenAIContext)
        #expect(presentation.openAIContextOptions == OpenAIReasoningContext.allCases)
        #expect(presentation.showsSummary)
        #expect(presentation.summaryOptions == [.none, .automatic])
    }

    @Test
    func `Anthropic adaptive exposes effort and display`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.anthropicMode = .adaptive

        let presentation = ModelReasoningSettingsPresentation(
            model: "claude-sonnet-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        )

        #expect(!presentation.showsAnthropicMode)
        #expect(presentation.activationOptions.contains(.explicitlyDisabled))
        #expect(presentation.anthropicModeOptions == [.adaptive])
        #expect(presentation.showsAnthropicDisplay)
        #expect(presentation.showsEffort)
        #expect(!presentation.showsLegacyBudget)
        #expect(presentation.effortOptions == ReasoningEffort.anthropicValues)
    }

    @Test
    func `Anthropic extended exposes legacy budget instead of effort`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled
        configuration.anthropicMode = .extended

        let presentation = ModelReasoningSettingsPresentation(
            model: "claude-sonnet-4-5-20250929",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        )

        #expect(!presentation.showsAnthropicMode)
        #expect(presentation.anthropicModeOptions == [.extended])
        #expect(presentation.showsAnthropicDisplay)
        #expect(!presentation.showsEffort)
        #expect(presentation.showsLegacyBudget)
    }

    @Test
    func `Anthropic models with both dialects expose a mode picker when explicitly enabled`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled

        let presentation = ModelReasoningSettingsPresentation(
            model: "claude-sonnet-4-6",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        )

        #expect(presentation.showsAnthropicMode)
        #expect(presentation.anthropicModeOptions == AnthropicThinkingMode.allCases)
    }

    @Test
    func `Anthropic legacy thinking can expose effort and a fixed budget together`() {
        let presentation = ModelReasoningSettingsPresentation(
            model: "claude-opus-4-5-20251101",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        )

        #expect(presentation.showsEffort)
        #expect(presentation.effortOptions == [.low, .medium, .high])
        #expect(presentation.showsLegacyBudget)
    }

    @Test
    func `Disabled activation hides provider-specific controls`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .disabled

        let presentation = ModelReasoningSettingsPresentation(
            model: "gpt-5.6",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: configuration
        )

        #expect(presentation.isActivationEnabled)
        #expect(!presentation.showsEffort)
        #expect(!presentation.showsOpenAIMode)
        #expect(!presentation.showsOpenAIContext)
        #expect(!presentation.showsSummary)
    }

    @Test
    func `Anthropic Off preserves only supported effort choices`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .explicitlyDisabled
        configuration.effort = .xhigh

        let presentation = ModelReasoningSettingsPresentation(
            model: "claude-opus-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        )
        let normalized = ModelReasoningSettingsPresentation.normalizedConfiguration(
            model: "claude-opus-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        )

        #expect(presentation.showsEffort)
        #expect(presentation.effortOptions == [.low, .medium, .high])
        #expect(!presentation.showsAnthropicDisplay)
        #expect(!presentation.showsLegacyBudget)
        #expect(normalized.effort == nil)
    }

    @Test(arguments: [
        (AIProvider.openai, APIEndpointType.imageGeneration),
        (AIProvider.appleIntelligence, APIEndpointType.chatCompletions),
    ])
    func `Unsupported configurations keep activation visible but disabled`(
        provider: AIProvider,
        endpointType: APIEndpointType
    ) {
        let presentation = ModelReasoningSettingsPresentation(
            model: "test-model",
            provider: provider,
            endpointType: endpointType,
            endpoint: nil,
            configuration: .automatic
        )

        #expect(!presentation.isActivationEnabled)
        #expect(!presentation.showsEffort)
        #expect(presentation.unavailableDescription != nil)
    }

    @Test
    func `Automatic unknown model hides advanced controls`() {
        let presentation = ModelReasoningSettingsPresentation(
            model: "deployment-alias",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: .automatic
        )

        #expect(presentation.isActivationEnabled)
        #expect(!presentation.showsEffort)
        #expect(!presentation.showsOpenAIMode)
        #expect(!presentation.showsOpenAIContext)
        #expect(!presentation.showsSummary)
        #expect(presentation.unavailableDescription != nil)
    }

    @Test
    func `Explicit unknown model uses provider fallback options`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled

        let presentation = ModelReasoningSettingsPresentation(
            model: "deployment-alias",
            provider: .openai,
            endpointType: .responses,
            endpoint: "https://example.com/v1",
            configuration: configuration
        )

        #expect(presentation.showsEffort)
        #expect(presentation.effortOptions == ReasoningEffort.allCases)
        #expect(presentation.openAIModeOptions == OpenAIReasoningMode.allCases)
        #expect(presentation.openAIContextOptions == OpenAIReasoningContext.allCases)
        #expect(presentation.summaryOptions == ReasoningSummaryPreference.allCases)
    }

    @Test
    func `Automatic custom endpoint hides advanced controls`() {
        let presentation = ModelReasoningSettingsPresentation(
            model: "gpt-5.6",
            provider: .openai,
            endpointType: .responses,
            endpoint: "https://example.com/v1",
            configuration: .automatic
        )

        #expect(presentation.isActivationEnabled)
        #expect(!presentation.showsEffort)
        #expect(presentation.unavailableDescription != nil)
    }

    @Test
    func `Always-on Anthropic models do not expose Off`() {
        let presentation = ModelReasoningSettingsPresentation(
            model: "claude-fable-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        )

        #expect(!presentation.activationOptions.contains(.explicitlyDisabled))
    }

    @Test
    func `Unknown aliases do not claim explicit disable support`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled
        let presentation = ModelReasoningSettingsPresentation(
            model: "deployment-alias",
            provider: .openai,
            endpointType: .responses,
            endpoint: "https://example.com/v1",
            configuration: configuration
        )

        #expect(!presentation.activationOptions.contains(.explicitlyDisabled))
    }

    @Test
    func `Normalization clears values that are invalid for changed capabilities`() {
        var configuration = ModelReasoningConfiguration(
            activation: .explicitlyDisabled,
            effort: .max,
            openAIMode: .pro,
            openAIContext: .allTurns,
            summary: .detailed,
            anthropicMode: .extended
        )
        configuration.legacyBudgetTokens = 1

        let normalized = ModelReasoningSettingsPresentation.normalizedConfiguration(
            model: "gpt-5",
            provider: .openai,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        )

        #expect(normalized.activation == .automatic)
        #expect(normalized.effort == nil)
        #expect(normalized.openAIMode == nil)
        #expect(normalized.openAIContext == .automatic)
        #expect(normalized.summary == .automatic)
        #expect(normalized.anthropicMode == .adaptive)
        #expect(normalized.legacyBudgetTokens == ModelReasoningConfiguration.minimumLegacyBudgetTokens)
    }

    @Test
    func `Normalization selects the only supported Anthropic mode`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled
        configuration.anthropicMode = .adaptive

        let normalized = ModelReasoningSettingsPresentation.normalizedConfiguration(
            model: "claude-sonnet-4-5-20250929",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        )

        #expect(normalized.anthropicMode == .extended)
    }
}

// swiftlint:enable identifier_name
