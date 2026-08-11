import SwiftUI

/// Shared controls used by the macOS and iOS model editors.
struct ModelReasoningSettingsControls: View {
    @Binding var configuration: ModelReasoningConfiguration
    let model: String
    let provider: AIProvider
    let endpointType: APIEndpointType
    let endpoint: String?

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
        .accessibilityIdentifier("settings.reasoning.activation")

        if presentation.showsAnthropicMode {
            Picker("Thinking Mode", selection: $configuration.anthropicMode) {
                ForEach(presentation.anthropicModeOptions, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.reasoning.anthropicMode")
        }

        if presentation.showsEffort {
            Picker("Effort", selection: $configuration.effort) {
                Text("Model Default").tag(nil as ReasoningEffort?)
                ForEach(presentation.effortOptions, id: \.self) { effort in
                    Text(effort.displayName).tag(effort as ReasoningEffort?)
                }
            }
            .accessibilityIdentifier("settings.reasoning.effort")
        }

        if presentation.showsOpenAIMode {
            Picker("Reasoning Mode", selection: $configuration.openAIMode) {
                Text("Model Default").tag(nil as OpenAIReasoningMode?)
                ForEach(presentation.openAIModeOptions, id: \.self) { mode in
                    Text(mode.displayName).tag(mode as OpenAIReasoningMode?)
                }
            }
            .accessibilityIdentifier("settings.reasoning.openAIMode")
        }

        if presentation.showsOpenAIContext {
            Picker("Reasoning Context", selection: $configuration.openAIContext) {
                ForEach(presentation.openAIContextOptions, id: \.self) { context in
                    Text(context.displayName).tag(context)
                }
            }
            .accessibilityIdentifier("settings.reasoning.openAIContext")
        }

        if presentation.showsSummary {
            Picker("Reasoning Summary", selection: $configuration.summary) {
                ForEach(presentation.summaryOptions, id: \.self) { summary in
                    Text(summary.displayName).tag(summary)
                }
            }
            .accessibilityIdentifier("settings.reasoning.summary")
        }

        if presentation.showsAnthropicDisplay {
            Picker("Thinking Display", selection: $configuration.anthropicDisplay) {
                ForEach(AnthropicThinkingDisplay.allCases, id: \.self) { display in
                    Text(display.displayName).tag(display)
                }
            }
            .accessibilityIdentifier("settings.reasoning.anthropicDisplay")
        }

        if presentation.showsLegacyBudget {
            Stepper(
                "Thinking Budget: \(configuration.legacyBudgetTokens) tokens",
                value: legacyBudgetBinding,
                step: 1024
            )
            .accessibilityIdentifier("settings.reasoning.legacyBudget")
        }

        Text(guidanceText)
            .font(Typography.caption)
            .foregroundStyle(Theme.textSecondary)
            .onAppear {
                normalizeConfiguration()
            }
            .onChange(of: normalizationInput) { _, _ in
                normalizeConfiguration()
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

    private var guidanceText: String {
        if let unavailableDescription = presentation.unavailableDescription {
            return unavailableDescription
        }
        return "Automatic enables supported controls for recognized first-party models. Provider Default omits reasoning controls; some models still reason by default. Use On for compatible custom endpoints or deployment aliases."
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
