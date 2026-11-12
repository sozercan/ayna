import SwiftUI

#if !os(watchOS)
    /// Conversation-level thinking-effort controls embedded in the model selector.
    ///
    /// Leads with a stepped effort slider; provider-specific knobs stay behind the
    /// header disclosure so the common case is a single drag.
    struct ChatReasoningPanel: View {
        @Binding var configuration: ModelReasoningConfiguration
        let selectedModels: Set<String>
        var primaryModel = ""
        let identifier: String

        @ObservedObject private var aiService = AIService.shared
        @State private var showsAdvanced = false

        /// Whether the panel has anything to show for the given selection.
        static func isAvailable(selectedModels: Set<String>, primaryModel: String = "") -> Bool {
            let models = normalizedModels(selectedModels: selectedModels, primaryModel: primaryModel)
            return ChatReasoningSettingsPresentation(
                models: contexts(for: models, aiService: AIService.shared),
                configuration: .automatic
            ).isAvailable
        }

        private static func normalizedModels(selectedModels: Set<String>, primaryModel: String) -> [String] {
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

        private static func contexts(for models: [String], aiService: AIService) -> [ChatReasoningModelContext] {
            models.map { model in
                ChatReasoningModelContext(
                    model: model,
                    provider: aiService.modelProviders[model] ?? aiService.provider,
                    endpointType: aiService.modelEndpointTypes[model] ?? .chatCompletions,
                    endpoint: aiService.modelEndpoints[model]
                )
            }
        }

        private var models: [String] {
            Self.normalizedModels(selectedModels: selectedModels, primaryModel: primaryModel)
        }

        private var modelContexts: [ChatReasoningModelContext] {
            Self.contexts(for: models, aiService: aiService)
        }

        private var presentation: ChatReasoningSettingsPresentation {
            ChatReasoningSettingsPresentation(models: modelContexts, configuration: configuration)
        }

        private var effortSelection: ChatReasoningEffortSelection {
            ChatReasoningEffortSelection(models: modelContexts, configuration: configuration)
        }

        private var effortOptions: [ReasoningEffort] {
            effortSelection.options
        }

        private var defaultConfiguration: ModelReasoningConfiguration {
            presentation.normalizedConfiguration(.automatic)
        }

        private var isAtDefault: Bool {
            configuration == defaultConfiguration
        }

        private var levelLabel: String {
            configuration.thinkingEffortBadge ?? "Default"
        }

        private var modelTitle: String {
            models.count == 1 ? models[0] : "\(models.count) models"
        }

        var body: some View {
            if presentation.isAvailable {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    header

                    if effortOptions.isEmpty {
                        Text(emptyEffortDescription)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ReasoningEffortStepSlider(
                            stepCount: effortOptions.count,
                            selection: effortIndexBinding,
                            valueLabel: levelLabel
                        )
                        .accessibilityIdentifier("\(identifier).effort")
                    }

                    if showsAdvanced {
                        advancedControls
                            .padding(.top, Spacing.xs)
                            .transition(.opacity)
                    }
                }
                .onAppear {
                    normalizeConfiguration()
                }
                .onChange(of: models) { _, _ in
                    normalizeConfiguration()
                }
            }
        }

        private var header: some View {
            HStack(spacing: Spacing.sm) {
                Button {
                    withAnimation(Motion.springSnappy) {
                        showsAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text(modelTitle)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(levelLabel)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: Typography.Size.xs, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                    }
                    .font(Typography.headline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAdvanced ? "Hide advanced thinking settings" : "Show advanced thinking settings")
                .accessibilityValue("\(modelTitle), \(levelLabel)")
                .accessibilityIdentifier("\(identifier).advanced")

                Spacer(minLength: Spacing.sm)

                Button {
                    withAnimation(Motion.springSnappy) {
                        configuration = defaultConfiguration
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: Typography.Size.body, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isAtDefault)
                .opacity(isAtDefault ? 0.4 : 1)
                .help("Reset to model default")
                .accessibilityLabel("Reset thinking to model default")
                .accessibilityIdentifier("\(identifier).reset")
            }
        }

        private var advancedControls: some View {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if models.count == 1, let model = models.first {
                    ModelReasoningSettingsControls(
                        configuration: $configuration,
                        model: model,
                        provider: provider(for: model),
                        endpointType: endpointType(for: model),
                        endpoint: aiService.modelEndpoints[model],
                        identifierPrefix: identifier,
                        includesEffortPicker: false
                    )
                } else {
                    Picker("Activation", selection: $configuration.activation) {
                        ForEach(presentation.activationOptions, id: \.self) { activation in
                            Text(activation.displayName).tag(activation)
                        }
                    }

                    Text("Only settings supported by every selected model are shown.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var emptyEffortDescription: String {
            switch configuration.activation {
            case .explicitlyDisabled:
                "Thinking is turned off."
            case .disabled:
                "Using the provider's default thinking behavior."
            case .automatic, .enabled:
                "Effort levels aren't available for this model."
            }
        }

        private var effortIndexBinding: Binding<Int?> {
            Binding(
                get: {
                    configuration.effort.flatMap { effortOptions.firstIndex(of: $0) }
                },
                set: { newValue in
                    configuration = effortSelection.configuration(
                        selecting: newValue.map { effortOptions[$0] },
                        from: configuration
                    )
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

    /// Capsule slider that snaps to discrete effort stops.
    ///
    /// A `nil` selection means "model default": the track is shown unfilled with
    /// no thumb, and any tap or drag picks the nearest stop.
    private struct ReasoningEffortStepSlider: View {
        let stepCount: Int
        @Binding var selection: Int?
        let valueLabel: String

        private var trackHeight: CGFloat {
            #if os(iOS)
                36
            #else
                30
            #endif
        }

        private let dotSize: CGFloat = 5
        private let thumbInset: CGFloat = 3

        var body: some View {
            GeometryReader { proxy in
                let width = proxy.size.width
                let radius = trackHeight / 2
                let usableWidth = max(width - trackHeight, 1)
                let lastIndex = max(stepCount - 1, 1)
                let xPosition = { (index: Int) -> CGFloat in
                    radius + usableWidth * CGFloat(index) / CGFloat(lastIndex)
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))

                    if let selection {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: xPosition(selection) + radius)
                    }

                    ForEach(0 ..< stepCount, id: \.self) { index in
                        Circle()
                            .fill(dotColor(for: index))
                            .frame(width: dotSize, height: dotSize)
                            .position(x: xPosition(index), y: radius)
                    }

                    if let selection {
                        Circle()
                            .fill(Color.white)
                            .shadow(color: Theme.shadow.opacity(0.6), radius: 2, y: 1)
                            .frame(width: trackHeight - thumbInset * 2, height: trackHeight - thumbInset * 2)
                            .position(x: xPosition(selection), y: radius)
                    }
                }
                .frame(width: width, height: trackHeight)
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = (value.location.x - radius) / usableWidth
                            let index = min(max(Int((fraction * CGFloat(lastIndex)).rounded()), 0), stepCount - 1)
                            if selection != index {
                                withAnimation(Motion.springSnappy) {
                                    selection = index
                                }
                            }
                        }
                )
            }
            .frame(height: trackHeight)
            .sensoryFeedback(.selection, trigger: selection)
            .accessibilityElement()
            .accessibilityLabel("Thinking effort")
            .accessibilityValue(valueLabel)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    selection = min((selection ?? -1) + 1, stepCount - 1)
                case .decrement:
                    if let selection, selection > 0 {
                        self.selection = selection - 1
                    } else {
                        self.selection = nil
                    }
                @unknown default:
                    break
                }
            }
        }

        private func dotColor(for index: Int) -> Color {
            if let selection, index <= selection {
                return Color.white.opacity(0.7)
            }
            return Theme.textSecondary.opacity(0.6)
        }
    }
#endif
