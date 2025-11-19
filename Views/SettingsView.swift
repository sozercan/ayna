//
//  SettingsView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

// swiftlint:disable file_length type_body_length

struct SettingsView: View {
    @ObservedObject private var openAIService = OpenAIService.shared
    @ObservedObject private var settingsRouter = SettingsRouter.shared
    @State private var showAPIKeyInfo = false
    @State private var selectedTab: SettingsTab = SettingsRouter.shared.consumeRequestedTab() ?? .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            APISettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
                .tag(SettingsTab.models)

            MCPSettingsView()
                .tabItem {
                    Label("MCP Tools", systemImage: "wrench.and.screwdriver")
                }
                .tag(SettingsTab.mcp)

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 650, height: 500)
        .onReceive(settingsRouter.$requestedTab) { tab in
            guard let tab else { return }
            selectedTab = tab
            _ = settingsRouter.consumeRequestedTab()
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true
    @ObservedObject private var openAIService = OpenAIService.shared
    @EnvironmentObject private var conversationManager: ConversationManager

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Generate Titles", isOn: $autoGenerateTitle)
                    .help("Automatically generate conversation titles from first message")
            } header: {
                Text("Behavior")
            }

            Section {
                Picker("Image Size", selection: $openAIService.imageSize) {
                    Text("1024×1024 (Square)").tag("1024x1024")
                    Text("1024×1536 (Portrait)").tag("1024x1536")
                    Text("1536×1024 (Landscape)").tag("1536x1024")
                }
                .help("Resolution for generated images")

                Picker("Image Quality", selection: $openAIService.imageQuality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .help("Quality level affects generation time and cost")

                Picker("Output Format", selection: $openAIService.outputFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .help("Image file format")

                HStack {
                    Text("Compression")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(openAIService.outputCompression) },
                        set: { openAIService.outputCompression = Int($0) },
                    ), in: 0 ... 100, step: 10)
                        .frame(width: 150)
                    Text("\(openAIService.outputCompression)%")
                        .foregroundStyle(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
                .help("Image compression level (100 = no compression)")
            } header: {
        Text("Image Generation")
            } footer: {
        Text("These settings apply when using image generation models")
                    .font(.caption)
      }

      Section {
                Button("Clear All Conversations") {
                    conversationManager.clearAllConversations()
                }
                .foregroundStyle(.red)
            } header: {
                Text("Data")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct APISettingsView: View {
    @ObservedObject private var openAIService = OpenAIService.shared
    @State private var showAPIKey = false
    @State private var tempAPIKey = ""
    @State private var tempEndpoint = ""
    @State private var tempAzureEndpoint = ""
    @State private var tempAzureDeployment = ""
    @State private var tempModelName = ""
    @State private var selectedModelName: String?
    @State private var tempEndpointType: APIEndpointType = .chatCompletions
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
            // Left panel - Model Management
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Models")
                                .font(.headline)
                            Text("Add and manage your AI models")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(action: createNewModel) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Add new model")
                    }
                }
                .padding()

                Divider()

                // Model list
                ScrollView {
                    if openAIService.customModels.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "cpu")
                                .font(.system(size: 32))
                                .foregroundStyle(.tertiary)
                            Text("No models added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(openAIService.customModels, id: \.self) { model in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model)
                                            .font(.system(size: 13))
                                        if let provider = openAIService.modelProviders[model] {
                                            Text(provider.displayName)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    HStack(spacing: 8) {
                                        Button(action: {
                                            openAIService.selectedModel = model
                                        }) {
                                            Image(systemName: model == openAIService.selectedModel ? "star.fill" : "star")
                                                .foregroundStyle(model == openAIService.selectedModel ? .yellow : .secondary)
                                                .font(.system(size: 12))
                                        }
                                        .buttonStyle(.plain)
                                        .help(model == openAIService.selectedModel ? "Default model" : "Set as default")

                                        Button(action: {
                                            removeModel(model)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundStyle(.red)
                                                .font(.system(size: 12))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove model")
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    selectedModelName == model ? Color.blue.opacity(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6),
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedModelName = model
                                    loadModelConfig(model)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)
            .background(Color(nsColor: .controlBackgroundColor))

            // Right panel - API Configuration
            VStack(spacing: 0) {
                // Provider Selection - Fixed at top
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model Configuration")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Configure AI provider settings and add models")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Provider Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Label("AI Provider", systemImage: "cloud.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Picker("", selection: $openAIService.provider) {
                            ForEach(AIProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName)
                                    .tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: openAIService.provider) { _, _ in
                            validationStatus = .notChecked
                        }
                    }
                }
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()
                    .padding(.bottom, 16)

                // Scrollable configuration area
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // API Endpoint Type Selection (not applicable for Apple Intelligence or AIKit)
                        if openAIService.provider != .appleIntelligence, openAIService.provider != .aikit {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("API Endpoint", systemImage: "arrow.left.arrow.right")
                                    .font(.headline)
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
                                    },
                                )) {
                                    ForEach(APIEndpointType.allCases, id: \.self) { endpointType in
                                        Text(endpointType.displayName).tag(endpointType)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Text("Choose which API endpoint to use for this model")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }

                        if openAIService.provider == .openai {
                            // OpenAI Configuration
                            VStack(alignment: .leading, spacing: 16) {
                                Label("OpenAI Configuration", systemImage: "key.fill")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                VStack(alignment: .leading, spacing: 16) {
                                    // Model Name
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Model Name")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Spacer()
                                            Text("Required")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                        TextField("gpt-4o, gpt-4o-mini, o1", text: $tempModelName)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: tempModelName) { _, _ in
                                                validationStatus = .notChecked
                                            }
                                        Text("The model identifier from OpenAI")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }

                                    // Endpoint URL
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Endpoint URL")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Spacer()
                                            Text("Required")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                        TextField(
                                            "https://api.openai.com or http://localhost:8000", text: $tempEndpoint,
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: tempEndpoint) { _, _ in
                                            validationStatus = .notChecked
                                        }
                                        Text(
                                            "OpenAI-compatible API endpoint (e.g., https://api.openai.com, http://localhost:8000)")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }

                                    // API Key
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("API Key")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Spacer()
                                            Text("Optional")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                        HStack(spacing: 8) {
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
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 32, height: 32)
                                                    .background(Color.secondary.opacity(0.1))
                                                    .cornerRadius(6)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .onChange(of: tempAPIKey) { _, _ in
                                            validationStatus = .notChecked
                                        }
                                        Text("Your OpenAI API key (stored securely)")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(16)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(8)

                                // Action Buttons
                                HStack(spacing: 12) {
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
                                            || tempEndpoint.isEmpty)
                                    .controlSize(.large)

                                    if let selectedName = selectedModelName,
                                       openAIService.customModels.contains(selectedName)
                                    {
                                        // Update existing model
                                        Button {
                                            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

                                            if !modelName.isEmpty {
                                                // Update provider and endpoint type
                                                openAIService.modelProviders[modelName] = .openai
                                                openAIService.modelEndpointTypes[modelName] = tempEndpointType

                                                // Update per-model API key
                                                if !apiKey.isEmpty {
                                                    openAIService.modelAPIKeys[modelName] = apiKey
                                                } else {
                                                    openAIService.modelAPIKeys.removeValue(forKey: modelName)
                                                }

                                                // Update custom endpoint
                                                if !endpoint.isEmpty {
                                                    openAIService.modelEndpoints[modelName] = endpoint
                                                } else {
                                                    openAIService.modelEndpoints.removeValue(forKey: modelName)
                                                }

                                                validationStatus = .notChecked
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "arrow.clockwise.circle.fill")
                                                Text("Update Model")
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .disabled(
                                            tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                || tempEndpoint.isEmpty,
                                        )
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                    } else {
                                        // Add new model
                                        Button {
                                            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

                                            if !modelName.isEmpty, !openAIService.customModels.contains(modelName) {
                                                openAIService.customModels.append(modelName)
                                                openAIService.modelProviders[modelName] = .openai
                                                openAIService.modelEndpointTypes[modelName] = tempEndpointType

                                                // Save per-model API key if provided
                                                if !apiKey.isEmpty {
                                                    openAIService.modelAPIKeys[modelName] = apiKey
                                                }

                                                // Save custom endpoint if provided
                                                if !endpoint.isEmpty {
                                                    openAIService.modelEndpoints[modelName] = endpoint
                                                }

                                                if openAIService.customModels.count == 1 {
                                                    openAIService.selectedModel = modelName
                                                }
                                                selectedModelName = modelName
                                                validationStatus = .notChecked
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "plus.circle.fill")
                                                Text("Add Model")
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .disabled(
                                            tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                || tempEndpoint.isEmpty,
                                        )
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        } else if openAIService.provider == .azure {
                            // Azure OpenAI Configuration
                            VStack(alignment: .leading, spacing: 16) {
                                Label("Azure OpenAI Configuration", systemImage: "cloud.fill")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                VStack(alignment: .leading, spacing: 16) {
                                    // API Key
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("API Key")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Spacer()
                                            Text("Required")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                        HStack(spacing: 8) {
                                            if showAPIKey {
                                                TextField("Enter your Azure API key", text: $tempAPIKey)
                                                    .textFieldStyle(.roundedBorder)
                                            } else {
                                                SecureField("Enter your Azure API key", text: $tempAPIKey)
                                                    .textFieldStyle(.roundedBorder)
                                            }

                                            Button(action: {
                                                showAPIKey.toggle()
                                            }) {
                                                Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 32, height: 32)
                                                    .background(Color.secondary.opacity(0.1))
                                                    .cornerRadius(6)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .onChange(of: tempAPIKey) { _, _ in
                                            validationStatus = .notChecked
                                        }
                                        Text("Your Azure OpenAI API key")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }

                                    // Endpoint
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Endpoint")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Spacer()
                                            Text("Required")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                        TextField("https://your-resource.openai.azure.com", text: $tempAzureEndpoint)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: tempAzureEndpoint) { _, _ in
                                                validationStatus = .notChecked
                                            }
                                        Text("Your Azure OpenAI resource endpoint")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }

                                    // Deployment Name
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Deployment Name")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Spacer()
                                            Text("Required")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                        TextField("gpt-4, gpt-35-turbo", text: $tempAzureDeployment)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: tempAzureDeployment) { _, _ in
                                                validationStatus = .notChecked
                                            }
                                        Text("The deployment name in your Azure resource")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }

                                    // API Version
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("API Version")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Picker("", selection: $openAIService.azureAPIVersion) {
                                            ForEach(openAIService.azureAPIVersions, id: \.self) { version in
                                                Text(version).tag(version)
                                            }
                                        }
                                        .labelsHidden()
                                        .onChange(of: openAIService.azureAPIVersion) { _, _ in
                                            validationStatus = .notChecked
                                        }
                                        Text("Azure OpenAI API version")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(16)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(8)

                                // Action Buttons
                                HStack(spacing: 12) {
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
                                    .disabled(tempAzureEndpoint.isEmpty || tempAzureDeployment.isEmpty)
                                    .controlSize(.large)

                                    if let selectedName = selectedModelName,
                                       openAIService.customModels.contains(selectedName)
                                    {
                                        // Update existing model
                                        Button {
                                            openAIService.azureEndpoint = tempAzureEndpoint
                                            openAIService.azureDeploymentName = tempAzureDeployment

                                            let modelName = tempAzureDeployment.trimmingCharacters(
                                                in: .whitespacesAndNewlines)
                                            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

                                            if !modelName.isEmpty {
                                                openAIService.modelProviders[modelName] = .azure
                                                openAIService.modelEndpointTypes[modelName] = tempEndpointType

                                                // Update per-model API key
                                                if !apiKey.isEmpty {
                                                    openAIService.modelAPIKeys[modelName] = apiKey
                                                } else {
                                                    openAIService.modelAPIKeys.removeValue(forKey: modelName)
                                                }

                                                validationStatus = .notChecked
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "arrow.clockwise.circle.fill")
                                                Text("Update Model")
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .disabled(tempAzureEndpoint.isEmpty || tempAzureDeployment.isEmpty)
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                    } else {
                                        // Add new model
                                        Button {
                                            openAIService.azureEndpoint = tempAzureEndpoint
                                            openAIService.azureDeploymentName = tempAzureDeployment

                                            let modelName = tempAzureDeployment.trimmingCharacters(
                                                in: .whitespacesAndNewlines)
                                            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

                                            if !modelName.isEmpty, !openAIService.customModels.contains(modelName) {
                                                openAIService.customModels.append(modelName)
                                                openAIService.modelProviders[modelName] = .azure
                                                openAIService.modelEndpointTypes[modelName] = tempEndpointType

                                                // Save per-model API key if provided
                                                if !apiKey.isEmpty {
                                                    openAIService.modelAPIKeys[modelName] = apiKey
                                                }

                                                if openAIService.customModels.count == 1 {
                                                    openAIService.selectedModel = modelName
                                                }
                                                selectedModelName = modelName
                                                validationStatus = .notChecked
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "plus.circle.fill")
                                                Text("Add Model")
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .disabled(tempAzureEndpoint.isEmpty || tempAzureDeployment.isEmpty)
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        } else if openAIService.provider == .appleIntelligence {
                            // Apple Intelligence Configuration
                            VStack(alignment: .leading, spacing: 16) {
                                Label("Apple Intelligence Configuration", systemImage: "apple.logo")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                VStack(alignment: .leading, spacing: 16) {
                                    if #available(macOS 26.0, *) {
                                        let service = AppleIntelligenceService.shared

                                        // Availability Status
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Availability")
                                                .font(.subheadline)
                                                .fontWeight(.medium)

                                            HStack(spacing: 8) {
                                                Image(systemName: service.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                                    .foregroundStyle(service.isAvailable ? .green : .orange)
                                                Text(service.availabilityDescription())
                                                    .font(.subheadline)
                                            }
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(6)

                                            if !service.isAvailable {
                                                Text("Apple Intelligence must be enabled in System Settings → Apple Intelligence & Siri")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        // Model Name
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text("Model Name")
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                Spacer()
                                                Text("Optional")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.secondary.opacity(0.1))
                                                    .cornerRadius(4)
                                            }
                                            TextField("apple-intelligence", text: $tempModelName)
                                                .textFieldStyle(.roundedBorder)
                                            Text("A friendly name for this model (e.g., 'apple-intelligence', 'on-device')")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    } else {
                                        // macOS 26+ required message
                                        VStack(spacing: 12) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 48))
                                                .foregroundStyle(.orange)

                                            Text("macOS 26.0 or later required")
                                                .font(.headline)

                                            Text("Apple Intelligence requires macOS Sequoia 26.0 or later with Apple Intelligence support.")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(24)
                                        .background(Color.orange.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                }
                                .padding(16)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(8)

                                // Action Buttons
                                if #available(macOS 26.0, *) {
                                    HStack(spacing: 12) {
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
                            .padding(.horizontal)
                        } else if openAIService.provider == .aikit {
                            // AIKit Configuration
                            AIKitConfigurationView(
                                tempModelName: $tempModelName,
                                selectedModelName: $selectedModelName,
                            )
                            .padding(.horizontal)
                        }

                        // Status Section
                        if openAIService.provider != .appleIntelligence, openAIService.provider != .aikit {
                            VStack(alignment: .leading, spacing: 16) {
                                Label("Validation Status", systemImage: "checkmark.seal.fill")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 12) {
                                    switch validationStatus {
                                    case .notChecked:
                                        Image(systemName: "circle.dotted")
                                            .font(.system(size: 24))
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Not Validated")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text("Click 'Validate' to test your configuration")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    case .checking:
                                        ProgressView()
                                            .scaleEffect(1.2)
                                            .frame(width: 24, height: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Validating...")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text("Testing connection to API")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    case .valid:
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundStyle(.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Configuration Valid")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .foregroundStyle(.green)
                                            Text("Ready to add model")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    case let .invalid(message):
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundStyle(.red)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Configuration Invalid")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .foregroundStyle(.red)
                                            Text(message)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(8)
                            }
                            .padding(.horizontal)
                            .padding(.bottom)
                        }
                    }
                }
            } // End of outer VStack wrapping provider selection and scroll view
        }
        .onAppear {
            tempAPIKey = openAIService.apiKey
            tempEndpoint = "https://api.openai.com/"
            tempAzureEndpoint = openAIService.azureEndpoint
            tempAzureDeployment = openAIService.azureDeploymentName
        }
    }

    private func createNewModel() {
        // Clear all fields and deselect - complete clean slate
        selectedModelName = nil
        tempModelName = ""
        tempAPIKey = ""
        tempEndpoint = "https://api.openai.com/"
        tempAzureEndpoint = ""
        tempAzureDeployment = ""
        tempEndpointType = .chatCompletions
        validationStatus = .notChecked
    }

    private func validateConfiguration() async {
        validationStatus = .checking

        do {
            if openAIService.provider == .openai {
                // Validate OpenAI configuration
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

                // Use custom endpoint for validation if provided
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

                // Only add auth header if API key is provided
                if !tempAPIKey.isEmpty {
                    request.setValue("Bearer \(tempAPIKey)", forHTTPHeaderField: "Authorization")
                }

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    validationStatus = .invalid("Invalid response from server")
                    return
                }

                if httpResponse.statusCode == 200 {
                    // Parse response to check if model exists
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["data"] as? [[String: Any]]
                    {
                        let modelIds = models.compactMap { $0["id"] as? String }
                        if modelIds.contains(modelName) {
                            validationStatus = .valid
                        } else {
                            // Model not found in list, but API key is valid - allow it anyway for custom models
                            validationStatus = .valid
                        }
                    } else {
                        validationStatus = .valid // API key is valid even if we can't parse models
                    }
                } else if httpResponse.statusCode == 401 {
                    validationStatus = .invalid("Invalid API key")
                } else {
                    validationStatus = .invalid("HTTP \(httpResponse.statusCode)")
                }

            } else {
                // Validate Azure OpenAI configuration
                guard !tempAPIKey.isEmpty else {
                    validationStatus = .invalid("API key is required")
                    return
                }

                guard !tempAzureEndpoint.isEmpty else {
                    validationStatus = .invalid("Endpoint is required")
                    return
                }

                let deploymentName = tempAzureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !deploymentName.isEmpty else {
                    validationStatus = .invalid("Deployment name is required")
                    return
                }

                // Test Azure deployment by making a minimal chat completions request
                let endpoint = tempAzureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                let urlString = "\(endpoint)/openai/deployments/\(deploymentName)/chat/completions?api-version=\(openAIService.azureAPIVersion)"
                guard let url = URL(string: urlString) else {
                    validationStatus = .invalid("Invalid endpoint URL")
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(tempAPIKey, forHTTPHeaderField: "api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                // Minimal test request
                let testPayload: [String: Any] = [
                    "messages": [
                        ["role": "user", "content": "test"],
                    ],
                ]

                request.httpBody = try JSONSerialization.data(withJSONObject: testPayload)

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    validationStatus = .invalid("Invalid response from server")
                    return
                }

                if httpResponse.statusCode == 200 {
                    // Successfully reached the deployment
                    validationStatus = .valid
                } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    validationStatus = .invalid("Invalid API key or permissions")
                } else if httpResponse.statusCode == 404 {
                    // Parse error message to see if it's a deployment issue
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String
                    {
                        if message.contains("deployment") || message.contains("not found") {
                            validationStatus = .invalid("Deployment '\(deploymentName)' not found")
                        } else {
                            validationStatus = .invalid(message)
                        }
                    } else {
                        validationStatus = .invalid("Deployment not found")
                    }
                } else {
                    // Try to get error message from response
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
        } catch {
            validationStatus = .invalid(error.localizedDescription)
        }
    }

    private func loadModelConfig(_ model: String) {
        // Switch to the correct provider for this model
        if let modelProvider = openAIService.modelProviders[model] {
            openAIService.provider = modelProvider

            // Sync with AIKitService if this is an AIKit model
            if modelProvider == .aikit {
                AIKitService.shared.selectModelByName(model)
            }
        }

        tempModelName = model
        // Load per-model API key if available, otherwise use global
        tempAPIKey = openAIService.modelAPIKeys[model] ?? openAIService.apiKey
        tempEndpointType = openAIService.modelEndpointTypes[model] ?? .chatCompletions

        if openAIService.provider == .openai {
            // Load custom endpoint if available, otherwise use default
            tempEndpoint = openAIService.modelEndpoints[model] ?? "https://api.openai.com"
        } else {
            tempAzureDeployment = model
            tempAzureEndpoint = openAIService.azureEndpoint
        }
    }

    private func removeModel(_ model: String) {
        openAIService.customModels.removeAll { $0 == model }
        // Also remove from provider mapping and per-model settings
        openAIService.modelProviders.removeValue(forKey: model)
        openAIService.modelEndpoints.removeValue(forKey: model)
        openAIService.modelAPIKeys.removeValue(forKey: model)

        // If we removed the selected default model, pick the next available one or clear it
        if openAIService.selectedModel == model {
            if let nextModel = openAIService.customModels.first {
                openAIService.selectedModel = nextModel
            } else {
                openAIService.selectedModel = ""
            }
        }

        if selectedModelName == model {
            selectedModelName = nil
            tempModelName = ""
            tempEndpoint = "https://api.openai.com/"
            tempAzureDeployment = ""
        }
    }
}

// Flow layout for quick add buttons
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing,
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing,
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX, y: bounds.minY + result.frames[index].minY), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var frames: [CGRect] = []
        var size: CGSize = .zero

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if currentX + size.width > maxWidth, currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }

            size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("ayna")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("A native macOS ChatGPT client")
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 12) {
                Text("Features")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    FeatureRow(icon: "bubble.left.and.bubble.right", text: "Native chat interface")
                    FeatureRow(icon: "key", text: "Secure API key storage")
                    FeatureRow(icon: "text.badge.plus", text: "Prompt templates")
                    FeatureRow(icon: "folder", text: "Conversation management")
                    FeatureRow(icon: "cpu", text: "Multiple AI models")
                    FeatureRow(icon: "cloud", text: "OpenAI & Azure OpenAI")
                    FeatureRow(icon: "apple.logo", text: "Apple Intelligence (macOS 26+)")
                }
                .font(.caption)
            }

            Spacer()

            Text("Built with SwiftUI for macOS")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(text)
        }
    }
}

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AIKit Configuration View

