//
//  MacSettingsView.swift
//  ayna
//
//  Created on 11/2/25.
//

import SwiftUI

// swiftlint:disable:next superfluous_disable_command
// swiftlint:disable file_length type_body_length

struct MacSettingsView: View {
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

            ToolsSettingsView()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .tag(SettingsTab.mcp)
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
    @State private var globalSystemPrompt = AppPreferences.globalSystemPrompt
    @ObservedObject private var openAIService = OpenAIService.shared
    @ObservedObject private var githubOAuth = GitHubOAuthService.shared
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default System Prompt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $globalSystemPrompt)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .accessibilityIdentifier("settings.globalSystemPrompt.editor")
                        .onChange(of: globalSystemPrompt) { _, newValue in
                            AppPreferences.globalSystemPrompt = newValue
                        }
                }
            } header: {
                Text("System Prompt")
            } footer: {
                Text("This prompt is sent at the start of every conversation unless overridden per-conversation. Leave empty for no default prompt.")
                    .font(.caption)
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

/// Settings section for Tavily Web Search configuration
struct WebSearchSettingsSection: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @State private var showAPIKey = false

    var body: some View {
        Section {
            Toggle("Enable Web Search", isOn: $tavilyService.isEnabled)
                .help("Allow models to search the web for current information")
                .accessibilityIdentifier("settings.webSearch.enableToggle")

            if tavilyService.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tavily API Key")
                            .font(.subheadline)
                        Spacer()
                        if tavilyService.isConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Text("Required")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }

                    HStack(spacing: 8) {
                        if showAPIKey {
                            TextField("tvly-...", text: $tavilyService.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("settings.webSearch.apiKey.textField")
                        } else {
                            SecureField("tvly-...", text: $tavilyService.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("settings.webSearch.apiKey.secureField")
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
                        .accessibilityIdentifier("settings.webSearch.apiKey.toggleVisibility")
                    }

                    HStack(spacing: 4) {
                        Text("Get your API key at")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Link("tavily.com", destination: URL(string: "https://tavily.com")!)
                            .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
        } header: {
            Text("Web Search")
        } footer: {
            Text("When enabled, models can search the web for current information using Tavily. This allows answering questions about recent events, current prices, and other time-sensitive topics.")
                .font(.caption)
        }
    }
}

/// Combined Tools settings view containing Web Search and MCP Servers
struct ToolsSettingsView: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @StateObject private var mcpManager = MCPServerManager.shared

    var body: some View {
        HSplitView {
            // Left panel - Tool Configuration
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tools")
                            .font(.title2)
                            .fontWeight(.semibold)

                        let toolCount = (tavilyService.isEnabled && tavilyService.isConfigured ? 1 : 0) + mcpManager.availableTools.count
                        Text("\(toolCount) tools available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        Task {
                            await mcpManager.discoverAllTools()
                        }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(mcpManager.isDiscovering)
                }
                .padding()

                Divider()

                // Tools list
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Built-in Tools Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Built-in Tools")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)

                            WebSearchToolRow()
                        }
                        .padding(.horizontal)

                        Divider()
                            .padding(.horizontal)

                        // MCP Tools Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("MCP Servers")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text("\(mcpManager.getConnectedServerCount()) connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            MCPServersList()
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .frame(minWidth: 300)

            // Right panel - Details/Configuration
            ToolConfigurationPanel()
        }
        .accessibilityIdentifier("settings.tools.view")
    }
}

/// Row displaying Web Search tool status
struct WebSearchToolRow: View {
    @ObservedObject private var tavilyService = TavilyService.shared

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Web Search")
                    .font(.headline)

                HStack(spacing: 4) {
                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if tavilyService.isEnabled, tavilyService.isConfigured {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text("1 tool")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: $tavilyService.isEnabled)
                .labelsHidden()
                .accessibilityIdentifier("settings.tools.webSearch.toggle")
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        if !tavilyService.isEnabled {
            .gray
        } else if tavilyService.isConfigured {
            .green
        } else {
            .orange
        }
    }

    private var statusDescription: String {
        if !tavilyService.isEnabled {
            "Disabled"
        } else if tavilyService.isConfigured {
            "Configured"
        } else {
            "API key required"
        }
    }
}

/// List of MCP servers
struct MCPServersList: View {
    @StateObject private var mcpManager = MCPServerManager.shared
    @State private var showingAddServer = false
    @State private var editingServer: MCPServerConfig?

