// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

struct AnthropicConfigurationView: View {
    @ObservedObject private var aiService = AIService.shared
    @Binding var tempModelName: String
    @Binding var tempAPIKey: String
    @Binding var tempEndpoint: String
    @Binding var tempThinkingBudget: AnthropicThinkingBudget
    @Binding var showAPIKey: Bool
    @Binding var selectedModelName: String?
    @Binding var validationStatus: APISettingsView.ValidationStatus

    @State private var isValidating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Anthropic Configuration")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Model Name")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text("Required")
                            .font(Typography.micro)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, Spacing.xxxs)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
                    }
                    TextField("claude-sonnet-4-20250514", text: $tempModelName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempModelName) { _, _ in
                            validationStatus = .notChecked
                        }
                    Text("Claude model identifier (e.g., claude-sonnet-4-20250514, claude-opus-4-20250514)")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Endpoint URL")
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
                    TextField("https://api.anthropic.com or http://localhost:8000", text: $tempEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempEndpoint) { _, _ in
                            validationStatus = .notChecked
                        }
                    Text("Leave empty for the default Anthropic API. Enter a custom HTTPS URL for proxies or Azure; HTTP is only allowed for localhost development.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("API Key")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text("Required")
                            .font(Typography.micro)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, Spacing.xxxs)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
                    }
                    HStack(spacing: Spacing.sm) {
                        if showAPIKey {
                            TextField("sk-ant-...", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-ant-...", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: {
                            showAPIKey.toggle()
                        }) {
                            Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: Typography.Size.sm))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: Spacing.Component.avatarSmall, height: Spacing.Component.avatarSmall)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                    }
                    .onChange(of: tempAPIKey) { _, _ in
                        validationStatus = .notChecked
                    }
                    Text("Your Anthropic API key (stored securely)")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Extended Thinking Budget")
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
                    Picker("Extended Thinking Budget", selection: $tempThinkingBudget) {
                        ForEach(AnthropicThinkingBudget.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("settings.anthropic.thinkingBudgetPicker")
                    Text("Allocate thinking tokens for Claude extended thinking. Choose Off to disable.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Spacing.lg)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))

            HStack(spacing: Spacing.md) {
                Button {
                    Task {
                        await validateAnthropicConfiguration()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                        Text("Validate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(tempModelName.isEmpty || tempAPIKey.isEmpty || isValidating)
                .controlSize(.large)

                if let selectedName = selectedModelName,
                   aiService.customModels.contains(selectedName)
                {
                    Button {
                        saveAnthropicModel()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                            Text("Update Model")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(tempModelName.isEmpty || tempAPIKey.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        saveAnthropicModel()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Model")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(tempModelName.isEmpty || tempAPIKey.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            ValidationStatusCard(validationStatus: validationStatus)
        }
    }

    private func validateAnthropicConfiguration() async {
        isValidating = true
        validationStatus = .checking

        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !modelName.isEmpty else {
            validationStatus = .invalid("Model name is required")
            isValidating = false
            return
        }

        guard !apiKey.isEmpty else {
            validationStatus = .invalid("API key is required")
            isValidating = false
            return
        }

        if !endpoint.isEmpty {
            do {
                _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: endpoint)
            } catch {
                validationStatus = .invalid("Invalid endpoint: \(error.localizedDescription)")
                isValidating = false
                return
            }
        }

        do {
            let url = try AnthropicEndpointResolver.messagesURL(
                customEndpoint: endpoint.isEmpty ? nil : endpoint
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let body: [String: Any] = [
                "model": modelName,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "Hi"]]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                validationStatus = .invalid("Invalid response")
                isValidating = false
                return
            }

            if httpResponse.statusCode == 200 {
                validationStatus = .valid
            } else if httpResponse.statusCode == 401 {
                validationStatus = .invalid("Invalid API key")
            } else if httpResponse.statusCode == 404 {
                validationStatus = .invalid("Model not found: \(modelName)")
            } else {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String
                {
                    validationStatus = .invalid(message)
                } else {
                    validationStatus = .invalid("HTTP \(httpResponse.statusCode)")
                }
            }
        } catch {
            validationStatus = .invalid("Connection failed: \(error.localizedDescription)")
        }

        isValidating = false
    }

    private func saveAnthropicModel() {
        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !modelName.isEmpty, !apiKey.isEmpty else { return }

        if let oldName = selectedModelName, oldName != modelName {
            aiService.customModels.removeAll { $0 == oldName }
            aiService.modelProviders.removeValue(forKey: oldName)
            aiService.modelAPIKeys.removeValue(forKey: oldName)
            aiService.modelEndpoints.removeValue(forKey: oldName)
            aiService.modelEndpointTypes.removeValue(forKey: oldName)
            aiService.modelThinkingBudgets.removeValue(forKey: oldName)
        }

        if !aiService.customModels.contains(modelName) {
            aiService.customModels.append(modelName)
        }

        aiService.modelProviders[modelName] = .anthropic
        aiService.modelAPIKeys[modelName] = apiKey

        if !endpoint.isEmpty {
            aiService.modelEndpoints[modelName] = endpoint
        } else {
            aiService.modelEndpoints.removeValue(forKey: modelName)
        }

        if let budgetTokens = tempThinkingBudget.budgetTokens {
            aiService.modelThinkingBudgets[modelName] = budgetTokens
        } else {
            aiService.modelThinkingBudgets.removeValue(forKey: modelName)
        }

        selectedModelName = modelName
        validationStatus = .notChecked
    }
}

#endif
