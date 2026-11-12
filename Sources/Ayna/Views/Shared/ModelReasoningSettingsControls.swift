import SwiftUI

/// Provider-aware reasoning controls used from the chat composer.
struct ModelReasoningSettingsControls: View {
    @Binding var configuration: ModelReasoningConfiguration
    let model: String
    let provider: AIProvider
    let endpointType: APIEndpointType
    let endpoint: String?
    var identifierPrefix = "chat.reasoning"
    /// The composer renders effort with its own slider, so it hides this picker.
    var includesEffortPicker = true

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
        Picker("Activation", selection: $configuration.activation) {
            ForEach(presentation.activationOptions, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .disabled(!presentation.isActivationEnabled)
        .accessibilityIdentifier("\(identifierPrefix).activation")
        .onAppear {
            normalizeConfiguration()
        }
        .onChange(of: normalizationInput) { _, _ in
            normalizeConfiguration()
        }

        if presentation.showsAnthropicMode {
            Picker("Thinking Mode", selection: $configuration.anthropicMode) {
                ForEach(presentation.anthropicModeOptions, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).anthropicMode")
        }

        if includesEffortPicker, presentation.showsEffort {
            Picker("Effort", selection: $configuration.effort) {
                Text("Model Default").tag(nil as ReasoningEffort?)
                ForEach(presentation.effortOptions, id: \.self) { effort in
                    Text(effort.displayName).tag(effort as ReasoningEffort?)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).effort")
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
