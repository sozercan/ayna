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

            ModelSettingsView()
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }

            APISettingsView()
                .tabItem {
                    Label("API", systemImage: "key")
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
    @AppStorage("streamResponse") private var streamResponse = true
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true
    @AppStorage("showTokenCount") private var showTokenCount = false

    var body: some View {
        Form {
            Section {
                Toggle("Stream Responses", isOn: $streamResponse)
                    .help("Show responses as they are generated")

                Toggle("Auto-Generate Titles", isOn: $autoGenerateTitle)
                    .help("Automatically generate conversation titles from first message")

                Toggle("Show Token Count", isOn: $showTokenCount)
                    .help("Display token usage information")
            } header: {
                Text("Behavior")
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

struct ModelSettingsView: View {
    @StateObject private var openAIService = OpenAIService.shared

    var body: some View {
        Form {
            if openAIService.provider == .azure {
                // Azure OpenAI uses deployment names
                Section {
                    Text(openAIService.azureDeploymentName.isEmpty ? "Not configured" : openAIService.azureDeploymentName)
                        .foregroundStyle(openAIService.azureDeploymentName.isEmpty ? .red : .primary)

                    if openAIService.azureDeploymentName.isEmpty {
                        Text("Configure your Azure deployment in the API tab")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } header: {
                    Text("Deployment")
                } footer: {
                    Text("Azure OpenAI uses deployment names instead of model selection. Configure your deployment in the API tab.")
                        .font(.caption)
                }
            } else {
                // OpenAI model selection
                Section {
                    if openAIService.customModels.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No models configured")
                                .foregroundStyle(.red)
                            Text("Go to the API tab to add models")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Default Model", selection: $openAIService.selectedModel) {
                            ForEach(openAIService.customModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                } header: {
                    Text("Default Model for New Conversations")
                } footer: {
                    Text("This model will be used when creating new conversations. Manage models in the API tab.")
                        .font(.caption)
                }

                Section {
                    if openAIService.customModels.isEmpty {
                        Text("No models available. Add models in the API tab.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(openAIService.customModels, id: \.self) { model in
                            HStack {
                                Image(systemName: "cpu")
                                    .foregroundStyle(.blue)
                                    .font(.system(size: 14))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model)
                                        .font(.system(size: 13, weight: .medium))
                                    if let description = model.modelDescription {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model == openAIService.selectedModel {
                                    Text("Default")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Your Models")
                } footer: {
                    Text("Each conversation can use a different model. Change a conversation's model by right-clicking it in the sidebar.")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// Model information helper
extension String {
    var modelDescription: String? {
        switch self {
        case "gpt-5":
            return "Most advanced reasoning model"
        case "gpt-4o":
            return "Best for everyday tasks"
        case "gpt-4o-mini":
            return "Fast and efficient for simple tasks"
        case "o3":
            return "Deep reasoning capabilities"
        case "o4-mini":
            return "Quick reasoning for simple problems"
        case "o1":
            return "Advanced reasoning model"
        case "o1-mini":
            return "Faster reasoning for simpler tasks"
        case "o1-preview":
            return "Preview of reasoning capabilities"
        case "gpt-4-turbo":
            return "Fast, powerful multimodal model"
        case "gpt-4":
            return "Reliable general-purpose model"
        case "gpt-3.5-turbo":
            return "Fast responses at lower cost"
        default:
            return nil
        }
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
                                        HStack(spacing: 4) {
                                            if let provider = openAIService.modelProviders[model] {
                                                Text(provider == .openai ? "OpenAI" : "Azure")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                            if model == openAIService.selectedModel {
                                                Text("•")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                Text("Default")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                    }

                                    Spacer()

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
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 350)
            .background(Color(nsColor: .controlBackgroundColor))

            // Right panel - API Configuration
            Form {
            Section {
                Picker("Provider", selection: $openAIService.provider) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } header: {
                Text("AI Provider")
            }

            if openAIService.provider == .openai {
                Section {
                    TextField("Model Name (e.g., gpt-4o)", text: $tempModelName)
                        .textFieldStyle(.roundedBorder)

                    TextField("Endpoint URL", text: $tempEndpoint)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        if showAPIKey {
                            TextField("API Key", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(action: {
                            showAPIKey.toggle()
                        }) {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }

                    HStack {
                        Spacer()
                        Button("Add Model") {
                            openAIService.apiKey = tempAPIKey

                            // Add model to custom models list if provided
                            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !modelName.isEmpty && !openAIService.customModels.contains(modelName) {
                                openAIService.customModels.append(modelName)
                                // Store that this model uses OpenAI provider
                                openAIService.modelProviders[modelName] = .openai
                                // Set as default if no models exist
                                if openAIService.customModels.count == 1 {
                                    openAIService.selectedModel = modelName
                                }
                                // Select the newly added model in the left panel
                                selectedModelName = modelName
                            }
                        }
                        .disabled(tempAPIKey.isEmpty || tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tempEndpoint.isEmpty)
                        Spacer()
                    }
                } header: {
                    Text("OpenAI Configuration")
                }
            } else if openAIService.provider == .azure {
                Section {
                    HStack {
                        if showAPIKey {
                            TextField("API Key", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(action: {
                            showAPIKey.toggle()
                        }) {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("Endpoint", text: $tempAzureEndpoint)
                        .textFieldStyle(.roundedBorder)

                    TextField("Deployment Name", text: $tempAzureDeployment)
                        .textFieldStyle(.roundedBorder)

                    Picker("API Version", selection: $openAIService.azureAPIVersion) {
                        ForEach(openAIService.azureAPIVersions, id: \.self) { version in
                            Text(version).tag(version)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Add Model") {
                            openAIService.apiKey = tempAPIKey
                            openAIService.azureEndpoint = tempAzureEndpoint
                            openAIService.azureDeploymentName = tempAzureDeployment

                            // Use deployment name as model name
                            let modelName = tempAzureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !modelName.isEmpty && !openAIService.customModels.contains(modelName) {
                                openAIService.customModels.append(modelName)
                                // Store that this model uses Azure provider
                                openAIService.modelProviders[modelName] = .azure
                                // Set as default if no models exist
                                if openAIService.customModels.count == 1 {
                                    openAIService.selectedModel = modelName
                                }
                                // Select the newly added model in the left panel
                                selectedModelName = modelName
                            }
                        }
                        .disabled(tempAPIKey.isEmpty || tempAzureEndpoint.isEmpty || tempAzureDeployment.isEmpty)
                        Spacer()
                    }
                } header: {
                    Text("Azure OpenAI Configuration")
                }
            }

            Section {
                HStack {
                    Image(systemName: openAIService.apiKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(openAIService.apiKey.isEmpty ? .red : .green)

                    Text(openAIService.apiKey.isEmpty ? "No API key configured" : "API key configured")
                        .font(.caption)
                }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            tempAPIKey = openAIService.apiKey
            tempEndpoint = "https://api.openai.com/"
            tempAzureEndpoint = openAIService.azureEndpoint
            tempAzureDeployment = openAIService.azureDeploymentName
        }
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

#Preview {
    SettingsView()
}
