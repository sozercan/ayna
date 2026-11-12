import SwiftUI

#if !os(watchOS)
    /// Thinking-effort controls shown inline under the selected model in the
    /// model selector.
    ///
    /// The stepped slider covers activation and effort; provider-specific
    /// options stay behind an "Options" disclosure.
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

        private var selection: ChatReasoningEffortSelection {
            ChatReasoningEffortSelection(models: modelContexts, configuration: configuration)
        }

        private var singleModelContext: ChatReasoningModelContext? {
            modelContexts.count == 1 ? modelContexts.first : nil
        }

        private var hasAdvancedControls: Bool {
            guard let context = singleModelContext else { return false }
            return ModelReasoningSettingsPresentation(
                model: context.model,
                provider: context.provider,
                endpointType: context.endpointType,
                endpoint: context.endpoint,
                configuration: configuration
            ).hasAdvancedControls
        }

        private var defaultConfiguration: ModelReasoningConfiguration {
            presentation.normalizedConfiguration(.automatic)
        }

        private var isAtDefault: Bool {
            configuration == defaultConfiguration
        }

        private var valueLabel: String {
            configuration.thinkingEffortBadge ?? "Model default"
        }

        var body: some View {
            if presentation.isAvailable {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if selection.stops.isEmpty {
                        Text("Thinking effort isn't adjustable for this model.")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ReasoningEffortStepSlider(
                            stepCount: selection.stops.count,
                            selection: stopIndexBinding,
                            valueLabel: valueLabel
                        )
                        .accessibilityIdentifier("\(identifier).effort")
                    }

                    if models.count > 1 {
                        Text("Applies to all \(models.count) selected models.")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if hasAdvancedControls || !isAtDefault {
                        footer
                    }

                    if showsAdvanced, hasAdvancedControls, let context = singleModelContext {
                        ModelReasoningSettingsControls(
                            configuration: $configuration,
                            model: context.model,
                            provider: context.provider,
                            endpointType: context.endpointType,
                            endpoint: context.endpoint,
                            identifierPrefix: identifier
                        )
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

        private var footer: some View {
            HStack(spacing: Spacing.sm) {
                if hasAdvancedControls {
                    Button {
                        withAnimation(Motion.springSnappy) {
                            showsAdvanced.toggle()
                        }
                    } label: {
                        HStack(spacing: Spacing.xxs) {
                            Text("Options")
                            Image(systemName: "chevron.right")
                                .font(.system(size: Typography.Size.xs, weight: .semibold))
                                .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsAdvanced ? "Hide thinking options" : "Show thinking options")
                    .accessibilityIdentifier("\(identifier).advanced")
                }

                Spacer(minLength: Spacing.sm)

                if !isAtDefault {
                    Button {
                        withAnimation(Motion.springSnappy) {
                            configuration = defaultConfiguration
                        }
                    } label: {
                        Label("Default", systemImage: "arrow.counterclockwise")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reset to model default")
                    .accessibilityLabel("Reset thinking to model default")
                    .accessibilityIdentifier("\(identifier).reset")
                }
            }
            .font(Typography.caption)
            .foregroundStyle(Theme.textSecondary)
        }

        private var stopIndexBinding: Binding<Int?> {
            Binding(
                get: {
                    selection.selectedIndex(for: configuration)
                },
                set: { newValue in
                    let stops = selection.stops
                    configuration = selection.configuration(
                        selecting: newValue.flatMap { stops.indices.contains($0) ? stops[$0] : nil },
                        from: configuration
                    )
                }
            )
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
