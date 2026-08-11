@testable import Ayna
import Foundation
import Testing

// swiftlint:disable identifier_name

@Suite("Reasoning Configuration Tests", .tags(.fast))
struct ReasoningConfigurationTests {
    @Test
    func `Automatic mode recognizes only supported first-party models and endpoints`() {
        #expect(resolve(model: "gpt-5.6", endpointType: .responses)?.dialect == .openAIResponses)
        #expect(resolve(model: "gpt-4.1", endpointType: .responses) == nil)
        #expect(resolve(
            model: "gpt-5.6",
            endpointType: .responses,
            endpoint: "https://gateway.example.com/v1"
        ) == nil)
        #expect(resolve(
            model: "azure-production-deployment",
            endpointType: .responses,
            endpoint: "https://example.openai.azure.com/openai/v1"
        ) == nil)
    }

    @Test
    func `Explicit mode opts custom aliases into their configured dialect`() {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled
        configuration.effort = .high

        let resolved = ReasoningCapabilityResolver.resolve(
            model: "azure-production-deployment",
            provider: .openai,
            endpointType: .responses,
            endpoint: "https://example.openai.azure.com/openai/v1",
            configuration: configuration
        )

        #expect(resolved?.dialect == .openAIResponses)
        #expect(resolved?.effort == .high)
    }

    @Test
    func `Automatic mode removes unsupported model-specific controls`() throws {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.effort = .max
        configuration.summary = .detailed
        configuration.openAIContext = .allTurns
        configuration.openAIMode = .pro

        let resolved = try #require(ReasoningCapabilityResolver.resolve(
            model: "gpt-5.5",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: configuration
        ))

        #expect(resolved.effort == nil)
        #expect(resolved.summary == .automatic)
        #expect(resolved.openAIContext == .automatic)
        #expect(resolved.openAIMode == nil)
    }

    @Test
    func `Explicit mode still sanitizes controls for recognized models`() throws {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled
        configuration.effort = .max
        configuration.summary = .detailed
        configuration.openAIContext = .allTurns
        configuration.openAIMode = .pro

        let resolved = try #require(ReasoningCapabilityResolver.resolve(
            model: "gpt-5.5",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: configuration
        ))

        #expect(resolved.effort == nil)
        #expect(resolved.summary == .automatic)
        #expect(resolved.openAIContext == .automatic)
        #expect(resolved.openAIMode == nil)
    }

    @Test
    func `GPT-5.6 Responses exposes persisted context, modes, and maximum effort`() throws {
        let profile = try #require(ReasoningCapabilityResolver.capabilities(
            model: "gpt-5.6-sol",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: .automatic
        ))

        #expect(profile.dialect == .openAIResponses)
        #expect(profile.supportedEfforts.contains(.max))
        #expect(profile.supportedSummaries == [.none, .automatic])
        #expect(profile.supportedOpenAIContexts.contains(.allTurns))
        #expect(profile.supportedOpenAIModes == OpenAIReasoningMode.allCases)
    }

    @Test
    func `GPT-5.6 Chat Completions supports maximum effort and disables reasoning for tools`() throws {
        let profile = try #require(ReasoningCapabilityResolver.capabilities(
            model: "gpt-5.6-terra",
            provider: .openai,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        ))

        #expect(profile.dialect == .openAIChat)
        #expect(profile.supportedEfforts.contains(.max))
        #expect(profile.chatCompletionsToolPolicy == .requiresExplicitEffort(.none))
        #expect(profile.allowsChatCompletionsTools(with: ReasoningEffort.none))
        #expect(!profile.allowsChatCompletionsTools(with: nil))
        #expect(!profile.allowsChatCompletionsTools(with: .high))
        #expect(profile.chatCompletionsEffort(requested: .max, hasTools: false) == .max)
        #expect(profile.chatCompletionsEffort(
            requested: .max,
            hasTools: true
        ) == ReasoningEffort.none)
    }

    @Test(arguments: [
        "gpt-5.6",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.6-cyber",
        "gpt-5.5",
        "gpt-5.5-2026-04-23",
        "gpt-5.5-pro",
        "gpt-5.5-pro-2026-04-23",
        "gpt-5.4",
        "gpt-5.4-2026-03-05",
        "gpt-5.4-mini",
        "gpt-5.4-mini-2026-03-17",
        "gpt-5.4-nano",
        "gpt-5.4-nano-2026-03-17",
        "gpt-5.4-pro",
        "gpt-5.4-pro-2026-03-05",
        "gpt-5.3-codex",
        "gpt-5.2",
        "gpt-5.2-2025-12-11",
        "gpt-5.2-pro",
        "gpt-5.2-pro-2025-12-11",
        "gpt-5.2-codex",
        "gpt-5.1",
        "gpt-5.1-2025-11-13",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max",
        "gpt-5",
        "gpt-5-2025-08-07",
        "gpt-5-mini",
        "gpt-5-mini-2025-08-07",
        "gpt-5-nano",
        "gpt-5-nano-2025-08-07",
        "gpt-5-pro",
        "gpt-5-pro-2025-10-06",
        "gpt-5-codex",
        "o1",
        "o1-2024-12-17",
        "o1-pro",
        "o1-pro-2025-03-19",
        "o3",
        "o3-2025-04-16",
        "o3-mini",
        "o3-mini-2025-01-31",
        "o3-pro",
        "o3-pro-2025-06-10",
        "o3-deep-research",
        "o3-deep-research-2025-06-26",
        "o4-mini",
        "o4-mini-2025-04-16",
        "o4-mini-deep-research",
        "o4-mini-deep-research-2025-06-26",
        "codex-mini-latest"
    ])
    func `OpenAI catalog recognizes documented exact Responses IDs`(model: String) {
        #expect(openAIModelPolicy(model: model, endpointType: .responses) != nil)
    }

    @Test
    func `OpenAI catalog recognizes exact Chat IDs without accepting invented snapshots`() {
        #expect(openAIModelPolicy(
            model: "o1-mini-2024-09-12",
            endpointType: .chatCompletions
        ) != nil)
        #expect(openAIModelPolicy(model: "gpt-5.6-20260810", endpointType: .responses) == nil)
        #expect(openAIModelPolicy(model: "proxy-gpt-5.6", endpointType: .responses) == nil)
    }

    @Test(arguments: [
        "gpt-5.5-pro",
        "gpt-5.5-pro-2026-04-23",
        "gpt-5.4-pro-2026-03-05",
        "gpt-5-pro",
        "gpt-5-pro-2025-10-06",
        "gpt-5.4-pro",
        "gpt-5.2-pro",
        "gpt-5.2-pro-2025-12-11",
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max",
        "gpt-5-codex",
        "o1-pro",
        "o1-pro-2025-03-19",
        "o3-pro",
        "o3-pro-2025-06-10",
        "o3-deep-research",
        "o3-deep-research-2025-06-26",
        "o4-mini-deep-research",
        "o4-mini-deep-research-2025-06-26",
        "codex-mini-latest"
    ])
    func `Response-only OpenAI models are unavailable on Chat Completions`(model: String) {
        #expect(openAIModelPolicy(model: model, endpointType: .chatCompletions) == nil)
    }

    @Test
    func `Known OpenAI models do not fall back on unsupported endpoints`() {
        #expect(openAIModelPolicy(model: "o1-mini", endpointType: .responses) == nil)

        var explicitlyEnabled = ModelReasoningConfiguration.automatic
        explicitlyEnabled.activation = .enabled
        explicitlyEnabled.effort = .high

        #expect(ReasoningCapabilityResolver.resolve(
            model: "gpt-5-pro",
            provider: .openai,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: explicitlyEnabled
        ) == nil)
        #expect(ReasoningCapabilityResolver.resolve(
            model: "o1-mini",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: explicitlyEnabled
        ) == nil)
    }

    @Test
    func `OpenAI model policies expose documented efforts defaults and disable support`() throws {
        let newest = try #require(openAIModelPolicy(model: "gpt-5.6", endpointType: .responses))
        let defaultOnWithDisable = try #require(openAIModelPolicy(
            model: "gpt-5.5",
            endpointType: .responses
        ))
        let defaultOff = try #require(openAIModelPolicy(model: "gpt-5.4", endpointType: .responses))
        let olderDefaultOff = try #require(openAIModelPolicy(
            model: "gpt-5.1",
            endpointType: .responses
        ))
        let pro = try #require(openAIModelPolicy(model: "gpt-5.5-pro", endpointType: .responses))
        let codex = try #require(openAIModelPolicy(
            model: "gpt-5.2-codex",
            endpointType: .responses
        ))
        let noDisable = try #require(openAIModelPolicy(model: "gpt-5", endpointType: .responses))

        #expect(newest.providerDefaultBehavior == .enabled)
        #expect(newest.explicitDisableSupport == .supported)
        #expect(newest.supportedEfforts == [.none, .low, .medium, .high, .xhigh, .max])
        #expect(defaultOnWithDisable.providerDefaultBehavior == .enabled)
        #expect(defaultOnWithDisable.explicitDisableSupport == .supported)
        #expect(defaultOnWithDisable.supportedEfforts == [.none, .low, .medium, .high, .xhigh])
        #expect(defaultOff.providerDefaultBehavior == .disabled)
        #expect(defaultOff.explicitDisableSupport == .supported)
        #expect(defaultOff.supportedEfforts == [.none, .low, .medium, .high, .xhigh])
        #expect(olderDefaultOff.providerDefaultBehavior == .disabled)
        #expect(olderDefaultOff.explicitDisableSupport == .supported)
        #expect(olderDefaultOff.supportedEfforts == [.none, .low, .medium, .high])
        #expect(pro.providerDefaultBehavior == .enabled)
        #expect(pro.explicitDisableSupport == .unsupported)
        #expect(pro.supportedEfforts == [.medium, .high, .xhigh])
        #expect(codex.explicitDisableSupport == .unsupported)
        #expect(codex.supportedEfforts == [.low, .medium, .high, .xhigh])
        #expect(noDisable.explicitDisableSupport == .unsupported)
    }

    @Test
    func `O1 mini remains passive when unsupported outbound controls are selected automatically`() throws {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.effort = .high
        configuration.summary = .automatic

        let resolved = try #require(ReasoningCapabilityResolver.resolve(
            model: "o1-mini",
            provider: .openai,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        ))

        #expect(resolved.effort == nil)
        #expect(resolved.summary == .none)
    }

    @Test
    func `Supported Anthropic models resolve their documented thinking dialect`() throws {
        let newest = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-sonnet-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        ))
        let adaptive = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-opus-4-8",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        ))
        let extended = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-sonnet-4-5-20250929",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        ))

        #expect(newest.dialect == .anthropicAdaptive)
        #expect(adaptive.dialect == .anthropicAdaptive)
        #expect(extended.dialect == .anthropicExtended)
        #expect(newest.anthropicDisplay == .providerDefault)
    }

    @Test
    func `Anthropic automatic matching accepts documented IDs only`() {
        #expect(ReasoningCapabilityResolver.resolve(
            model: "proxy-claude-sonnet-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        ) == nil)
        #expect(ReasoningCapabilityResolver.resolve(
            model: "claude-sonnet-5-20260701",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: .automatic
        ) == nil)
    }

    @Test
    func `Anthropic models that support both modes honor an explicit legacy selection`() throws {
        var configuration = ModelReasoningConfiguration.automatic
        configuration.activation = .enabled
        configuration.anthropicMode = .extended

        let resolved = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-sonnet-4-6",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: configuration
        ))

        #expect(resolved.dialect == .anthropicExtended)
    }

    @Test
    func `Anthropic model policies distinguish default and disable behavior`() throws {
        let alwaysOn = try #require(anthropicModelPolicy(model: "claude-fable-5"))
        let alwaysOnBothModes = try #require(anthropicModelPolicy(model: "claude-mythos-preview"))
        let defaultOnRestrictedDisable = try #require(anthropicModelPolicy(model: "claude-opus-5"))
        let defaultOn = try #require(anthropicModelPolicy(model: "claude-sonnet-5"))
        let defaultOffAdaptive = try #require(anthropicModelPolicy(model: "claude-opus-4-8"))
        let defaultOffBothModes = try #require(anthropicModelPolicy(model: "claude-sonnet-4-6"))
        let legacyWithEffort = try #require(anthropicModelPolicy(model: "claude-opus-4-5"))
        let legacyWithoutEffort = try #require(anthropicModelPolicy(model: "claude-sonnet-4-5"))

        #expect(alwaysOn.providerDefaultBehavior == .alwaysEnabled)
        #expect(alwaysOn.explicitDisableSupport == .unsupported)
        #expect(alwaysOn.supportedAnthropicModes == [.adaptive])
        #expect(alwaysOn.supportedEfforts == [.low, .medium, .high, .xhigh, .max])

        #expect(alwaysOnBothModes.providerDefaultBehavior == .alwaysEnabled)
        #expect(alwaysOnBothModes.explicitDisableSupport == .unsupported)
        #expect(alwaysOnBothModes.supportedAnthropicModes == AnthropicThinkingMode.allCases)
        #expect(alwaysOnBothModes.supportedEfforts == [.low, .medium, .high, .max])

        #expect(defaultOnRestrictedDisable.providerDefaultBehavior == .enabled)
        #expect(defaultOnRestrictedDisable.explicitDisableSupport == .supportedWithEfforts([
            .low,
            .medium,
            .high,
        ]))
        #expect(defaultOnRestrictedDisable.supportedAnthropicModes == [.adaptive])

        #expect(defaultOn.providerDefaultBehavior == .enabled)
        #expect(defaultOn.explicitDisableSupport == .supported)
        #expect(defaultOn.supportedAnthropicModes == [.adaptive])

        #expect(defaultOffAdaptive.providerDefaultBehavior == .disabled)
        #expect(defaultOffAdaptive.explicitDisableSupport == .supported)
        #expect(defaultOffAdaptive.supportedAnthropicModes == [.adaptive])

        #expect(defaultOffBothModes.providerDefaultBehavior == .disabled)
        #expect(defaultOffBothModes.explicitDisableSupport == .supported)
        #expect(defaultOffBothModes.supportedAnthropicModes == AnthropicThinkingMode.allCases)

        #expect(legacyWithEffort.supportedAnthropicModes == [.extended])
        #expect(legacyWithEffort.supportedEfforts == [.low, .medium, .high])
        #expect(legacyWithEffort.explicitDisableSupport == .supported)

        #expect(legacyWithoutEffort.supportedAnthropicModes == [.extended])
        #expect(legacyWithoutEffort.supportedEfforts.isEmpty)
        #expect(legacyWithoutEffort.explicitDisableSupport == .supported)
    }

    @Test
    func `Provider default omission and explicit disable resolve differently`() throws {
        var providerDefault = ModelReasoningConfiguration.automatic
        providerDefault.activation = .disabled

        #expect(ReasoningCapabilityResolver.resolve(
            model: "claude-sonnet-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: providerDefault
        ) == nil)

        var explicitlyDisabled = ModelReasoningConfiguration.automatic
        explicitlyDisabled.activation = .explicitlyDisabled
        explicitlyDisabled.effort = .medium

        let openAI = try #require(ReasoningCapabilityResolver.resolve(
            model: "gpt-5.6",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: explicitlyDisabled
        ))
        let anthropic = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-sonnet-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: explicitlyDisabled
        ))
        let anthropicRestricted = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-opus-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: explicitlyDisabled
        ))

        #expect(openAI.dialect == .openAIResponses)
        #expect(openAI.effort == ReasoningEffort.none)
        #expect(openAI.summary == .none)
        #expect(anthropic.dialect == .anthropicDisabled)
        #expect(anthropic.effort == .medium)
        #expect(anthropicRestricted.dialect == .anthropicDisabled)
        #expect(anthropicRestricted.effort == .medium)

        #expect(ReasoningCapabilityResolver.resolve(
            model: "gpt-5",
            provider: .openai,
            endpointType: .responses,
            endpoint: nil,
            configuration: explicitlyDisabled
        ) == nil)
        #expect(ReasoningCapabilityResolver.resolve(
            model: "claude-fable-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: explicitlyDisabled
        ) == nil)
        let legacyAnthropic = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-sonnet-4-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: explicitlyDisabled
        ))
        #expect(legacyAnthropic.dialect == .anthropicDisabled)
        #expect(legacyAnthropic.effort == nil)

        explicitlyDisabled.effort = .xhigh
        let restrictedInvalidEffort = try #require(ReasoningCapabilityResolver.resolve(
            model: "claude-opus-5",
            provider: .anthropic,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: explicitlyDisabled
        ))
        #expect(restrictedInvalidEffort.effort == nil)
    }

    @Test
    func `Retired Anthropic models are not recognized automatically`() {
        for model in [
            "claude-opus-4-1",
            "claude-opus-4-20250514",
            "claude-sonnet-4-20250514",
            "claude-3-7-sonnet-20250219",
        ] {
            #expect(ReasoningCapabilityResolver.resolve(
                model: model,
                provider: .anthropic,
                endpointType: .chatCompletions,
                endpoint: nil,
                configuration: .automatic
            ) == nil)
        }
    }

    @Test
    func `Captured provider default survives continuation persistence`() throws {
        let captured = ReasoningContinuationState(
            format: .openAIResponses,
            items: [AnyCodable(["type": "reasoning", "id": "rs_default"])]
        ).attaching(model: "gpt-5.6", requestConfiguration: nil)

        let data = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode(ReasoningContinuationState.self, from: data)

        #expect(decoded.requestConfiguration == nil)
        #expect(decoded.hasRequestConfigurationSnapshot)
    }

    @Test
    func `Reasoning is unavailable for Apple and image-generation requests`() {
        var enabled = ModelReasoningConfiguration.automatic
        enabled.activation = .enabled

        #expect(ReasoningCapabilityResolver.resolve(
            model: "apple-intelligence",
            provider: .appleIntelligence,
            endpointType: .chatCompletions,
            endpoint: nil,
            configuration: enabled
        ) == nil)
        #expect(ReasoningCapabilityResolver.resolve(
            model: "gpt-image-1",
            provider: .openai,
            endpointType: .imageGeneration,
            endpoint: nil,
            configuration: enabled
        ) == nil)
    }

    @Test
    func `Opaque continuation state survives persistence without changing provider items`() throws {
        let state = ReasoningContinuationState(
            format: .openAIResponses,
            items: [AnyCodable([
                "type": "reasoning",
                "id": "rs_123",
                "encrypted_content": "opaque-token"
            ])],
            model: "gpt-5.6",
            requestConfiguration: ResolvedReasoningConfiguration(
                dialect: .openAIResponses,
                effort: .high,
                openAIMode: .standard,
                openAIContext: .allTurns,
                summary: .automatic,
                anthropicDisplay: .summarized,
                legacyBudgetTokens: 4096
            )
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ReasoningContinuationState.self, from: data)

        #expect(decoded == state)
    }

    private func resolve(
        model: String,
        endpointType: APIEndpointType,
        endpoint: String? = nil
    ) -> ResolvedReasoningConfiguration? {
        ReasoningCapabilityResolver.resolve(
            model: model,
            provider: .openai,
            endpointType: endpointType,
            endpoint: endpoint,
            configuration: .automatic
        )
    }

    private func openAIModelPolicy(
        model: String,
        endpointType: APIEndpointType
    ) -> ReasoningCapabilityProfile? {
        ReasoningCapabilityResolver.modelPolicy(
            model: model,
            provider: .openai,
            endpointType: endpointType
        )
    }

    private func anthropicModelPolicy(
        model: String,
        mode: AnthropicThinkingMode = .adaptive
    ) -> ReasoningCapabilityProfile? {
        ReasoningCapabilityResolver.modelPolicy(
            model: model,
            provider: .anthropic,
            endpointType: .chatCompletions,
            anthropicMode: mode
        )
    }
}

// swiftlint:enable identifier_name
