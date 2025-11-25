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
    @EnvironmentObject var conversationManager: ConversationManager
    @AppStorage("autoGenerateTitle") private var autoGenerateTitle = true

    @State private var showingAddSheet = false
    @State private var selectedModelForEditing: String?

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - General

                Section("General") {
                    Toggle("Auto-Generate Titles", isOn: $autoGenerateTitle)
                        .accessibilityIdentifier(TestIdentifiers.Settings.autoGenerateTitleToggle)

                    NavigationLink("System Prompt") {
                        IOSSystemPromptSettingsView()
                    }
                    .accessibilityIdentifier("settings.systemPrompt.link")

                    NavigationLink("Image Generation Settings") {
                        IOSImageGenerationSettingsView()
                    }

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

                // MARK: - Models

                Section("Models") {
                    ForEach(openAIService.customModels, id: \.self) { model in
                        NavigationLink {
                            IOSModelEditView(modelName: model, isNew: false)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model)
                                        .font(.headline)
                                    if let provider = openAIService.modelProviders[model] {
                                        Text(provider.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model == openAIService.selectedModel {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
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

                Picker("Image Quality", selection: $openAIService.imageQuality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }

                Picker("Output Format", selection: $openAIService.outputFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }

                VStack(alignment: .leading) {
                    Text("Compression: \(openAIService.outputCompression)%")
                    Slider(value: Binding(
                        get: { Double(openAIService.outputCompression) },
                        set: { openAIService.outputCompression = Int($0) }
                    ), in: 0 ... 100, step: 10)
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
    @ObservedObject var openAIService = OpenAIService.shared

    let isNew: Bool
    @State var modelName: String

    @State private var provider: AIProvider = .openai
    @State private var apiKey = ""
    @State private var endpoint = ""
    @State private var endpointType: APIEndpointType = .chatCompletions

    init(modelName: String, isNew: Bool) {
        _modelName = State(initialValue: modelName)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section("Model Details") {
                if isNew {
                    TextField("Model Name", text: $modelName)
                } else {
                    Text(modelName)
                        .foregroundStyle(.secondary)
                }

                Picker("Provider", selection: $provider) {
                    Text("OpenAI").tag(AIProvider.openai)
                    Text("Apple Intelligence").tag(AIProvider.appleIntelligence)
                }
            }

            if provider == .openai {
                Section("Configuration") {
                    SecureField("API Key", text: $apiKey)

                    TextField("Endpoint URL", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    Picker("Endpoint Type", selection: $endpointType) {
                        ForEach(APIEndpointType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
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
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveModel()
                    dismiss()
                }
                .disabled(modelName.isEmpty)
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
        DiagnosticsLogger.log(
            .openAIService,
            level: .info,
            message: isNew ? "➕ Adding new model" : "💾 Saving model changes",
            metadata: [
                "model": modelName,
                "provider": provider.displayName,
                "hasEndpoint": "\(!endpoint.isEmpty)",
            ]
        )
        if isNew {
            if openAIService.customModels.contains(modelName) {
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .default,
                    message: "⚠️ Duplicate model name, skipping",
                    metadata: ["model": modelName]
                )
                // Handle duplicate name if needed, for now just return or overwrite
                return
            }
            openAIService.customModels.append(modelName)
        }

        openAIService.modelProviders[modelName] = provider

        if provider == .openai {
            if !apiKey.isEmpty {
                openAIService.modelAPIKeys[modelName] = apiKey
            }
            if !endpoint.isEmpty {
                openAIService.modelEndpoints[modelName] = endpoint
            }
            openAIService.modelEndpointTypes[modelName] = endpointType
        }

        // If this is the first model, select it
        if openAIService.customModels.count == 1 {
            openAIService.selectedModel = modelName
        }
    }
}
