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
                    Picker("Model", selection: $openAIService.selectedModel) {
                        ForEach(openAIService.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                } header: {
                    Text("OpenAI Model")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(openAIService.provider == .azure ? "Azure Deployment Info" : "Model Information")
                        .font(.headline)

                    if openAIService.provider == .azure {
                        Text("Your Azure deployment determines which model is used:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Check Azure Portal for your deployed model")
                            Text("• Each deployment can use different models")
                            Text("• Model capabilities depend on your deployment")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Different models have different capabilities and pricing:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("• GPT-4o: Most capable, vision support")
                            Text("• GPT-4o Mini: Fast and efficient")
                            Text("• o1-Preview: Advanced reasoning")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("About \(openAIService.provider == .azure ? "Deployments" : "Models")")
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
    @State private var tempAzureEndpoint = ""
    @State private var tempAzureDeployment = ""

    var body: some View {
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
                    HStack {
                        if showAPIKey {
                            TextField("sk-...", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-...", text: $tempAPIKey)
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
                        Button("Save API Key") {
                            openAIService.apiKey = tempAPIKey
                        }
                        .disabled(tempAPIKey.isEmpty)

                        Button("Clear") {
                            tempAPIKey = ""
                            openAIService.apiKey = ""
                        }
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("OpenAI API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your API key is stored securely in macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Link("Get your API key from OpenAI →",
                             destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.caption)
                    }
                }
            } else if openAIService.provider == .azure {
                Section {
                    HStack {
                        if showAPIKey {
                            TextField("Azure API Key", text: $tempAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Azure API Key", text: $tempAPIKey)
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
                        Button("Save Configuration") {
                            openAIService.apiKey = tempAPIKey
                            openAIService.azureEndpoint = tempAzureEndpoint
                            openAIService.azureDeploymentName = tempAzureDeployment
                        }
                        .disabled(tempAPIKey.isEmpty || tempAzureEndpoint.isEmpty || tempAzureDeployment.isEmpty)

                        Button("Clear") {
                            tempAPIKey = ""
                            tempAzureEndpoint = ""
                            tempAzureDeployment = ""
                            openAIService.apiKey = ""
                            openAIService.azureEndpoint = ""
                            openAIService.azureDeploymentName = ""
                        }
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("Azure OpenAI Configuration")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your API key is stored securely in macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Endpoint example: https://your-resource.openai.azure.com")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Link("Learn more about Azure OpenAI →",
                             destination: URL(string: "https://azure.microsoft.com/en-us/products/ai-services/openai-service")!)
                            .font(.caption)
                    }
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
            tempAzureEndpoint = openAIService.azureEndpoint
            tempAzureDeployment = openAIService.azureDeploymentName
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
