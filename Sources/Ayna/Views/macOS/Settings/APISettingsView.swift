// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

struct APISettingsView: View {
    @ObservedObject private var aiService = AIService.shared
    @State private var showAPIKey = false
    @State private var tempAPIKey = ""
    @State private var tempEndpoint = ""
    @State private var tempModelName = ""
    @State private var selectedModelName: String?
    @State private var tempEndpointType: APIEndpointType = .chatCompletions
    @State private var tempThinkingBudget: AnthropicThinkingBudget = .off
    @State private var isValidating = false
    @State private var validationStatus: ValidationStatus = .notChecked

    enum ValidationStatus {
        case notChecked
        case checking
        case valid
        case invalid(String)
    }

    var body: some View {
        HSplitView {
            modelsSidebar
            modelConfigurationDetail
        }
        .onAppear {
            if let model = selectedModelName, aiService.customModels.contains(model) {
                loadModelConfig(model)
            } else {
                tempAPIKey = ""
                tempEndpoint = "https://api.openai.com/"
                if aiService.provider == .anthropic {
                    createNewModel()
                }
            }
        }
        .onChange(of: aiService.provider) { _, newProvider in
            if newProvider == .anthropic {
                createNewModel()
            }
        }
    }

    private var modelsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                    Button(action: createNewModel) {
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

            Divider()

            ScrollView {
                if aiService.customModels.isEmpty {
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
                } else {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        ForEach(aiService.customModels, id: \.self) { model in
                            modelListRow(model)
                        }
                    }
                    .padding(Spacing.sm)
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)
        .background(Theme.backgroundSecondary)
    }

    private func modelListRow(_ model: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(model)
                    .font(Typography.modelName)
                if let provider = aiService.modelProviders[model] {
                    Text(provider.displayName)
                        .font(.system(size: Typography.Size.xs))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            HStack(spacing: Spacing.sm) {
                Button(action: {
                    aiService.selectedModel = model
                }) {
                    Image(systemName: model == aiService.selectedModel ? "star.fill" : "star")
                        .foregroundStyle(model == aiService.selectedModel ? .yellow : Theme.textSecondary)
                        .font(.system(size: Typography.Size.caption))
                }
                .buttonStyle(.plain)
                .help(model == aiService.selectedModel ? "Default model" : "Set as default")

                Button(action: {
                    removeModel(model)
                }) {
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
            selectedModelName == model ? Color.blue.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedModelName = model
            loadModelConfig(model)
        }
        .contextMenu {
            Button {
                aiService.selectedModel = model
            } label: {
                Label("Set as Default", systemImage: "star")
            }

            Button {
                duplicateModel(model)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                removeModel(model)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var modelConfigurationDetail: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Model Configuration")
                        .font(Typography.title2)
                        .fontWeight(.semibold)
                    Text("Configure AI provider settings and add models")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("AI Provider")
                        .font(Typography.headline)
                        .foregroundStyle(.primary)

                    Picker("", selection: $aiService.provider) {
                        ForEach(AIProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: aiService.provider) { _, _ in
                        validationStatus = .notChecked
                    }
                }
            }
            .padding(Spacing.xl)
            .background(Theme.background)

            Divider()
                .padding(.bottom, Spacing.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.contentPadding) {
                    if aiService.provider != .appleIntelligence, aiService.provider != .anthropic {
                        endpointTypePicker
                    }

                    if aiService.provider == .openai {
                        openAIConfigurationSection
                    } else if aiService.provider == .appleIntelligence {
                        appleIntelligenceConfigurationSection
                    } else if aiService.provider == .anthropic {
                        AnthropicConfigurationView(
                            tempModelName: $tempModelName,
                            tempAPIKey: $tempAPIKey,
                            tempEndpoint: $tempEndpoint,
                            tempThinkingBudget: $tempThinkingBudget,
                            showAPIKey: $showAPIKey,
                            selectedModelName: $selectedModelName,
                            validationStatus: $validationStatus
                        )
                        .padding(.horizontal)
                    }

                    if aiService.provider != .appleIntelligence, aiService.provider != .anthropic {
                        ValidationStatusCard(validationStatus: validationStatus)
                            .padding(.horizontal)
                            .padding(.bottom)
                    }
                }
            }
        }
    }

    private var endpointTypePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("API Endpoint")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            Picker("", selection: $tempEndpointType) {
                ForEach(APIEndpointType.allCases, id: \.self) { endpointType in
                    Text(endpointType.displayName).tag(endpointType)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: tempEndpointType) { _, newValue in
                if let modelName = selectedModelName {
                    aiService.modelEndpointTypes[modelName] = newValue
                }
            }
            .id(selectedModelName)

            Text("Choose which API endpoint to use for this model")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal)
    }