    var body: some View {
        VStack(spacing: 12) {
            if mcpManager.serverConfigs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.title)
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("No MCP Servers")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Add Server") {
                        showingAddServer = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            } else {
                ForEach(mcpManager.serverConfigs) { config in
                    MCPServerRow(
                        config: config,
                        status: mcpManager.getServerStatus(config.name),
                        tools: mcpManager.availableTools.filter { $0.serverName == config.name },
                        onEdit: { editingServer = config },
                        onDelete: { mcpManager.removeServerConfig(config) },
                        onToggle: {
                            var updated = config
                            updated.enabled.toggle()
                            mcpManager.updateServerConfig(updated)
                        },
                        onRetry: {
                            Task {
                                await mcpManager.connectToServer(config, autoDisableOnFailure: false)
                            }
                        }
                    )
                }

                Button {
                    showingAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .sheet(isPresented: $showingAddServer) {
            ServerConfigSheet(
                config: nil,
                onSave: { config in
                    mcpManager.addServerConfig(config)
                    showingAddServer = false
                },
                onCancel: {
                    showingAddServer = false
                }
            )
        }
        .sheet(item: $editingServer) { config in
            ServerConfigSheet(
                config: config,
                onSave: { updated in
                    mcpManager.updateServerConfig(updated)
                    editingServer = nil
                },
                onCancel: {
                    editingServer = nil
                }
            )
        }
    }
}

/// Compact MCP Server row
struct MCPServerRow: View {
    let config: MCPServerConfig
    let status: MCPServerStatus?
    let tools: [MCPTool]
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void
    let onRetry: () -> Void

    @State private var isEnabled: Bool

    init(
        config: MCPServerConfig,
        status: MCPServerStatus?,
        tools: [MCPTool],
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.config = config
        self.status = status
        self.tools = tools
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onToggle = onToggle
        self.onRetry = onRetry
        _isEnabled = State(initialValue: config.enabled)
    }

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.headline)

                HStack(spacing: 4) {
                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !tools.isEmpty {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text("\(tools.count) tools")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { _, _ in
                    onToggle()
                }

            Menu {
                Button("Edit") { onEdit() }
                if canRetry {
                    Button("Retry Connection") { onRetry() }
                }
                Divider()
                Button("Delete", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch status?.state {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .error: .red
        case .disabled: .gray
        default: config.enabled ? .secondary : .gray
        }
    }

    private var statusDescription: String {
        switch status?.state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .error: "Error"
        case .disabled: "Disabled"
        default: config.enabled ? "Idle" : "Disabled"
        }
    }

    private var canRetry: Bool {
        guard config.enabled else { return false }
        switch status?.state {
        case .connected, .connecting, .reconnecting, .disabled: return false
        default: return true
        }
    }
}

/// Right panel for tool configuration
struct ToolConfigurationPanel: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @State private var showAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Configuration")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Web Search Configuration
                    if tavilyService.isEnabled {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Web Search")
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Tavily API Key")
                                        .font(.subheadline)
                                    Spacer()
                                    if tavilyService.isConfigured {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                    } else {
                                        Text("Required")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.1))
                                            .cornerRadius(4)
                                    }
                                }

                                HStack(spacing: 8) {
                                    if showAPIKey {
                                        TextField("tvly-...", text: $tavilyService.apiKey)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityIdentifier("settings.tools.webSearch.apiKey.textField")
                                    } else {
                                        SecureField("tvly-...", text: $tavilyService.apiKey)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityIdentifier("settings.tools.webSearch.apiKey.secureField")
                                    }

                                    Button(action: { showAPIKey.toggle() }) {
                                        Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32, height: 32)
                                            .background(Color.secondary.opacity(0.1))
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("settings.tools.webSearch.apiKey.toggleVisibility")
                                }

                                HStack(spacing: 4) {
                                    Text("Get your API key at")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Link("tavily.com", destination: URL(string: "https://tavily.com")!)
                                        .font(.caption)
                                }
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    // Info text
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About Tools")
                            .font(.headline)

                        Text("Tools extend the capabilities of AI models by allowing them to access external data and services. When enabled, models can automatically use these tools to provide more accurate and up-to-date responses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("• **Web Search**: Search the web for current information\n• **MCP Servers**: Connect to external services via the Model Context Protocol")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
        }
        .frame(minWidth: 280)
    }
}

