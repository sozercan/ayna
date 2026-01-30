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
    @ObservedObject var openAIService = OpenAIService.shared
    @ObservedObject var githubOAuth = GitHubOAuthService.shared
    @ObservedObject var tavilyService = TavilyService.shared
    @EnvironmentObject var conversationManager: ConversationManager
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true
    @State private var multiModelSelectionEnabled = AppPreferences.multiModelSelectionEnabled

    @State private var showingAddSheet = false
    @State private var selectedModelForEditing: String?

    private var toolsSummary: String {
        if tavilyService.isEnabled, tavilyService.isConfigured {
            "1 enabled"
        } else {
            "None"
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
                    ForEach(openAIService.customModels, id: \.self) { model in
                        NavigationLink {
                            IOSModelEditView(modelName: model, isNew: false)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model)
                                        .font(Typography.headline)
                                    if let provider = openAIService.modelProviders[model] {
                                        Text(provider.displayName)
                                            .font(Typography.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                if model == openAIService.selectedModel {
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
                                    .openAIService,
                                    level: .info,
                                    message: "✅ Model selected as default",
                                    metadata: ["model": model]
                                )
                                openAIService.selectedModel = model
                            } label: {
                                Label("Select", systemImage: "checkmark")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                DiagnosticsLogger.log(
                                    .openAIService,
                                    level: .info,
                                    message: "✅ Model set as default via context menu",
                                    metadata: ["model": model]
                                )
                                openAIService.selectedModel = model
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
                    metadata: ["modelCount": "\(openAIService.customModels.count)"]
                )
            }
        }
    }

    private func removeModel(_ model: String) {
        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "🗑️ Removing model",
            metadata: ["model": model]
        )
        if let index = openAIService.customModels.firstIndex(of: model) {
            openAIService.customModels.remove(at: index)
            openAIService.modelProviders.removeValue(forKey: model)
            openAIService.modelEndpoints.removeValue(forKey: model)
            openAIService.modelAPIKeys.removeValue(forKey: model)
            openAIService.modelEndpointTypes.removeValue(forKey: model)

            // If we removed the selected model, select the first available one
            if openAIService.selectedModel == model, let first = openAIService.customModels.first {
                openAIService.selectedModel = first
            }
        }
    }

    private func duplicateModel(_ model: String) {
        // Generate a unique name by appending "Copy" or "Copy N"
        var newName = "\(model) Copy"
        var copyNumber = 2
        while openAIService.customModels.contains(newName) {
            newName = "\(model) Copy \(copyNumber)"
            copyNumber += 1
        }

        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: "📋 Duplicating model",
            metadata: ["original": model, "duplicate": newName]
        )

        // Add the new model
        openAIService.customModels.append(newName)

        // Copy all settings from the original model
        if let provider = openAIService.modelProviders[model] {
            openAIService.modelProviders[newName] = provider
        }
        if let endpoint = openAIService.modelEndpoints[model] {
            openAIService.modelEndpoints[newName] = endpoint
        }
        if let apiKey = openAIService.modelAPIKeys[model] {
            openAIService.modelAPIKeys[newName] = apiKey
        }
        if let endpointType = openAIService.modelEndpointTypes[model] {
            openAIService.modelEndpointTypes[newName] = endpointType
        }
        if let usesOAuth = openAIService.modelUsesGitHubOAuth[model] {
            openAIService.modelUsesGitHubOAuth[newName] = usesOAuth
        }
    }
}

struct IOSImageGenerationSettingsView: View {
    @ObservedObject var openAIService = OpenAIService.shared