    private var openAIConfigurationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("OpenAI Configuration")
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
                    TextField("gpt-4o, gpt-4o-mini, o1", text: $tempModelName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempModelName) { _, _ in
                            validationStatus = .notChecked
                        }
                    Text("The model identifier from OpenAI")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Endpoint URL")
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
                    TextField(
                        "https://api.openai.com or http://localhost:8000", text: $tempEndpoint
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tempEndpoint) { _, _ in
                        validationStatus = .notChecked
                    }
                    Text(
                        "OpenAI-compatible API endpoint (e.g., https://api.openai.com, http://localhost:8000). For Azure, enter https://<resource>.openai.azure.com and set Model Name to your deployment name."
                    )
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("API Key")
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
                    HStack(spacing: Spacing.sm) {
                        if showAPIKey {
                            TextField("sk-proj-...", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-proj-...", text: $tempAPIKey)
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
                    Text("Your OpenAI API key (stored securely)")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Spacing.lg)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))

            openAIActionButtons
        }
        .padding(.horizontal)
    }

    private var openAIActionButtons: some View {
        HStack(spacing: Spacing.md) {
            Button {
                Task {
                    await validateConfiguration()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("Validate")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(
                tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || tempEndpoint.isEmpty
            )
            .controlSize(.large)

            if let selectedName = selectedModelName,
               aiService.customModels.contains(selectedName)
            {
                Button {
                    updateOpenAIModel(selectedName: selectedName)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text("Update Model")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(
                    tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || tempEndpoint.isEmpty
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    addOpenAIModel()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Model")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(
                    tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || tempEndpoint.isEmpty
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var appleIntelligenceConfigurationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Apple Intelligence Configuration")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                if #available(macOS 26.0, *) {
                    let service = AppleIntelligenceService.shared

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
                } else {
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
            }
            .padding(Spacing.lg)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))

            if #available(macOS 26.0, *) {
                HStack(spacing: Spacing.md) {
                    Button {
                        addAppleIntelligenceModel()
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
        .padding(.horizontal)
    }

    private func updateOpenAIModel(selectedName: String) {
        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !modelName.isEmpty else { return }

        if selectedName != modelName {
            aiService.customModels.removeAll { $0 == selectedName }
            aiService.modelProviders.removeValue(forKey: selectedName)
            aiService.modelAPIKeys.removeValue(forKey: selectedName)
            aiService.modelEndpoints.removeValue(forKey: selectedName)
            aiService.modelEndpointTypes.removeValue(forKey: selectedName)
            aiService.modelThinkingBudgets.removeValue(forKey: selectedName)

            if !aiService.customModels.contains(modelName) {
                aiService.customModels.append(modelName)
            }

            if aiService.selectedModel == selectedName {
                aiService.selectedModel = modelName
            }
        }

        aiService.modelProviders[modelName] = .openai
        aiService.modelEndpointTypes[modelName] = tempEndpointType
        aiService.modelThinkingBudgets.removeValue(forKey: modelName)

        if !apiKey.isEmpty {
            aiService.modelAPIKeys[modelName] = apiKey
        } else {
            aiService.modelAPIKeys.removeValue(forKey: modelName)
        }

        if !endpoint.isEmpty {
            aiService.modelEndpoints[modelName] = endpoint
        } else {
            aiService.modelEndpoints.removeValue(forKey: modelName)
        }

        selectedModelName = modelName
        validationStatus = .notChecked
    }

    private func addOpenAIModel() {
        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !modelName.isEmpty, !aiService.customModels.contains(modelName) else { return }

        aiService.customModels.append(modelName)
        aiService.modelProviders[modelName] = .openai
        aiService.modelEndpointTypes[modelName] = tempEndpointType
        aiService.modelThinkingBudgets.removeValue(forKey: modelName)

        if !apiKey.isEmpty {
            aiService.modelAPIKeys[modelName] = apiKey
        }

        if !endpoint.isEmpty {
            aiService.modelEndpoints[modelName] = endpoint
        }

        if aiService.customModels.count == 1 {
            aiService.selectedModel = modelName
        }
        selectedModelName = modelName
        validationStatus = .notChecked
    }

    private func addAppleIntelligenceModel() {
        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalModelName = modelName.isEmpty ? "apple-intelligence" : modelName

        guard !aiService.customModels.contains(finalModelName) else { return }

        aiService.customModels.append(finalModelName)
        aiService.modelProviders[finalModelName] = .appleIntelligence
        if aiService.customModels.count == 1 {
            aiService.selectedModel = finalModelName
        }
        selectedModelName = finalModelName
        tempModelName = ""
    }

    private func createNewModel() {
        selectedModelName = nil
        tempModelName = ""
        tempAPIKey = ""
        tempEndpoint = aiService.provider == .anthropic ? "" : "https://api.openai.com/"
        tempEndpointType = .chatCompletions
        tempThinkingBudget = .off
        validationStatus = .notChecked
    }

    private func validateConfiguration() async {
        validationStatus = .checking

        guard aiService.provider == .openai else {
            validationStatus = .invalid("Validation is only available for OpenAI-compatible models")
            return
        }

        do {
            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelName.isEmpty else {
                validationStatus = .invalid("Model name is required")
                return
            }

            let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty else {
                validationStatus = .invalid("Endpoint is required")
                return
            }

            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAzureEndpoint = endpoint.lowercased().contains("openai.azure.com")

            if isAzureEndpoint {
                try await validateAzureEndpoint(endpoint, apiKey: apiKey)
            } else {
                try await validateOpenAIEndpoint(endpoint, apiKey: apiKey)
            }
        } catch {
            validationStatus = .invalid(error.localizedDescription)
        }
    }

    private func validateAzureEndpoint(_ endpoint: String, apiKey: String) async throws {
        guard !apiKey.isEmpty else {
            validationStatus = .invalid("API key is required for Azure endpoints")
            return
        }

        let baseEndpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let modelsURL = "\(baseEndpoint)/openai/models?api-version=\(aiService.latestAzureAPIVersion)"

        guard let url = URL(string: modelsURL) else {
            validationStatus = .invalid("Invalid endpoint URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "api-key")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            validationStatus = .invalid("Invalid response from server")
            return
        }

        switch httpResponse.statusCode {
        case 200:
            validationStatus = .valid
        case 401, 403:
            validationStatus = .invalid("Invalid API key or permissions")
        case 404:
            validationStatus = .invalid("Invalid Azure OpenAI endpoint")
        default:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                validationStatus = .invalid(message)
            } else {
                validationStatus = .invalid("HTTP \(httpResponse.statusCode)")
            }
        }
    }

    private func validateOpenAIEndpoint(_ endpoint: String, apiKey: String) async throws {
        let baseEndpoint =
            endpoint.contains("api.openai.com")
                ? "https://api.openai.com"
                : endpoint.replacingOccurrences(of: "/v1/chat/completions", with: "")
        let modelsURL = "\(baseEndpoint)/v1/models"

        guard let url = URL(string: modelsURL) else {
            validationStatus = .invalid("Invalid endpoint URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            validationStatus = .invalid("Invalid response from server")
            return
        }

        if httpResponse.statusCode == 200 {
            validationStatus = .valid
        } else if httpResponse.statusCode == 401 {
            validationStatus = .invalid("Invalid API key")
        } else {
            validationStatus = .invalid("HTTP \(httpResponse.statusCode)")
        }
    }

    private func loadModelConfig(_ model: String) {
        if let modelProvider = aiService.modelProviders[model] {
            aiService.provider = modelProvider
        }

        tempModelName = model
        tempAPIKey = aiService.modelAPIKeys[model] ?? ""
        tempEndpointType = aiService.modelEndpointTypes[model] ?? .chatCompletions
        tempThinkingBudget = AnthropicThinkingBudget.preset(for: aiService.thinkingBudget(for: model))

        switch aiService.provider {
        case .openai:
            tempEndpoint = aiService.modelEndpoints[model] ?? "https://api.openai.com"
        case .anthropic:
            tempEndpoint = aiService.modelEndpoints[model] ?? ""
        default:
            tempEndpoint = aiService.modelEndpoints[model] ?? ""
        }
    }

    private func removeModel(_ model: String) {
        aiService.customModels.removeAll { $0 == model }
        aiService.modelProviders.removeValue(forKey: model)
        aiService.modelEndpoints.removeValue(forKey: model)
        aiService.modelAPIKeys.removeValue(forKey: model)
        aiService.modelEndpointTypes.removeValue(forKey: model)
        aiService.modelThinkingBudgets.removeValue(forKey: model)

        if aiService.selectedModel == model {
            if let nextModel = aiService.customModels.first {
                aiService.selectedModel = nextModel
            } else {
                aiService.selectedModel = ""
            }
        }

        if selectedModelName == model {
            selectedModelName = nil
            tempModelName = ""
            tempEndpoint = "https://api.openai.com/"
            tempThinkingBudget = .off
        }
    }

    private func duplicateModel(_ model: String) {
        var newName = "\(model) Copy"
        var copyNumber = 2
        while aiService.customModels.contains(newName) {
            newName = "\(model) Copy \(copyNumber)"
            copyNumber += 1
        }

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📋 Duplicating model",
            metadata: ["original": model, "duplicate": newName]
        )

        aiService.customModels.append(newName)

        if let provider = aiService.modelProviders[model] {
            aiService.modelProviders[newName] = provider
        }
        if let endpoint = aiService.modelEndpoints[model] {
            aiService.modelEndpoints[newName] = endpoint
        }
        if let apiKey = aiService.modelAPIKeys[model] {
            aiService.modelAPIKeys[newName] = apiKey
        }
        aiService.modelEndpointTypes[newName] = aiService.modelEndpointTypes[model] ?? .chatCompletions
        if let thinkingBudget = aiService.modelThinkingBudgets[model] {
            aiService.modelThinkingBudgets[newName] = thinkingBudget
        }

        selectedModelName = newName
        loadModelConfig(newName)
    }
}

struct ValidationStatusCard: View {
    let validationStatus: APISettingsView.ValidationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Validation Status")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            HStack(spacing: Spacing.md) {
                switch validationStatus {
                case .notChecked:
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text("Not Validated")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        Text("Click 'Validate' to test your configuration")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                case .checking:
                    ProgressView()
                        .scaleEffect(1.2)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text("Validating...")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        Text("Testing connection to API")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                case .valid:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.statusConnected)
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
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.statusError)
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
                Spacer()
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))
        }
    }
}

#endif
