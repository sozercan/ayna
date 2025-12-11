//
//  ProviderSettingsSection.swift
//  ayna
//
//  Extracted from MacSettingsView.swift - Provider-specific configuration views
//

import SwiftUI

/// OpenAI provider configuration form
struct OpenAIConfigurationSection: View {
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var tempModelName: String
    @Binding var tempAPIKey: String
    @Binding var tempEndpoint: String
    @Binding var tempEndpointType: APIEndpointType
    @Binding var showAPIKey: Bool
    @Binding var selectedModelName: String?
    @Binding var validationStatus: ModelValidationStatus

    let onValidate: () async -> Void
    let onAddModel: () -> Void
    let onUpdateModel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Label("OpenAI Configuration", systemImage: "key.fill")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            configurationFields
            actionButtons
        }
        .padding(.horizontal)
    }

    // MARK: - Configuration Fields

    private var configurationFields: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            modelNameField
            endpointField
            apiKeyField
        }
        .padding(Spacing.lg)
        .background(Theme.backgroundSecondary)
        .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
    }

    private var modelNameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Model Name")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                Spacer()
                requiredBadge
            }
            TextField("gpt-4o, gpt-4o-mini, o1", text: $tempModelName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: tempModelName) { _, _ in
                    validationStatus = .notChecked
                }
            Text("The model identifier from OpenAI")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var endpointField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Endpoint URL")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                Spacer()
                requiredBadge
            }
            TextField("https://api.openai.com or http://localhost:8000", text: $tempEndpoint)
                .textFieldStyle(.roundedBorder)
                .onChange(of: tempEndpoint) { _, _ in
                    validationStatus = .notChecked
                }
            Text("OpenAI-compatible API endpoint (e.g., https://api.openai.com, http://localhost:8000). For Azure, enter https://<resource>.openai.azure.com and set Model Name to your deployment name.")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("API Key")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                Spacer()
                optionalBadge
            }
            HStack(spacing: Spacing.sm) {
                if showAPIKey {
                    TextField("sk-proj-...", text: $tempAPIKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("sk-proj-...", text: $tempAPIKey)
                        .textFieldStyle(.roundedBorder)
                }

                Button(action: { showAPIKey.toggle() }) {
                    Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: Typography.Size.sm))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                }
                .buttonStyle(.plain)
            }
            .onChange(of: tempAPIKey) { _, _ in
                validationStatus = .notChecked
            }
            Text("Your OpenAI API key (stored securely)")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: Spacing.md) {
            Button {
                Task { await onValidate() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("Validate")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tempEndpoint.isEmpty)
            .controlSize(.large)

            if let selectedName = selectedModelName, openAIService.customModels.contains(selectedName) {
                Button(action: onUpdateModel) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text("Update Model")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tempEndpoint.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(action: onAddModel) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Model")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tempEndpoint.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Badge Helpers

    private var requiredBadge: some View {
        Text("Required")
            .font(Typography.micro)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxxs)
            .background(Color.secondary.opacity(0.1))
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
    }

    private var optionalBadge: some View {
        Text("Optional")
            .font(Typography.micro)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxxs)
            .background(Color.secondary.opacity(0.1))
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
    }
}

/// Apple Intelligence provider configuration
struct AppleIntelligenceConfigurationSection: View {
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var tempModelName: String
    @Binding var selectedModelName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Label("Apple Intelligence Configuration", systemImage: "apple.logo")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            configurationContent
            actionButtons
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if #available(macOS 26.0, *) {
                let service = AppleIntelligenceService.shared

                availabilityStatus(service: service)
                modelNameField
            } else {
                macOSRequiredView
            }
        }
        .padding(Spacing.lg)
        .background(Theme.backgroundSecondary)
        .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
    }

    @available(macOS 26.0, *)
    private func availabilityStatus(service: AppleIntelligenceService) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Availability")
                .font(Typography.subheadline)
                .fontWeight(.medium)

            HStack(spacing: Spacing.sm) {
                Image(systemName: service.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(service.isAvailable ? Theme.statusConnected : Theme.statusConnecting)
                Text(service.availabilityDescription())
                    .font(Typography.subheadline)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))

            if !service.isAvailable {
                Text("Apple Intelligence must be enabled in System Settings → Apple Intelligence & Siri")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var modelNameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Model Name")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("Optional")
                    .font(Typography.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxxs)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
            }
            TextField("apple-intelligence", text: $tempModelName)
                .textFieldStyle(.roundedBorder)
            Text("A friendly name for this model (e.g., 'apple-intelligence', 'on-device')")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var macOSRequiredView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.statusConnecting)

            Text("macOS 26.0 or later required")
                .font(Typography.headline)

            Text("Apple Intelligence requires macOS Sequoia 26.0 or later with Apple Intelligence support.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.contentPadding)
        .background(Color.orange.opacity(0.1))
        .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
    }

    @ViewBuilder
    private var actionButtons: some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: Spacing.md) {
                Button {
                    let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalModelName = modelName.isEmpty ? "apple-intelligence" : modelName

                    if !openAIService.customModels.contains(finalModelName) {
                        openAIService.customModels.append(finalModelName)
                        openAIService.modelProviders[finalModelName] = .appleIntelligence
                        if openAIService.customModels.count == 1 {
                            openAIService.selectedModel = finalModelName
                        }
                        selectedModelName = finalModelName
                        tempModelName = ""
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Model")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

/// API Endpoint type selection view
struct EndpointTypeSelector: View {
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var selectedModelName: String?
    @Binding var tempEndpointType: APIEndpointType

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("API Endpoint", systemImage: "arrow.left.arrow.right")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            Picker("", selection: Binding(
                get: {
                    if let modelName = selectedModelName {
                        openAIService.modelEndpointTypes[modelName] ?? .chatCompletions
                    } else {
                        tempEndpointType
                    }
                },
                set: { newValue in
                    if let modelName = selectedModelName {
                        openAIService.modelEndpointTypes[modelName] = newValue
                    } else {
                        tempEndpointType = newValue
                    }
                }
            )) {
                ForEach(APIEndpointType.allCases, id: \.self) { endpointType in
                    Text(endpointType.displayName).tag(endpointType)
                }
            }
            .pickerStyle(.segmented)

            Text("Choose which API endpoint to use for this model")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal)
    }
}
