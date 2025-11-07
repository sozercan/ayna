//
//  SettingsView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var openAIService = OpenAIService.shared
    @State private var showAPIKeyInfo = false

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            APISettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            MCPSettingsView()
                .tabItem {
                    Label("MCP Tools", systemImage: "wrench.and.screwdriver")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 650, height: 500)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true
    @StateObject private var openAIService = OpenAIService.shared

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
                        set: { openAIService.outputCompression = Int($0) }
                    ), in: 0...100, step: 10)
                    .frame(width: 150)
                    Text("\(openAIService.outputCompression)%")
                        .foregroundStyle(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
                .help("Image compression level (100 = no compression)")
            } header: {
                Text("Image Generation (gpt-image-1)")
            } footer: {
                Text("These settings apply when using image generation models like gpt-image-1")
                    .font(.caption)
            }

            Section {
                LabeledContent("Storage Location") {
                    Text("User Defaults")
                        .foregroundStyle(.secondary)
                }

                Button("Clear All Conversations") {
                    UserDefaults.standard.removeObject(forKey: "saved_conversations")
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
    @StateObject private var openAIService = OpenAIService.shared
    @State private var showAPIKey = false
    @State private var tempAPIKey = ""
    @State private var tempEndpoint = ""
    @State private var tempAzureEndpoint = ""
    @State private var tempAzureDeployment = ""
    @State private var tempModelName = ""
    @State private var selectedModelName: String?
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
                                    in: RoundedRectangle(cornerRadius: 6)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model Configuration")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Configure AI provider settings and add models")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    Divider()

                    // Provider Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Label("AI Provider", systemImage: "cloud.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Picker("", selection: $openAIService.provider) {
                            ForEach(AIProvider.allCases, id: \.self) { provider in
                                HStack {
                                    Text(provider.displayName)
                                }
                                .tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: openAIService.provider) { _, _ in
                            validationStatus = .notChecked
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // API Endpoint Type Selection (not applicable for Apple Intelligence)
                    if openAIService.provider != .appleIntelligence, let modelName = selectedModelName {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("API Endpoint", systemImage: "arrow.left.arrow.right")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Picker("", selection: Binding(
                                get: { openAIService.modelEndpointTypes[modelName] ?? .chatCompletions },
                                set: { openAIService.modelEndpointTypes[modelName] = $0 }
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
                                    TextField("https://api.openai.com", text: $tempEndpoint)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: tempEndpoint) { _, _ in
                                            validationStatus = .notChecked
                                        }
                                    Text("OpenAI API endpoint URL")
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
                                .disabled(tempAPIKey.isEmpty || tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .controlSize(.large)

                                Button {
                                    openAIService.apiKey = tempAPIKey

                                    let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !modelName.isEmpty && !openAIService.customModels.contains(modelName) {
                                        openAIService.customModels.append(modelName)
                                        openAIService.modelProviders[modelName] = .openai
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
                                .disabled(tempAPIKey.isEmpty || tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tempEndpoint.isEmpty)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
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
                                .disabled(tempAPIKey.isEmpty || tempAzureEndpoint.isEmpty || tempAzureDeployment.isEmpty)
                                .controlSize(.large)

                                Button {
                                    openAIService.apiKey = tempAPIKey
                                    openAIService.azureEndpoint = tempAzureEndpoint
                                    openAIService.azureDeploymentName = tempAzureDeployment

                                    let modelName = tempAzureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !modelName.isEmpty && !openAIService.customModels.contains(modelName) {
                                        openAIService.customModels.append(modelName)
                                        openAIService.modelProviders[modelName] = .azure
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
                                .disabled(tempAPIKey.isEmpty || tempAzureEndpoint.isEmpty || tempAzureDeployment.isEmpty)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
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
                    }

                    // Status Section
                    if openAIService.provider != .appleIntelligence {
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
                            case .invalid(let message):
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
        validationStatus = .notChecked
    }

    private func validateConfiguration() async {
        validationStatus = .checking

        do {
            if openAIService.provider == .openai {
                // Validate OpenAI configuration
                guard !tempAPIKey.isEmpty else {
                    validationStatus = .invalid("API key is required")
                    return
                }

                let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelName.isEmpty else {
                    validationStatus = .invalid("Model name is required")
                    return
                }

                // Call OpenAI models endpoint to verify API key and check if model exists
                let url = URL(string: "https://api.openai.com/v1/models")!
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("Bearer \(tempAPIKey)", forHTTPHeaderField: "Authorization")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    validationStatus = .invalid("Invalid response from server")
                    return
                }

                if httpResponse.statusCode == 200 {
                    // Parse response to check if model exists
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["data"] as? [[String: Any]] {
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
                        ["role": "user", "content": "test"]
                    ]
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
                       let message = error["message"] as? String {
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
                       let message = error["message"] as? String {
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
        }

        tempModelName = model
        tempAPIKey = openAIService.apiKey

        if openAIService.provider == .openai {
            tempEndpoint = "https://api.openai.com/"
        } else {
            tempAzureDeployment = model
            tempAzureEndpoint = openAIService.azureEndpoint
        }
    }

    private func removeModel(_ model: String) {
        openAIService.customModels.removeAll { $0 == model }
        // Also remove from provider mapping
        openAIService.modelProviders.removeValue(forKey: model)

        // If we removed the selected default model, pick a new one
        if openAIService.selectedModel == model && !openAIService.customModels.isEmpty {
            openAIService.selectedModel = openAIService.customModels[0]
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
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

                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
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

#Preview {
    SettingsView()
}