struct APISettingsView: View {
    @ObservedObject private var openAIService = OpenAIService.shared
    @State private var showAPIKey = false
    @State private var tempAPIKey = ""
    @State private var tempEndpoint = ""
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
                        // API Endpoint Type Selection (not applicable for Apple Intelligence, AIKit, or GitHub Models)
                        if openAIService.provider != .appleIntelligence, openAIService.provider != .aikit, openAIService.provider != .githubModels {
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
                                    }
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
                                            "https://api.openai.com or http://localhost:8000", text: $tempEndpoint
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: tempEndpoint) { _, _ in
                                            validationStatus = .notChecked
                                        }
                                        Text(
                                            "OpenAI-compatible API endpoint (e.g., https://api.openai.com, http://localhost:8000). For Azure, enter https://<resource>.openai.azure.com and set Model Name to your deployment name.")
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
                                                || tempEndpoint.isEmpty
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
                                                || tempEndpoint.isEmpty
                                        )
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
                        } else if openAIService.provider == .githubModels {
                            // GitHub Models Configuration
                            GitHubModelsConfigurationView(
                                tempModelName: $tempModelName,
                                tempAPIKey: $tempAPIKey,
                                showAPIKey: $showAPIKey,
                                selectedModelName: $selectedModelName,
                                validationStatus: $validationStatus
                            )
                            .padding(.horizontal)
                        } else if openAIService.provider == .aikit {
                            // AIKit Configuration
                            AIKitConfigurationView(
                                tempModelName: $tempModelName,
                                selectedModelName: $selectedModelName
                            )
                            .padding(.horizontal)
                        }

                        // Status Section
                        if openAIService.provider != .appleIntelligence, openAIService.provider != .aikit, openAIService.provider != .githubModels {
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
            // Default to "new model" state for GitHub Models
            if openAIService.provider == .githubModels {
                createNewModel()
            }
        }
        .onChange(of: openAIService.provider) { _, newProvider in
            // Reset to "new model" state when switching to GitHub Models
            if newProvider == .githubModels {
                createNewModel()
            }
        }
    }

    private func createNewModel() {
        // Clear all fields and deselect - complete clean slate
        selectedModelName = nil
        tempModelName = ""
        tempAPIKey = ""
        tempEndpoint = "https://api.openai.com/"
        tempEndpointType = .chatCompletions
        validationStatus = .notChecked
    }

    private func validateConfiguration() async {
        validationStatus = .checking

        guard openAIService.provider == .openai else {
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
                guard !apiKey.isEmpty else {
                    validationStatus = .invalid("API key is required for Azure endpoints")
                    return
                }

                let urlString =
                    "\(endpoint)/openai/deployments/\(modelName)/chat/completions?api-version=\(openAIService.latestAzureAPIVersion)"
                guard let url = URL(string: urlString) else {
                    validationStatus = .invalid("Invalid endpoint URL")
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let testPayload: [String: Any] = [
                    "messages": [["role": "user", "content": "test"]],
                    "model": modelName
                ]

                request.httpBody = try JSONSerialization.data(withJSONObject: testPayload)

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
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String
                    {
                        if message.contains("deployment") || message.contains("not found") {
                            validationStatus = .invalid("Deployment '\(modelName)' not found")
                        } else {
                            validationStatus = .invalid(message)
                        }
                    } else {
                        validationStatus = .invalid("Deployment not found")
                    }
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
            } else {
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

                let (data, response) = try await URLSession.shared.data(for: request)

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
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
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

// MARK: - GitHub Models Configuration View

struct GitHubModelsConfigurationView: View {
    @ObservedObject private var openAIService = OpenAIService.shared
    @ObservedObject private var githubOAuth = GitHubOAuthService.shared
    @Binding var tempModelName: String
    @Binding var tempAPIKey: String
    @Binding var showAPIKey: Bool
    @Binding var selectedModelName: String?
    @Binding var validationStatus: APISettingsView.ValidationStatus

    @State private var isValidating = false

    /// Returns the effective API key - OAuth token if signed in
    private var effectiveAPIKey: String {
        if githubOAuth.isAuthenticated, let token = githubOAuth.getAccessToken() {
            return token
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("GitHub Models Configuration", systemImage: "mark.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 16) {
                // Info section
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("Access AI models through GitHub Models using your GitHub account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Show OAuth status if signed in
                if githubOAuth.isAuthenticated {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if let user = githubOAuth.currentUser {
                                Text("Signed in as @\(user.login)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Signed in with GitHub")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            // Token refresh indicator
                            if githubOAuth.isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .help("Refreshing token...")
                            }

                            Button("Sign Out") {
                                githubOAuth.signOut()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
                } else {
                    // Sign In Button
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            githubOAuth.startWebFlow()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with GitHub")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(githubOAuth.isAuthenticating)

                        if githubOAuth.isAuthenticating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Completing sign in...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel") {
                                    githubOAuth.cancelAuthentication()
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                            .padding(8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(6)
                        }

                        if let error = githubOAuth.authError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                // Model Selection
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Model")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        if githubOAuth.isLoadingModels {
                            ProgressView().controlSize(.small)
                            Text("Loading...").font(.caption2).foregroundStyle(.secondary)
                        } else if !githubOAuth.availableModels.isEmpty {
                            Button {
                                Task { await githubOAuth.fetchModels() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Refresh models list")
                        }
                        Text("Required")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }

                    // Model Picker or fallback text field
                    if !githubOAuth.availableModels.isEmpty {
                        Picker("", selection: $tempModelName) {
                            Text("Select a model...").tag("")
                            ForEach(githubOAuth.availableModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .labelsHidden()

                        Text("\(githubOAuth.availableModels.count) models available")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if let error = githubOAuth.modelsError {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("openai/gpt-4o", text: $tempModelName)
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Retry") {
                                Task { await githubOAuth.fetchModels() }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("openai/gpt-4o", text: $tempModelName)
                                .textFieldStyle(.roundedBorder)
                            if githubOAuth.isAuthenticated {
                                Button("Load Available Models") {
                                    Task { await githubOAuth.fetchModels() }
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            } else {
                                Text("Sign in to see available models")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text("Model ID in format: publisher/model_name")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Validation Status
                if isValidating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Validating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    switch validationStatus {
                    case .valid:
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Configuration valid")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    case let .invalid(message):
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    default:
                        EmptyView()
                    }
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
                .disabled(tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .controlSize(.large)

                if let selectedName = selectedModelName,
                   openAIService.customModels.contains(selectedName)
                {
                    // Update existing model
                    Button {
                        updateModel()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                            Text("Update Model")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    // Add new model
                    Button {
                        addModel()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Model")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private func validateConfiguration() async {
        isValidating = true
        validationStatus = .checking

        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = effectiveAPIKey

        guard !modelName.isEmpty else {
            await MainActor.run {
                isValidating = false
                validationStatus = .invalid("Model ID is required")
            }
            return
        }

        guard !apiKey.isEmpty else {
            await MainActor.run {
                isValidating = false
                validationStatus = .invalid("GitHub authentication is required. Sign in with GitHub.")
            }
            return
        }

        // Test the API by making a simple request
        do {
            guard let url = URL(string: "https://models.github.ai/inference/chat/completions") else {
                await MainActor.run {
                    isValidating = false
                    validationStatus = .invalid("Invalid API URL")
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            let testPayload: [String: Any] = [
                "model": modelName,
                "messages": [["role": "user", "content": "test"]],
                "max_tokens": 1
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: testPayload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    isValidating = false
                    validationStatus = .invalid("Invalid response from server")
                }
                return
            }

            await MainActor.run {
                isValidating = false

                switch httpResponse.statusCode {
                case 200:
                    validationStatus = .valid
                case 401, 403:
                    validationStatus = .invalid("Invalid GitHub authentication or insufficient permissions. Ensure token has 'models:read' scope.")
                case 404:
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String
                    {
                        validationStatus = .invalid(message)
                    } else {
                        validationStatus = .invalid("Model '\(modelName)' not found")
                    }
                case 422:
                    validationStatus = .invalid("Invalid model ID format. Use publisher/model_name format.")
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
        } catch {
            await MainActor.run {
                isValidating = false
                validationStatus = .invalid(error.localizedDescription)
            }
        }
    }

    private func addModel() {
        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !modelName.isEmpty, !openAIService.customModels.contains(modelName) else { return }

        openAIService.customModels.append(modelName)
        openAIService.modelProviders[modelName] = .githubModels

        // Mark that this model uses OAuth if signed in
        if githubOAuth.isAuthenticated {
            openAIService.modelUsesGitHubOAuth[modelName] = true
        }

        if openAIService.customModels.count == 1 {
            openAIService.selectedModel = modelName
        }
        selectedModelName = modelName
        validationStatus = .notChecked
    }

    private func updateModel() {
        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !modelName.isEmpty else { return }

        openAIService.modelProviders[modelName] = .githubModels

        // Using OAuth, remove any stored PAT
        openAIService.modelAPIKeys.removeValue(forKey: modelName)
        openAIService.modelUsesGitHubOAuth[modelName] = true

        validationStatus = .notChecked
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

// MARK: - GitHub Account View

// Removed as it is now integrated into GitHubModelsConfigurationView

#Preview {
    MacSettingsView()
}

// swiftlint:enable file_length type_body_length
