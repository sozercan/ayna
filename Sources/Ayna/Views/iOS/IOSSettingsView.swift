#if os(iOS)
//
//  IOSSettingsView.swift
//  ayna
//
//  Created on 11/22/25.
//

import os.log
import SwiftUI

struct IOSSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var aiService = AIService.shared
    @ObservedObject var tavilyService = TavilyService.shared
    @State private var webFetchService = WebFetchService.shared
    @EnvironmentObject var conversationManager: ConversationManager
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true
    @State private var multiModelSelectionEnabled = AppPreferences.multiModelSelectionEnabled

    @State private var showingAddSheet = false
    @State private var selectedModelForEditing: String?

    private var toolsSummary: String {
        var enabledCount = 0
        if tavilyService.isEnabled, tavilyService.isConfigured {
            enabledCount += 1
        }
        if webFetchService.isEnabled {
            enabledCount += 1
        }
        if enabledCount == 0 {
            return "None"
        } else if enabledCount == 1 {
            return "1 enabled"
        } else {
            return "\(enabledCount) enabled"
        }
    }

    private var memorySummary: String {
        let provider = MemoryContextProvider.shared
        if provider.isMemoryEnabled {
            let factCount = UserMemoryService.shared.activeFacts().count
            return factCount == 1 ? "1 fact" : "\(factCount) facts"
        } else {
            return "Disabled"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - General

                Section("General") {
                    Toggle("Auto-Generate Titles", isOn: $autoGenerateTitle)
                        .accessibilityIdentifier(TestIdentifiers.Settings.autoGenerateTitleToggle)

                    Toggle("Sound Effects", isOn: Binding(
                        get: { SoundEngine.shared.isEnabled },
                        set: { SoundEngine.shared.isEnabled = $0 }
                    ))
                    .accessibilityIdentifier("settings.soundEffects.toggle")

                    Toggle("Multi-Model Selection", isOn: $multiModelSelectionEnabled)
                        .accessibilityIdentifier("settings.multiModelSelection.toggle")
                        .onChange(of: multiModelSelectionEnabled) { _, newValue in
                            AppPreferences.multiModelSelectionEnabled = newValue
                        }

                    NavigationLink("System Prompt") {
                        IOSSystemPromptSettingsView()
                    }
                    .accessibilityIdentifier("settings.systemPrompt.link")

                    NavigationLink("Image Generation Settings") {
                        IOSImageGenerationSettingsView()
                    }
                    .accessibilityIdentifier("settings.imageGeneration.link")

                    Button("Clear All Conversations", role: .destructive) {
                        conversationManager.clearAllConversations()
                        DiagnosticsLogger.log(
                            .conversationManager,
                            level: .info,
                            message: "🗑️ Cleared all conversations"
                        )
                    }
                    .accessibilityIdentifier(TestIdentifiers.Settings.clearConversationsButton)
                }

                // MARK: - Tools

                Section("Tools") {
                    NavigationLink {
                        IOSToolsSettingsView()
                    } label: {
                        HStack {
                            Text("Tools")
                            Spacer()
                            Text(toolsSummary)
                                .font(Typography.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("settings.tools.link")
                }

                // MARK: - Memory

                Section("Memory") {
                    NavigationLink {
                        IOSMemorySettingsView()
                    } label: {
                        HStack {
                            Text("Memory")
                            Spacer()
                            Text(memorySummary)
                                .font(Typography.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("settings.memory.link")
                }

                // MARK: - Models

                Section("Models") {
                    ForEach(aiService.customModels, id: \.self) { model in
                        NavigationLink {
                            IOSModelEditView(modelName: model, isNew: false)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model)
                                        .font(Typography.headline)
                                    if let provider = aiService.modelProviders[model] {
                                        Text(provider.displayName)
                                            .font(Typography.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                if model == aiService.selectedModel {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                removeModel(model)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                DiagnosticsLogger.log(
                                    .aiService,
                                    level: .info,
                                    message: "✅ Model selected as default",
                                    metadata: ["model": model]
                                )
                                aiService.selectedModel = model
                            } label: {
                                Label("Select", systemImage: "checkmark")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                DiagnosticsLogger.log(
                                    .aiService,
                                    level: .info,
                                    message: "✅ Model set as default via context menu",
                                    metadata: ["model": model]
                                )
                                aiService.selectedModel = model
                            } label: {
                                Label("Set as Default", systemImage: "checkmark")
                            }

                            Button {
                                duplicateModel(model)
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }

                            Button(role: .destructive) {
                                removeModel(model)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier(TestIdentifiers.Settings.modelRow(for: model))
                    }

                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Model", systemImage: "plus")
                    }
                    .accessibilityIdentifier(TestIdentifiers.Settings.addModelButton)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier(TestIdentifiers.Settings.doneButton)
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                NavigationStack {
                    IOSModelEditView(modelName: "", isNew: true)
                }
            }
            .onAppear {
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "⚙️ IOSSettingsView appeared",
                    metadata: ["modelCount": "\(aiService.customModels.count)"]
                )
            }
        }
    }

    private func removeModel(_ model: String) {
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "🗑️ Removing model",
            metadata: ["model": model]
        )
        if let index = aiService.customModels.firstIndex(of: model) {
            aiService.customModels.remove(at: index)
            aiService.modelProviders.removeValue(forKey: model)
            aiService.modelEndpoints.removeValue(forKey: model)
            aiService.modelAPIKeys.removeValue(forKey: model)
            aiService.modelEndpointTypes.removeValue(forKey: model)

            // If we removed the selected model, select the first available one
            if aiService.selectedModel == model, let first = aiService.customModels.first {
                aiService.selectedModel = first
            }
        }
    }

    private func duplicateModel(_ model: String) {
        // Generate a unique name by appending "Copy" or "Copy N"
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

        // Add the new model
        aiService.customModels.append(newName)

        // Copy all settings from the original model
        if let provider = aiService.modelProviders[model] {
            aiService.modelProviders[newName] = provider
        }
        if let endpoint = aiService.modelEndpoints[model] {
            aiService.modelEndpoints[newName] = endpoint
        }
        if let apiKey = aiService.modelAPIKeys[model] {
            aiService.modelAPIKeys[newName] = apiKey
        }
        if let endpointType = aiService.modelEndpointTypes[model] {
            aiService.modelEndpointTypes[newName] = endpointType
        }
    }
}

struct IOSImageGenerationSettingsView: View {
    @ObservedObject var aiService = AIService.shared

    var body: some View {
        Form {
            Section {
                Picker("Image Size", selection: $aiService.imageSize) {
                    Text("1024×1024 (Square)").tag("1024x1024")
                    Text("1024×1536 (Portrait)").tag("1024x1536")
                    Text("1536×1024 (Landscape)").tag("1536x1024")
                }
                .accessibilityIdentifier("settings.imageGeneration.sizeSelector")

                Picker("Image Quality", selection: $aiService.imageQuality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .accessibilityIdentifier("settings.imageGeneration.qualitySelector")

                Picker("Output Format", selection: $aiService.outputFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .accessibilityIdentifier("settings.imageGeneration.formatSelector")

                VStack(alignment: .leading) {
                    Text("Compression: \(aiService.outputCompression)%")
                    Slider(value: Binding(
                        get: { Double(aiService.outputCompression) },
                        set: { aiService.outputCompression = Int($0) }
                    ), in: 0 ... 100, step: 10)
                        .accessibilityLabel("Compression")
                        .accessibilityIdentifier("settings.imageGeneration.compressionSlider")
                }
            } footer: {
                Text("These settings apply when using image generation models.")
            }
        }
        .navigationTitle("Image Generation")
    }
}

struct IOSSystemPromptSettingsView: View {
    @State private var globalSystemPrompt = AppPreferences.globalSystemPrompt

    var body: some View {
        Form {
            Section {
                TextEditor(text: $globalSystemPrompt)
                    .frame(minHeight: 150)
                    .accessibilityIdentifier("settings.globalSystemPrompt.editor")
                    .onChange(of: globalSystemPrompt) { _, newValue in
                        AppPreferences.globalSystemPrompt = newValue
                    }
            } header: {
                Text("Default System Prompt")
            } footer: {
                Text("This prompt is sent at the start of every conversation unless overridden per-conversation. Leave empty for no default prompt.")
            }
        }
        .navigationTitle("System Prompt")
    }
}

struct IOSModelEditView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var aiService = AIService.shared

    let isNew: Bool
    let originalModelName: String
    @State var modelName: String

    @State private var provider: AIProvider = .openai
    @State private var apiKey = ""
    @State private var endpoint = ""
    @State private var endpointType: APIEndpointType = .chatCompletions

    init(modelName: String, isNew: Bool) {
        _modelName = State(initialValue: modelName)
        originalModelName = modelName
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section("Model Details") {
                TextField("Model Name", text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Model Name")
                    .accessibilityIdentifier("settings.addModel.modelName")

                Picker("Provider", selection: $provider) {
                    Text("OpenAI").tag(AIProvider.openai)
                    Text("Anthropic").tag(AIProvider.anthropic)
                    Text("Apple Intelligence").tag(AIProvider.appleIntelligence)
                }
                .accessibilityIdentifier("settings.addModel.providerSelector")
            }

            if provider == .openai {
                Section("Configuration") {
                    SecureField("API Key", text: $apiKey)
                        .accessibilityLabel("API Key")
                        .accessibilityIdentifier("settings.addModel.apiKey")

                    TextField("Endpoint URL", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Endpoint URL")
                        .accessibilityIdentifier("settings.addModel.endpointUrl")

                    Picker("Endpoint Type", selection: $endpointType) {
                        ForEach(APIEndpointType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .accessibilityIdentifier("settings.addModel.endpointTypeSelector")
                }
            } else if provider == .anthropic {
                Section("Configuration") {
                    TextField("Model Name", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Model Name")
                        .accessibilityIdentifier("settings.addModel.anthropicModelName")

                    SecureField("API Key", text: $apiKey)
                        .accessibilityLabel("API Key")
                        .accessibilityIdentifier("settings.addModel.anthropicApiKey")

                    TextField("Endpoint URL (Optional)", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Endpoint URL")
                        .accessibilityIdentifier("settings.addModel.anthropicEndpoint")
                }

                Section {
                    Text("Enter your Anthropic model name (e.g., claude-sonnet-4-20250514) and API key. Leave endpoint empty for the default Anthropic API.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle(isNew ? "Add Model" : "Edit Model")
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.addModel.cancelButton")
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveModel()
                    dismiss()
                }
                .disabled(
                    modelName.isEmpty ||
                        (provider == .anthropic && apiKey.isEmpty)
                )
                .accessibilityIdentifier("settings.addModel.saveButton")
            }
        }
        .onAppear {
            if !isNew {
                loadModelData()
            }
        }
    }

    private func loadModelData() {
        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: "📂 Loading model data",
            metadata: ["model": modelName]
        )
        if let savedProvider = aiService.modelProviders[modelName] {
            provider = savedProvider
        }
        if let savedKey = aiService.modelAPIKeys[modelName] {
            apiKey = savedKey
        }
        if let savedEndpoint = aiService.modelEndpoints[modelName] {
            endpoint = savedEndpoint
        }
        if let savedType = aiService.modelEndpointTypes[modelName] {
            endpointType = savedType
        }
    }

    private func saveModel() {
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRename = !isNew && trimmedName != originalModelName

        DiagnosticsLogger.log(
            .aiService,
            level: .info,
            message: isNew ? "➕ Adding new model" : (isRename ? "✏️ Renaming model" : "💾 Saving model changes"),
            metadata: [
                "model": trimmedName,
                "originalModel": originalModelName,
                "provider": provider.displayName,
                "hasEndpoint": "\(!endpoint.isEmpty)",
            ]
        )

        if isNew {
            if aiService.customModels.contains(trimmedName) {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .default,
                    message: "⚠️ Duplicate model name, skipping",
                    metadata: ["model": trimmedName]
                )
                return
            }
            aiService.customModels.append(trimmedName)
        } else if isRename {
            // Check if new name already exists
            if aiService.customModels.contains(trimmedName) {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .default,
                    message: "⚠️ Model name already exists, skipping rename",
                    metadata: ["model": trimmedName]
                )
                return
            }

            // Update the model list: replace old name with new name
            if let index = aiService.customModels.firstIndex(of: originalModelName) {
                aiService.customModels[index] = trimmedName
            }

            // Remove old model settings
            aiService.modelProviders.removeValue(forKey: originalModelName)
            aiService.modelAPIKeys.removeValue(forKey: originalModelName)
            aiService.modelEndpoints.removeValue(forKey: originalModelName)
            aiService.modelEndpointTypes.removeValue(forKey: originalModelName)

            // Update selected model if it was the renamed one
            if aiService.selectedModel == originalModelName {
                aiService.selectedModel = trimmedName
            }
        }

        aiService.modelProviders[trimmedName] = provider

        if provider == .openai {
            if !apiKey.isEmpty {
                aiService.modelAPIKeys[trimmedName] = apiKey
            }
            if !endpoint.isEmpty {
                aiService.modelEndpoints[trimmedName] = endpoint
            }
            aiService.modelEndpointTypes[trimmedName] = endpointType
        } else if provider == .anthropic {
            if !apiKey.isEmpty {
                aiService.modelAPIKeys[trimmedName] = apiKey
            }
            if !endpoint.isEmpty {
                aiService.modelEndpoints[trimmedName] = endpoint
            }
        }

        // If this is the first model, select it
        if aiService.customModels.count == 1 {
            aiService.selectedModel = trimmedName
        }
    }
}

// MARK: - Tools Settings View

/// iOS view for managing tools (Web Search, Web Fetch)
struct IOSToolsSettingsView: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @State private var webFetchEnabled = WebFetchService.shared.isEnabled

    var body: some View {
        Form {
            // Built-in Tools
            Section {
                // Web Fetch Tool
                HStack {
                    Image(systemName: "link")
                        .font(Typography.title2)
                        .foregroundStyle(webFetchEnabled ? Theme.accent : Theme.textSecondary)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text("Web Fetch")
                            .font(Typography.headline)

                        if webFetchEnabled {
                            Text("Fetch content from URLs")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("Disabled")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $webFetchEnabled)
                        .labelsHidden()
                        .accessibilityLabel("Web Fetch")
                        .accessibilityIdentifier("settings.tools.webFetch.toggle")
                        .onChange(of: webFetchEnabled) { _, newValue in
                            WebFetchService.shared.isEnabled = newValue
                        }
                }

                // Web Search Tool
                HStack {
                    Image(systemName: "globe")
                        .font(Typography.title2)
                        .foregroundStyle(tavilyService.isEnabled ? Theme.accent : Theme.textSecondary)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text("Web Search")
                            .font(Typography.headline)

                        if tavilyService.isEnabled {
                            Text(tavilyService.isConfigured ? "Tavily" : "DuckDuckGo")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("Disabled")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $tavilyService.isEnabled)
                        .labelsHidden()
                        .accessibilityLabel("Web Search")
                        .accessibilityIdentifier("settings.tools.webSearch.toggle")
                }
            } header: {
                Text("Built-in Tools")
            } footer: {
                Text("Tools extend the capabilities of AI models by allowing them to access external data and services.")
            }

            // Web Search Configuration
            if tavilyService.isEnabled {
                Section {
                    HStack {
                        SecureField("Tavily API Key", text: $tavilyService.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Tavily API Key")
                            .accessibilityIdentifier("settings.tools.webSearch.apiKey")

                        if tavilyService.isConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.statusConnected)
                        }
                    }
                } header: {
                    Text("Web Search Configuration")
                } footer: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Web search works without an API key using DuckDuckGo. Add a Tavily key for higher quality results.")
                        Link("Get an API key at tavily.com", destination: URL(string: "https://tavily.com")!)
                    }
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// iOS settings section for Tavily Web Search configuration (legacy, kept for reference)
struct IOSWebSearchSettingsSection: View {
    @ObservedObject private var tavilyService = TavilyService.shared

    var body: some View {
        Section {
            Toggle("Enable Web Search", isOn: $tavilyService.isEnabled)
                .accessibilityIdentifier("settings.webSearch.enableToggle")

            if tavilyService.isEnabled {
                HStack {
                    SecureField("Tavily API Key", text: $tavilyService.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Tavily API Key")
                        .accessibilityIdentifier("settings.webSearch.apiKey")

                    if tavilyService.isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.statusConnected)
                    }
                }
            }
        } header: {
            Text("Web Search")
        } footer: {
            if tavilyService.isEnabled {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Using \(tavilyService.isConfigured ? "Tavily" : "DuckDuckGo"). Add a Tavily key for higher quality results.")
                    Link("Get an API key at tavily.com", destination: URL(string: "https://tavily.com")!)
                }
            } else {
                Text("When enabled, models can search the web for current information.")
            }
        }
    }
}
#endif
