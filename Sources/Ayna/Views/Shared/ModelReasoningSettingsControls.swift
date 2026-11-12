import SwiftUI

/// Provider-specific reasoning options shown behind the thinking-effort slider.
///
/// Activation and effort are driven by the slider itself, so they are not repeated here.
struct ModelReasoningSettingsControls: View {
    @Binding var configuration: ModelReasoningConfiguration
    let model: String
    let provider: AIProvider
    let endpointType: APIEndpointType
    let endpoint: String?
    var identifierPrefix = "chat.reasoning"

    private var presentation: ModelReasoningSettingsPresentation {
        ModelReasoningSettingsPresentation(
            model: model,
            provider: provider,
            endpointType: endpointType,
            endpoint: endpoint,
            configuration: configuration
        )
    }

    private var normalizationInput: NormalizationInput {
        NormalizationInput(
            model: model,
            provider: provider,
            endpointType: endpointType,
            endpoint: endpoint,
            activation: configuration.activation,
            anthropicMode: configuration.anthropicMode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            controls
        }
        .onAppear {
            normalizeConfiguration()
        }
        .onChange(of: normalizationInput) { _, _ in
            normalizeConfiguration()
        }
    }

    @ViewBuilder
    private var controls: some View {
        if presentation.showsAnthropicMode {
            Picker("Thinking Mode", selection: $configuration.anthropicMode) {
                ForEach(presentation.anthropicModeOptions, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).anthropicMode")
        }

        if presentation.showsOpenAIMode {
            Picker("Reasoning Mode", selection: $configuration.openAIMode) {
                Text("Model Default").tag(nil as OpenAIReasoningMode?)
                ForEach(presentation.openAIModeOptions, id: \.self) { mode in
                    Text(mode.displayName).tag(mode as OpenAIReasoningMode?)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).openAIMode")
        }

        if presentation.showsOpenAIContext {
            Picker("Reasoning Context", selection: $configuration.openAIContext) {
                ForEach(presentation.openAIContextOptions, id: \.self) { context in
                    Text(context.displayName).tag(context)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).openAIContext")
        }

        if presentation.showsSummary {
            Picker("Reasoning Summary", selection: $configuration.summary) {
                ForEach(presentation.summaryOptions, id: \.self) { summary in
                    Text(summary.displayName).tag(summary)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).summary")
        }

        if presentation.showsAnthropicDisplay {
            Picker("Thinking Display", selection: $configuration.anthropicDisplay) {
                ForEach(AnthropicThinkingDisplay.allCases, id: \.self) { display in
                    Text(display.displayName).tag(display)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).anthropicDisplay")
        }

        if presentation.showsLegacyBudget {
            Stepper(
                "Thinking Budget: \(configuration.legacyBudgetTokens) tokens",
                value: legacyBudgetBinding,
                step: 1024
            )
            .accessibilityIdentifier("\(identifierPrefix).legacyBudget")
        }

        if let unavailableDescription = presentation.unavailableDescription {
            Text(unavailableDescription)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func normalizeConfiguration() {
        let normalized = ModelReasoningSettingsPresentation.normalizedConfiguration(
            model: model,
            provider: provider,
            endpointType: endpointType,
            endpoint: endpoint,
            configuration: configuration
        )
        if normalized != configuration {
            configuration = normalized
        }
    }

    private var legacyBudgetBinding: Binding<Int> {
        Binding(
            get: {
                max(
                    configuration.legacyBudgetTokens,
                    ModelReasoningConfiguration.minimumLegacyBudgetTokens
                )
            },
            set: { newValue in
                configuration.legacyBudgetTokens = max(
                    newValue,
                    ModelReasoningConfiguration.minimumLegacyBudgetTokens
                )
            }
        )
    }

    private struct NormalizationInput: Equatable {
        let model: String
        let provider: AIProvider
        let endpointType: APIEndpointType
        let endpoint: String?
        let activation: ReasoningActivationMode
        let anthropicMode: AnthropicThinkingMode
    }
}
