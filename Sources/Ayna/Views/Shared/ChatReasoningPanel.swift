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

        /// Slider stops: "Auto" (the model default) followed by the selection's stops.
        private var stopLabels: [String] {
            ["Auto"] + selection.stops.map(\.displayName)
        }

        private var selectedStopIndex: Int {
            selection.selectedIndex(for: configuration).map { $0 + 1 } ?? 0
        }

        var body: some View {
            if presentation.isAvailable {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    labelRow

                    if selection.stops.isEmpty {
                        Text("Effort isn't adjustable for this model.")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ReasoningEffortStepSlider(
                            stepCount: stopLabels.count,
                            selection: stopIndexBinding,
                            valueLabel: stopLabels[selectedStopIndex]
                        )
                        .accessibilityIdentifier("\(identifier).effort")
                    }

                    if models.count > 1 {
                        Text("Applies to all \(models.count) selected models.")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textTertiary)
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

        private var labelRow: some View {
            HStack(spacing: Spacing.xs) {
                Text("Thinking")
                    .foregroundStyle(Theme.textSecondary)
                Text(selection.stops.isEmpty ? "Auto" : stopLabels[selectedStopIndex])
                    .foregroundStyle(selectedStopIndex == 0 ? Theme.textPrimary : Theme.accent)
                    .contentTransition(.numericText())
                    .animation(Motion.springSnappy, value: selectedStopIndex)

                Spacer(minLength: Spacing.sm)

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
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsAdvanced ? "Hide thinking options" : "Show thinking options")
                    .accessibilityIdentifier("\(identifier).advanced")
                }
            }
            .font(Typography.captionBold)
        }

        private var stopIndexBinding: Binding<Int?> {
            Binding(
                get: {
                    selectedStopIndex
                },
                set: { newValue in
                    let stops = selection.stops
                    let stop: ChatReasoningEffortSelection.Stop? = newValue.flatMap { index in
                        stops.indices.contains(index - 1) ? stops[index - 1] : nil
                    }
                    configuration = selection.configuration(selecting: stop, from: configuration)
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

    /// Slim stepped slider that snaps to discrete thinking-effort stops.
    private struct ReasoningEffortStepSlider: View {
        let stepCount: Int
        @Binding var selection: Int?
        let valueLabel: String

        #if os(iOS)
            private let hitHeight: CGFloat = 32
            private let thumbSize: CGFloat = 22
        #else
            private let hitHeight: CGFloat = 22
            private let thumbSize: CGFloat = 16
        #endif
        private let trackHeight: CGFloat = 4
        private let tickSize: CGFloat = 4

        var body: some View {
            GeometryReader { proxy in
                let inset = thumbSize / 2
                let usableWidth = max(proxy.size.width - thumbSize, 1)
                let lastIndex = max(stepCount - 1, 1)
                let current = selection ?? 0
                let xPosition = { (index: Int) -> CGFloat in
                    inset + usableWidth * CGFloat(index) / CGFloat(lastIndex)
                }
                let midY = hitHeight / 2

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: trackHeight)
                        .padding(.horizontal, inset)

                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(xPosition(current) - inset, 0), height: trackHeight)
                        .offset(x: inset)

                    ForEach(0 ..< stepCount, id: \.self) { index in
                        Circle()
                            .fill(index <= current ? Theme.accent : Color.secondary.opacity(0.5))
                            .frame(width: tickSize, height: tickSize)
                            .position(x: xPosition(index), y: midY)
                    }

                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: thumbSize, height: thumbSize)
                        .position(x: xPosition(current), y: midY)
                }
                .frame(width: proxy.size.width, height: hitHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = (value.location.x - inset) / usableWidth
                            let index = min(max(Int((fraction * CGFloat(lastIndex)).rounded()), 0), stepCount - 1)
                            if selection != index {
                                withAnimation(Motion.springSnappy) {
                                    selection = index
                                }
                            }
                        }
                )
            }
            .frame(height: hitHeight)
            .sensoryFeedback(.selection, trigger: selection)
            .accessibilityElement()
            .accessibilityLabel("Thinking effort")
            .accessibilityValue(valueLabel)
            .accessibilityAdjustableAction { direction in
                let current = selection ?? 0
                switch direction {
                case .increment:
                    selection = min(current + 1, stepCount - 1)
                case .decrement:
                    selection = max(current - 1, 0)
                @unknown default:
                    break
                }
            }
        }
    }
#endif