struct AIKitConfigurationView: View {
    @ObservedObject private var aikitService = AIKitService.shared
    @ObservedObject private var openAIService = OpenAIService.shared
    @Binding var tempModelName: String
    @Binding var selectedModelName: String?

    @State private var isPulling = false
    @State private var isRunning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("AIKit Configuration", systemImage: "shippingbox.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 16) {
                // Info section
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("AIKit runs AI models locally using containers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Model Selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select Model")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker("", selection: $aikitService.selectedModelId) {
                        ForEach(aikitService.availableModels) { model in
                            Text("\(model.displayName) (\(model.size))").tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: aikitService.selectedModelId) { _, _ in
                        Task {
                            await aikitService.updateContainerStatus()
                        }
                    }

                    if let model = aikitService.selectedModel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Image: \(model.imageURL)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Container Status
                VStack(alignment: .leading, spacing: 6) {
                    Text("Container Status")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(aikitService.statusMessage.isEmpty ? aikitService.containerStatus.rawValue : aikitService.statusMessage)
                            .font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Container Management Buttons
                VStack(spacing: 8) {
                    if aikitService.containerStatus == .running {
                        Button(action: stopContainer) {
                            HStack {
                                if isRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isRunning ? "Stopping..." : "Stop Container")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isRunning)
                        .controlSize(.large)
                        .tint(.red)
                    } else {
                        Button(action: pullAndRunModel) {
                            HStack {
                                if isRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isRunning ? "Starting..." : "Pull & Run Model")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isRunning)
                        .controlSize(.large)
                    }

                    Text(aikitService.containerStatus == .running ? "Container is running on http://localhost:8080" : "This will pull the model image and run it on http://localhost:8080")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Add Model Button
            Button {
                if let model = aikitService.selectedModel {
                    let modelName = model.name
                    if !openAIService.customModels.contains(modelName) {
                        openAIService.customModels.append(modelName)
                        openAIService.modelProviders[modelName] = .aikit
                        if openAIService.customModels.count == 1 {
                            openAIService.selectedModel = modelName
                        }
                        selectedModelName = modelName
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Model to List")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .task {
            let service = AIKitService.shared
            await service.checkPodmanAvailability()
            await service.updateContainerStatus()
        }
    }

    private var statusColor: Color {
        switch aikitService.containerStatus {
        case .notPulled, .stopped:
            .gray
        case .pulling, .starting, .stopping:
            .orange
        case .pulled:
            .yellow
        case .running:
            .green
        case .error, .notSupported:
            .red
        }
    }

    private func pullAndRunModel() {
        isRunning = true
        errorMessage = nil

        Task {
            do {
                // Pull the model
                try await aikitService.pullModel()

                // Run the container
                try await aikitService.runContainer()

                await MainActor.run {
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stopContainer() {
        isRunning = true
        errorMessage = nil

        Task {
            do {
                // Stop the container
                try await aikitService.stopContainer()

                await MainActor.run {
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}

// swiftlint:enable file_length type_body_length
