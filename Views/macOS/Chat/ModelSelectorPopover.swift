//
//  ModelSelectorPopover.swift
//  ayna
//
//  Extracted from MacChatView/MacNewChatView - Model selection popover
//

import SwiftUI

/// A popover for selecting AI models with multi-model support
struct ModelSelectorPopover: View {
    @Binding var selectedModels: Set<String>
    @Binding var selectedModel: String
    let onToggleModel: (String) -> Void
    let onClearMultiSelection: () -> Void

    @ObservedObject private var aiService = AIService.shared

    /// Whether multi-model selection is enabled in preferences
    private var multiModelEnabled: Bool {
        AppPreferences.multiModelSelectionEnabled
    }

    /// The capability type of currently selected models
    private var selectedCapabilityType: AIService.ModelCapability? {
        guard let firstSelected = selectedModels.first else { return nil }
        return aiService.getModelCapability(firstSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header
            Text(multiModelEnabled ? "Select models" : "Select model")
                .font(Typography.captionBold)
                .foregroundStyle(Theme.textSecondary)

            if multiModelEnabled {
                Text("1 model = single response, 2+ = compare")
                    .font(Typography.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }

            Divider()
                .padding(.vertical, Spacing.xxs)

            // Model list or empty state
            if aiService.usableModels.isEmpty {
                emptyStateView
            } else {
                modelListView
            }

            // Clear multi-selection button
            if multiModelEnabled, selectedModels.count > 1 {
                clearMultiSelectionButton
            }
        }
        .padding()
        .frame(minWidth: 220)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        SettingsLink {
            Label("Add Model in Settings", systemImage: "slider.horizontal.3")
        }
        .routeSettings(to: .models)
    }

    // MARK: - Model List

    private var modelListView: some View {
        ForEach(aiService.usableModels, id: \.self) { model in
            modelRow(for: model)
        }
    }

    private func modelRow(for model: String) -> some View {
        let isSelected = selectedModels.contains(model)
        let modelCapability = aiService.getModelCapability(model)
        let isCapabilityMismatch: Bool = {
            guard let selectedType = selectedCapabilityType else { return false }
            return modelCapability != selectedType
        }()
        // Only disable in multi-model mode when mixing capability types
        let isDisabled = multiModelEnabled && !isSelected && isCapabilityMismatch

        return Button(action: { onToggleModel(model) }) {
            HStack {
                // Checkbox/radio icon
                selectionIcon(isSelected: isSelected)

                // Model name
                Text(model)
                    .font(Typography.modelName)

                Spacer()

                // Capability badge for image gen models
                if modelCapability == .imageGeneration {
                    Image(systemName: "photo")
                        .font(.system(size: Typography.Size.xs))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, Spacing.xxs)
            .padding(.horizontal, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
                    .fill(isSelected ? Theme.selection : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    @ViewBuilder
    private func selectionIcon(isSelected: Bool) -> some View {
        if multiModelEnabled {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .font(.system(size: Typography.Size.body))
        } else {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .font(.system(size: Typography.Size.body))
        }
    }

    // MARK: - Clear Multi-Selection

    private var clearMultiSelectionButton: some View {
        VStack {
            Divider()
                .padding(.vertical, Spacing.xxs)

            Button(action: onClearMultiSelection) {
                HStack {
                    Image(systemName: "xmark.circle")
                    Text("Clear multi-selection")
                }
                .font(Typography.footnote)
                .foregroundStyle(Theme.destructive)
            }
            .buttonStyle(.plain)
        }
    }
}
