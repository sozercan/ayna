//
//  ModelSettingsSection.swift
//  ayna
//
//  Extracted from MacSettingsView.swift - Model list and selection UI
//

import SwiftUI

/// Model list panel showing all configured models with selection and management
struct ModelListPanel: View {
    @ObservedObject private var aiService = AIService.shared
    @Binding var selectedModelName: String?
    let onCreateNew: () -> Void
    let onModelSelected: (String) -> Void
    let onRemoveModel: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            modelListView
        }
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)
        .background(Theme.backgroundSecondary)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Models")
                        .font(Typography.headline)
                    Text("Add and manage your AI models")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Button(action: onCreateNew) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add new model")
                .help("Add new model")
            }
        }
        .padding()
    }

    // MARK: - Model List

    private var modelListView: some View {
        ScrollView {
            if aiService.customModels.isEmpty {
                emptyStateView
            } else {
                modelRows
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "cpu")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No models added")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var modelRows: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(aiService.customModels, id: \.self) { model in
                ModelRowView(
                    model: model,
                    isSelected: selectedModelName == model,
                    isDefault: model == aiService.selectedModel,
                    provider: aiService.modelProviders[model],
                    onTap: { onModelSelected(model) },
                    onSetDefault: { aiService.selectedModel = model },
                    onRemove: { onRemoveModel(model) }
                )
            }
        }
        .padding(Spacing.sm)
    }
}

/// Single model row in the list
struct ModelRowView: View {
    let model: String
    let isSelected: Bool
    let isDefault: Bool
    let provider: AIProvider?
    let onTap: () -> Void
    let onSetDefault: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(model)
                    .font(Typography.modelName)
                if let provider {
                    Text(provider.displayName)
                        .font(.system(size: Typography.Size.xs))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            HStack(spacing: Spacing.sm) {
                Button(action: onSetDefault) {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .foregroundStyle(isDefault ? .yellow : Theme.textSecondary)
                        .font(.system(size: Typography.Size.caption))
                }
                .buttonStyle(.plain)
                .help(isDefault ? "Default model" : "Set as default")

                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.statusError)
                        .font(.system(size: Typography.Size.caption))
                }
                .buttonStyle(.plain)
                .help("Remove model")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            isSelected ? Color.blue.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Validation status for model configuration
enum ModelValidationStatus {
    case notChecked
    case checking
    case valid
    case invalid(String)
}

/// Status indicator view for model validation
struct ValidationStatusView: View {
    let status: ModelValidationStatus

    var body: some View {
        HStack(spacing: Spacing.md) {
            statusIcon
            statusText
            Spacer()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .notChecked:
            Image(systemName: "circle.dotted")
                .font(.system(size: 24))
                .foregroundStyle(Theme.textSecondary)
        case .checking:
            ProgressView()
                .scaleEffect(1.2)
                .frame(width: 24, height: 24)
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.statusConnected)
        case .invalid:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.statusError)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case .notChecked:
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Not Validated")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                Text("Click 'Validate' to test your configuration")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .checking:
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Validating...")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                Text("Testing connection to API")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .valid:
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Configuration Valid")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.statusConnected)
                Text("Ready to add model")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case let .invalid(message):
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Configuration Invalid")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.statusError)
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
    }
}
