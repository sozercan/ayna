import SwiftUI

/// Provider-aware reasoning controls used from the chat composer.
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
        Picker("Activation", selection: $configuration.activation) {
            ForEach(presentation.activationOptions, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .disabled(!presentation.isActivationEnabled)
        .accessibilityIdentifier("\(identifierPrefix).activation")

        if presentation.showsAnthropicMode {
            Picker("Thinking Mode", selection: $configuration.anthropicMode) {
                ForEach(presentation.anthropicModeOptions, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).anthropicMode")
        }

        if presentation.showsEffort {
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

// Compact conversation-level reasoning picker inspired by the inline effort
// controls in modern chat composers.
#if !os(watchOS)
    struct ChatReasoningControl: View {
        @Binding var configuration: ModelReasoningConfiguration
        let selectedModels: Set<String>
        let primaryModel: String
        let identifier: String

        @ObservedObject private var aiService = AIService.shared
        @State private var isPresented = false

        private var models: [String] {
            let normalized = selectedModels
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            if !normalized.isEmpty {
                return normalized
            }
            let primary = primaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return primary.isEmpty ? [] : [primary]
        }

        private var presentation: ChatReasoningSettingsPresentation {
            ChatReasoningSettingsPresentation(
                models: models.map { model in
                    ChatReasoningModelContext(
                        model: model,
                        provider: provider(for: model),
                        endpointType: endpointType(for: model),
                        endpoint: aiService.modelEndpoints[model]
                    )
                },
                configuration: configuration
            )
        }

        private var commonEffortOptions: [ReasoningEffort] {
            presentation.effortOptions
        }

        private var commonActivationOptions: [ReasoningActivationMode] {
            presentation.activationOptions
        }

        private var effortChoices: [ReasoningEffort?] {
            [nil] + commonEffortOptions.map(Optional.some)
        }

        private var isAvailable: Bool {
            presentation.isAvailable
        }

        private var controlMinimumHeight: CGFloat {
            #if os(iOS)
                44
            #else
                34
            #endif
        }

        private var accessibilityLabel: String {
            models.count > 1 ? "Reasoning effort for \(models.count) models" : "Reasoning effort"
        }

        private var compactLabel: String {
            switch configuration.activation {
            case .automatic:
                configuration.effort?.displayName ?? "Auto"
            case .disabled:
                "Default"
            case .explicitlyDisabled:
                "Off"
            case .enabled:
                configuration.effort?.displayName ?? "On"
            }
        }

        var body: some View {
            if isAvailable {
                Button {
                    isPresented.toggle()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "brain")
                            .font(.system(size: Typography.Size.caption))
                        Text(compactLabel)
                            .font(Typography.modelName)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: Typography.Size.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Spacing.md)
                    .frame(minHeight: controlMinimumHeight)
                    .background(Theme.backgroundTertiary.opacity(0.8), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(compactLabel)
                .accessibilityIdentifier(identifier)
                .popover(isPresented: $isPresented) {
                    popoverContent
                    #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                    #endif
                }
                .onAppear {
                    normalizeConfiguration()
                }
                .onChange(of: models) { _, _ in
                    normalizeConfiguration()
                }
            }
        }

        private var popoverContent: some View {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text("Reasoning")
                        .font(Typography.headline)
                    Spacer()
                    Text(compactLabel)
                        .font(Typography.captionBold)
                        .foregroundStyle(Theme.textSecondary)
                }

                if effortChoices.count > 1 {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Slider(
                            value: effortIndexBinding,
                            in: 0 ... Double(effortChoices.count - 1),
                            step: 1
                        )
                        .accessibilityLabel("Reasoning effort")
                        .accessibilityValue(compactLabel)

                        HStack {
                            Text("Model default")
                            Spacer()
                            Text(commonEffortOptions.last?.displayName ?? "")
                        }
                        .font(Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack {
                            Text("Model")
                            Spacer()
                            Text(models.count == 1 ? models[0] : "\(models.count) models")
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }

                        if models.count == 1, let model = models.first {
                            ModelReasoningSettingsControls(
                                configuration: $configuration,
                                model: model,
                                provider: provider(for: model),
                                endpointType: endpointType(for: model),
                                endpoint: aiService.modelEndpoints[model],
                                identifierPrefix: identifier
                            )
                        } else {
                            Picker("Activation", selection: $configuration.activation) {
                                ForEach(commonActivationOptions, id: \.self) { activation in
                                    Text(activation.displayName).tag(activation)
                                }
                            }

                            if !commonEffortOptions.isEmpty {
                                Picker("Effort", selection: $configuration.effort) {
                                    Text("Model Default").tag(nil as ReasoningEffort?)
                                    ForEach(commonEffortOptions, id: \.self) { effort in
                                        Text(effort.displayName).tag(effort as ReasoningEffort?)
                                    }
                                }
                            }

                            Text("Only controls supported by every selected model are shown.")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.top, Spacing.sm)
                }
            }
            .padding()
            .frame(minWidth: 300, idealWidth: 340)
        }

        private var effortIndexBinding: Binding<Double> {
            Binding(
                get: {
                    Double(effortChoices.firstIndex(where: { $0 == configuration.effort }) ?? 0)
                },
                set: { newValue in
                    let index = min(max(Int(newValue.rounded()), 0), effortChoices.count - 1)
                    configuration.effort = effortChoices[index]
                }
            )
        }

        private func provider(for model: String) -> AIProvider {
            aiService.modelProviders[model] ?? aiService.provider
        }

        private func endpointType(for model: String) -> APIEndpointType {
            aiService.modelEndpointTypes[model] ?? .chatCompletions
        }

        private func normalizeConfiguration() {
            let normalized = presentation.normalizedConfiguration(configuration)
            if normalized != configuration {
                configuration = normalized
            }
        }
    }
#endif