    var body: some View {
        Form {
            Section {
                Picker("Image Size", selection: $openAIService.imageSize) {
                    Text("1024×1024 (Square)").tag("1024x1024")
                    Text("1024×1536 (Portrait)").tag("1024x1536")
                    Text("1536×1024 (Landscape)").tag("1536x1024")
                }
                .accessibilityIdentifier("settings.imageGeneration.sizeSelector")

                Picker("Image Quality", selection: $openAIService.imageQuality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .accessibilityIdentifier("settings.imageGeneration.qualitySelector")

                Picker("Output Format", selection: $openAIService.outputFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .accessibilityIdentifier("settings.imageGeneration.formatSelector")

                VStack(alignment: .leading) {
                    Text("Compression: \(openAIService.outputCompression)%")
                    Slider(value: Binding(
                        get: { Double(openAIService.outputCompression) },
                        set: { openAIService.outputCompression = Int($0) }
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
    @Environment(\.openURL) var openURL
    @ObservedObject var openAIService = OpenAIService.shared
    @ObservedObject var githubOAuth = GitHubOAuthService.shared

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

    /// Returns the effective API key - OAuth token if signed in
    private var effectiveAPIKey: String {
        if provider == .githubModels, githubOAuth.isAuthenticated,
           let token = githubOAuth.getAccessToken()
        {
            return token
        }
        return ""
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
                    Text("GitHub Models").tag(AIProvider.githubModels)
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
            } else if provider == .githubModels {
                // Show OAuth status if signed in
                if githubOAuth.isAuthenticated {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.statusConnected)
                            if let user = githubOAuth.currentUser {
                                Text("Signed in as @\(user.login)")
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                Text("Signed in with GitHub")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Button("Sign Out", role: .destructive) {
                            githubOAuth.signOut()
                        }
                    } header: {
                        Text("Authentication")
                    } footer: {
                        Text("Using your GitHub account for authentication.")
                    }
                } else {
                    Section {
                        Button {
                            githubOAuth.startWebFlow()
                        } label: {
                            HStack {
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with GitHub")
                            }
                        }
                        .disabled(githubOAuth.isAuthenticating)
                        .accessibilityIdentifier("settings.github.signInButton")

                        if githubOAuth.isAuthenticating {
                            HStack {
                                ProgressView()
                                Text("Completing sign in...")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button("Cancel", role: .destructive) {
                                    githubOAuth.cancelAuthentication()
                                }
                                .font(Typography.caption)
                            }
                        }

                        if let error = githubOAuth.authError {
                            ErrorBannerView(
                                message: error,
                                onDismiss: { githubOAuth.authError = nil },
                                identifierPrefix: "settings.github.authError"
                            )
                        }
                    } header: {
                        Text("Sign In")
                    }
                }

                Section {
                    if githubOAuth.isLoadingModels {
                        HStack {
                            ProgressView()
                            Text("Loading models...")
                        }
                    } else if !githubOAuth.availableModels.isEmpty {
                        Picker("Select Model", selection: $modelName) {
                            Text("Select...").tag("")
                            ForEach(githubOAuth.availableModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .accessibilityIdentifier("settings.github.modelSelector")
                        Text("\(githubOAuth.availableModels.count) models available")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else if let error = githubOAuth.modelsError {
                        TextField("Model ID (e.g., openai/gpt-4o)", text: $modelName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Model ID")
                            .accessibilityIdentifier("settings.addModel.githubModelId")
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.statusConnecting)
                            Text(error)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Button("Retry") {
                            Task { await githubOAuth.fetchModels() }
                        }
                    } else {
                        TextField("Model ID (e.g., openai/gpt-4o)", text: $modelName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Model ID")
                            .accessibilityIdentifier("settings.addModel.githubModelId")
                        if githubOAuth.isAuthenticated {
                            Button("Load Available Models") {
                                Task { await githubOAuth.fetchModels() }
                            }
                            .accessibilityIdentifier("settings.github.loadModelsButton")
                        } else {
                            Text("Sign in to see available models")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                } header: {
                    Text("Model Selection")
                } footer: {
                    Text("Select from available GitHub Models or enter model ID in format: publisher/model_name")
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
                .disabled(modelName.isEmpty || (provider == .githubModels && !githubOAuth.isAuthenticated))
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
            .openAIService,
            level: .info,
            message: "📂 Loading model data",
            metadata: ["model": modelName]
        )
        if let savedProvider = openAIService.modelProviders[modelName] {
            provider = savedProvider
        }
        if let savedKey = openAIService.modelAPIKeys[modelName] {
            apiKey = savedKey
        }
        if let savedEndpoint = openAIService.modelEndpoints[modelName] {
            endpoint = savedEndpoint
        }
        if let savedType = openAIService.modelEndpointTypes[modelName] {
            endpointType = savedType
        }
    }

    private func saveModel() {
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRename = !isNew && trimmedName != originalModelName

        DiagnosticsLogger.log(
            .openAIService,
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
            if openAIService.customModels.contains(trimmedName) {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .default,
                    message: "⚠️ Duplicate model name, skipping",
                    metadata: ["model": trimmedName]
                )
                return
            }
            openAIService.customModels.append(trimmedName)
        } else if isRename {
            // Check if new name already exists
            if openAIService.customModels.contains(trimmedName) {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .default,
                    message: "⚠️ Model name already exists, skipping rename",
                    metadata: ["model": trimmedName]
                )
                return
            }

            // Update the model list: replace old name with new name
            if let index = openAIService.customModels.firstIndex(of: originalModelName) {
                openAIService.customModels[index] = trimmedName
            }

            // Remove old model settings
            openAIService.modelProviders.removeValue(forKey: originalModelName)
            openAIService.modelAPIKeys.removeValue(forKey: originalModelName)
            openAIService.modelEndpoints.removeValue(forKey: originalModelName)
            openAIService.modelEndpointTypes.removeValue(forKey: originalModelName)
            openAIService.modelUsesGitHubOAuth.removeValue(forKey: originalModelName)

            // Update selected model if it was the renamed one
            if openAIService.selectedModel == originalModelName {
                openAIService.selectedModel = trimmedName
            }
        }

        openAIService.modelProviders[trimmedName] = provider

        if provider == .openai {
            if !apiKey.isEmpty {
                openAIService.modelAPIKeys[trimmedName] = apiKey
            }
            if !endpoint.isEmpty {
                openAIService.modelEndpoints[trimmedName] = endpoint
            }
            openAIService.modelEndpointTypes[trimmedName] = endpointType
        } else if provider == .githubModels {
            // Use OAuth if signed in
            if githubOAuth.isAuthenticated {
                openAIService.modelUsesGitHubOAuth[trimmedName] = true
                openAIService.modelAPIKeys.removeValue(forKey: trimmedName)
            }
        }

        // If this is the first model, select it
        if openAIService.customModels.count == 1 {
            openAIService.selectedModel = trimmedName
        }
    }
}

// MARK: - iOS GitHub Account View

struct IOSGitHubAccountView: View {
    @ObservedObject private var githubOAuth = GitHubOAuthService.shared
    @Environment(\.openURL) private var openURL
    @State private var showingSignOutAlert = false

    var body: some View {
        if githubOAuth.isAuthenticated {
            // Signed in state
            HStack(spacing: Spacing.md) {
                // Avatar
                if let avatarUrl = githubOAuth.currentUser?.avatarUrl,
                   let url = URL(string: avatarUrl)
                {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: Typography.IconSize.heroLarge / 2))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: Typography.IconSize.heroLarge / 2))
                        .foregroundStyle(Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    if let user = githubOAuth.currentUser {
                        Text(user.name ?? user.login)
                            .font(Typography.subheadline)
                        Text("@\(user.login)")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Signed in")
                            .font(Typography.subheadline)
                    }
                }

                Spacer()

                Button("Sign Out", role: .destructive) {
                    showingSignOutAlert = true
                }
                .buttonStyle(.borderless)
            }
            .alert("Sign Out", isPresented: $showingSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    githubOAuth.signOut()
                }
            } message: {
                Text("Are you sure you want to sign out of GitHub?")
            }
        } else if githubOAuth.isAuthenticating {
            // Authenticating state
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text("Signing in...")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    githubOAuth.cancelAuthentication()
                }
                .foregroundStyle(Theme.textSecondary)
            }
        } else {
            // Signed out state
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Button {
                    githubOAuth.startWebFlow()
                } label: {
                    HStack {
                        Image(systemName: "person.badge.key.fill")
                        Text("Sign in with GitHub")
                    }
                }

                if let error = githubOAuth.authError {
                    ErrorBannerView(
                        message: error,
                        onDismiss: { githubOAuth.authError = nil },
                        identifierPrefix: "settings.oauth.authError"
                    )
                }
            }
        }
    }
}

// MARK: - Tools Settings View

/// iOS view for managing tools (Web Search)
struct IOSToolsSettingsView: View {
    @ObservedObject private var tavilyService = TavilyService.shared

    var body: some View {
        Form {
            // Built-in Tools
            Section {
                HStack {
                    Image(systemName: "globe")
                        .font(Typography.title2)
                        .foregroundStyle(tavilyService.isEnabled && tavilyService.isConfigured ? Theme.accent : Theme.textSecondary)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text("Web Search")
                            .font(Typography.headline)

                        if tavilyService.isEnabled {
                            if tavilyService.isConfigured {
                                Text("Powered by Tavily")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                Text("API key required")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.statusConnecting)
                            }
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
                        if !tavilyService.isConfigured {
                            Text("Enter your Tavily API key to enable web search.")
                                .foregroundStyle(Theme.statusConnecting)
                        }
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
                    if !tavilyService.isConfigured {
                        Text("Enter your Tavily API key to enable web search.")
                            .foregroundStyle(Theme.statusConnecting)
                    }
                    Link("Get an API key at tavily.com", destination: URL(string: "https://tavily.com")!)
                }
            } else {
                Text("When enabled, models can search the web for current information.")
            }
        }
    }
}
