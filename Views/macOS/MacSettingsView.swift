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
    @ObservedObject private var aiService = AIService.shared
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

            AgentsSettingsSection()
                .tabItem {
                    Label("Agents", systemImage: "cpu.fill")
                }
                .tag(SettingsTab.agents)

            MemorySettingsSection()
                .tabItem {
                    Label("Memory", systemImage: "brain")
                }
                .tag(SettingsTab.memory)
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
    @State private var attachFromAppEnabled = AppPreferences.attachFromAppEnabled
    @State private var multiModelSelectionEnabled = AppPreferences.multiModelSelectionEnabled
    @ObservedObject private var aiService = AIService.shared
    @ObservedObject private var githubOAuth = GitHubOAuthService.shared
    @EnvironmentObject private var conversationManager: ConversationManager

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Generate Titles", isOn: $autoGenerateTitle)
                    .help("Automatically generate conversation titles from first message")

                Toggle("Multi-Model Selection", isOn: $multiModelSelectionEnabled)
                    .help("Allow selecting multiple models to compare responses side-by-side")
                    .onChange(of: multiModelSelectionEnabled) { _, newValue in
                        AppPreferences.multiModelSelectionEnabled = newValue
                    }
            } header: {
                Text("Behavior")
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Default System Prompt")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    TextEditor(text: $globalSystemPrompt)
                        .font(Typography.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.sm)
                        .background(Theme.background)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
                                .stroke(Theme.separator, lineWidth: Spacing.Border.standard)
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
                Picker("Image Size", selection: $aiService.imageSize) {
                    Text("1024×1024 (Square)").tag("1024x1024")
                    Text("1024×1536 (Portrait)").tag("1024x1536")
                    Text("1536×1024 (Landscape)").tag("1536x1024")
                }
                .help("Resolution for generated images")

                Picker("Image Quality", selection: $aiService.imageQuality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .help("Quality level affects generation time and cost")

                Picker("Output Format", selection: $aiService.outputFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .help("Image file format")

                HStack {
                    Text("Compression")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(aiService.outputCompression) },
                        set: { aiService.outputCompression = Int($0) }
                    ), in: 0 ... 100, step: 10)
                        .frame(width: 150)
                    Text("\(aiService.outputCompression)%")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 45, alignment: .trailing)
                }
                .help("Image compression level (100 = no compression)")
            } header: {
                Text("Image Generation")
            } footer: {
                Text("These settings apply when using image generation models")
                    .font(Typography.caption)
            }

            // Attach from App Section
            AttachFromAppSettingsSection(isEnabled: $attachFromAppEnabled)

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
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Tavily API Key")
                            .font(Typography.subheadline)
                        Spacer()
                        if tavilyService.isConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.statusConnected)
                                .font(Typography.caption)
                        } else {
                            Text("Required")
                                .font(Typography.micro)
                                .foregroundStyle(Theme.statusConnecting)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, Spacing.xxxs)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
                        }
                    }

                    HStack(spacing: Spacing.sm) {
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
                                .font(.system(size: Typography.Size.sm))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 32, height: 32)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                        .accessibilityIdentifier("settings.webSearch.apiKey.toggleVisibility")
                    }

                    HStack(spacing: Spacing.xxs) {
                        Text("Get your API key at")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                        Link("tavily.com", destination: URL(string: "https://tavily.com")!)
                            .font(Typography.caption)
                    }
                }
                .padding(.top, Spacing.xxs)
            }
        } header: {
            Text("Web Search")
        } footer: {
            Text("When enabled, models can search the web for current information using Tavily. This allows answering questions about recent events, current prices, and other time-sensitive topics.")
                .font(Typography.caption)
        }
    }
}

/// Settings section for "Attach from App" feature
struct AttachFromAppSettingsSection: View {
    @Binding var isEnabled: Bool
    @State private var accessibilityEnabled = AccessibilityService.shared.isEnabled

    var body: some View {
        Section {
            Toggle("Enable Attach from App", isOn: $isEnabled)
                .help("Use a global hotkey to capture context from any app and ask questions about it")
                .accessibilityIdentifier("settings.attachFromApp.enableToggle")
                .onChange(of: isEnabled) { _, newValue in
                    AppPreferences.attachFromAppEnabled = newValue

                    if newValue {
                        // Register hotkey when enabled
                        do {
                            try GlobalHotkeyService.shared.registerDefault()
                            AccessibilityService.shared.startMonitoring()
                        } catch {
                            DiagnosticsLogger.log(
                                .attachFromApp,
                                level: .error,
                                message: "Failed to register hotkey",
                                metadata: ["error": error.localizedDescription]
                            )
                        }
                    } else {
                        // Unregister when disabled
                        GlobalHotkeyService.shared.unregister()
                        AccessibilityService.shared.stopMonitoring()
                    }
                }

            if isEnabled {
                // Hotkey display
                LabeledContent("Hotkey") {
                    Text(AppPreferences.attachFromAppHotkey)
                        .font(Typography.code)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(Theme.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.xs))
                }
                .accessibilityIdentifier("settings.attachFromApp.hotkey")

                // Accessibility permission status
                LabeledContent("Accessibility") {
                    if accessibilityEnabled {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.statusConnected)
                            .font(Typography.caption)
                    } else {
                        Button {
                            AccessibilityService.shared.openAccessibilityPreferences()
                        } label: {
                            Label("Grant Permission", systemImage: "gearshape")
                        }
                        .buttonStyle(.link)
                        .font(Typography.caption)
                    }
                }
                .accessibilityIdentifier("settings.attachFromApp.accessibility")
            }
        } header: {
            Text("Attach from App")
        } footer: {
            Text("Press \(AppPreferences.attachFromAppHotkey) anywhere to capture content from the focused app and ask questions about it. Requires Accessibility permission.")
                .font(Typography.caption)
        }
        .onAppear {
            accessibilityEnabled = AccessibilityService.shared.checkPermission(prompt: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityPermissionChanged)) { notification in
            if let enabled = notification.userInfo?["enabled"] as? Bool {
                accessibilityEnabled = enabled
            }
        }
    }
}

/// Combined Tools settings view containing Web Search and MCP Servers
struct ToolsSettingsView: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @StateObject private var mcpManager = MCPServerManager.shared
    @Bindable private var agentSettings = AgentSettingsStore.shared

    var body: some View {
        HSplitView {
            // Left panel - Tool Configuration
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Tools")
                            .font(Typography.title2)
                            .fontWeight(.semibold)

                        let webSearchCount = (tavilyService.isEnabled && tavilyService.isConfigured ? 1 : 0)
                        let agenticToolCount = agentSettings.settings.isEnabled ? 6 : 0
                        let toolCount = webSearchCount + agenticToolCount + mcpManager.availableTools.count
                        Text("\(toolCount) tools available")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
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
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        // Built-in Tools Section
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("Built-in Tools")
                                .font(Typography.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(Theme.textSecondary)

                            WebSearchToolRow()
                        }
                        .padding(.horizontal)

                        Divider()
                            .padding(.horizontal)

                        // Agentic Tools Section
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            HStack {
                                Text("Agentic Tools")
                                    .font(Typography.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(Theme.textSecondary)

                                Spacer()

                                Button {
                                    SettingsRouter.shared.route(to: .agents)
                                } label: {
                                    Text("Configure")
                                        .font(Typography.caption)
                                }
                                .buttonStyle(.link)
                            }

                            AgenticToolsRow()
                        }
                        .padding(.horizontal)

                        Divider()
                            .padding(.horizontal)

                        // MCP Tools Section
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            HStack {
                                Text("MCP Servers")
                                    .font(Typography.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(Theme.textSecondary)

                                Spacer()

                                Text("\(mcpManager.getConnectedServerCount()) connected")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
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

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Web Search")
                    .font(Typography.headline)

                HStack(spacing: Spacing.xxs) {
                    Text(statusDescription)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if tavilyService.isEnabled, tavilyService.isConfigured {
                        Text("•")
                            .foregroundStyle(Theme.textSecondary)
                        Text("1 tool")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: $tavilyService.isEnabled)
                .labelsHidden()
                .accessibilityIdentifier("settings.tools.webSearch.toggle")
        }
        .padding()
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }

    private var statusColor: Color {
        if !tavilyService.isEnabled {
            Theme.statusDisconnected
        } else if tavilyService.isConfigured {
            Theme.statusConnected
        } else {
            Theme.statusConnecting
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

/// Row displaying Agentic Tools status
struct AgenticToolsRow: View {
    @Bindable private var agentSettings = AgentSettingsStore.shared

    private let toolNames = [
        "read_file", "write_file", "edit_file",
        "list_directory", "search_files", "run_command"
    ]

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Agentic Tools")
                    .font(Typography.headline)

                HStack(spacing: Spacing.xxs) {
                    Text(statusDescription)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if agentSettings.settings.isEnabled {
                        Text("•")
                            .foregroundStyle(Theme.textSecondary)
                        Text("6 tools")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: $agentSettings.settings.isEnabled)
                .labelsHidden()
                .accessibilityIdentifier("settings.tools.agentic.toggle")
        }
        .padding()
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }

    private var statusColor: Color {
        agentSettings.settings.isEnabled ? Theme.statusConnected : Theme.statusDisconnected
    }

    private var statusDescription: String {
        agentSettings.settings.isEnabled ? "Enabled" : "Disabled"
    }
}

/// List of MCP servers
struct MCPServersList: View {
    @StateObject private var mcpManager = MCPServerManager.shared
    @State private var showingAddServer = false
    @State private var editingServer: MCPServerConfig?

    var body: some View {
        VStack(spacing: Spacing.md) {
            if mcpManager.serverConfigs.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "server.rack")
                        .font(Typography.title1)
                        .foregroundStyle(Theme.textSecondary.opacity(0.5))

                    Text("No MCP Servers")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)

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

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(config.name)
                    .font(Typography.headline)

                HStack(spacing: Spacing.xxs) {
                    Text(statusDescription)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if !tools.isEmpty {
                        Text("•")
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(tools.count) tools")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.accent)
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
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
        }
        .padding()
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }

    private var statusColor: Color {
        switch status?.state {
        case .connected: Theme.statusConnected
        case .connecting, .reconnecting: Theme.statusConnecting
        case .error: Theme.statusError
        case .disabled: Theme.statusDisconnected
        default: config.enabled ? .secondary : Theme.statusDisconnected
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
                    .font(Typography.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Web Search Configuration
                    if tavilyService.isEnabled {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("Web Search")
                                .font(Typography.headline)

                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack {
                                    Text("Tavily API Key")
                                        .font(Typography.subheadline)
                                    Spacer()
                                    if tavilyService.isConfigured {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.statusConnected)
                                            .font(Typography.caption)
                                    } else {
                                        Text("Required")
                                            .font(Typography.micro)
                                            .foregroundStyle(Theme.statusConnecting)
                                            .padding(.horizontal, Spacing.xs)
                                            .padding(.vertical, Spacing.xxxs)
                                            .background(Color.orange.opacity(0.1))
                                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
                                    }
                                }

                                HStack(spacing: Spacing.sm) {
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
                                            .font(.system(size: Typography.Size.sm))
                                            .foregroundStyle(Theme.textSecondary)
                                            .frame(width: 32, height: 32)
                                            .background(Color.secondary.opacity(0.1))
                                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                                    .accessibilityIdentifier("settings.tools.webSearch.apiKey.toggleVisibility")
                                }

                                HStack(spacing: Spacing.xxs) {
                                    Text("Get your API key at")
                                        .font(Typography.caption)
                                        .foregroundStyle(.tertiary)
                                    Link("tavily.com", destination: URL(string: "https://tavily.com")!)
                                        .font(Typography.caption)
                                }
                            }
                            .padding()
                            .background(Theme.backgroundSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
                        }
                    }

                    // Info text
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("About Tools")
                            .font(Typography.headline)

                        Text("Tools extend the capabilities of AI models by allowing them to access external data and services. When enabled, models can automatically use these tools to provide more accurate and up-to-date responses.")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)

                        Text("• **Web Search**: Search the web for current information\n• **MCP Servers**: Connect to external services via the Model Context Protocol")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding()
                    .background(Theme.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
                }
                .padding()
            }
        }
        .frame(minWidth: 280)
    }
}

struct APISettingsView: View {
    @ObservedObject private var aiService = AIService.shared
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

                // Model list
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
                        }
                        .padding(Spacing.sm)
                    }
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)
            .background(Theme.backgroundSecondary)

            // Right panel - API Configuration
            VStack(spacing: 0) {
                // Provider Selection - Fixed at top
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // Header
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Model Configuration")
                            .font(Typography.title2)
                            .fontWeight(.semibold)
                        Text("Configure AI provider settings and add models")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Provider Selection
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

                // Scrollable configuration area
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.contentPadding) {
                        // API Endpoint Type Selection (not applicable for Apple Intelligence, GitHub Models, or Anthropic)
                        if aiService.provider != .appleIntelligence, aiService.provider != .githubModels,
                           aiService.provider != .anthropic
                        {
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

                        if aiService.provider == .openai {
                            // OpenAI Configuration
                            VStack(alignment: .leading, spacing: Spacing.lg) {
                                Text("OpenAI Configuration")
                                    .font(Typography.headline)
                                    .foregroundStyle(.primary)

                                VStack(alignment: .leading, spacing: Spacing.lg) {
                                    // Model Name
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

                                    // Endpoint URL
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

                                    // API Key
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
                                                    .frame(width: 32, height: 32)
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

                                // Action Buttons
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
                                        // Update existing model
                                        Button {
                                            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

                                            if !modelName.isEmpty {
                                                // Remove old model data if name changed
                                                if selectedName != modelName {
                                                    aiService.customModels.removeAll { $0 == selectedName }
                                                    aiService.modelProviders.removeValue(forKey: selectedName)
                                                    aiService.modelAPIKeys.removeValue(forKey: selectedName)
                                                    aiService.modelEndpoints.removeValue(forKey: selectedName)
                                                    aiService.modelEndpointTypes.removeValue(forKey: selectedName)

                                                    // Add new model name if not already present
                                                    if !aiService.customModels.contains(modelName) {
                                                        aiService.customModels.append(modelName)
                                                    }

                                                    // Update selected model if it was the renamed one
                                                    if aiService.selectedModel == selectedName {
                                                        aiService.selectedModel = modelName
                                                    }
                                                }

                                                // Update provider and endpoint type
                                                aiService.modelProviders[modelName] = .openai
                                                aiService.modelEndpointTypes[modelName] = tempEndpointType

                                                // Update per-model API key
                                                if !apiKey.isEmpty {
                                                    aiService.modelAPIKeys[modelName] = apiKey
                                                } else {
                                                    aiService.modelAPIKeys.removeValue(forKey: modelName)
                                                }

                                                // Update custom endpoint
                                                if !endpoint.isEmpty {
                                                    aiService.modelEndpoints[modelName] = endpoint
                                                } else {
                                                    aiService.modelEndpoints.removeValue(forKey: modelName)
                                                }

                                                selectedModelName = modelName
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

                                            if !modelName.isEmpty, !aiService.customModels.contains(modelName) {
                                                aiService.customModels.append(modelName)
                                                aiService.modelProviders[modelName] = .openai
                                                aiService.modelEndpointTypes[modelName] = tempEndpointType

                                                // Save per-model API key if provided
                                                if !apiKey.isEmpty {
                                                    aiService.modelAPIKeys[modelName] = apiKey
                                                }

                                                // Save custom endpoint if provided
                                                if !endpoint.isEmpty {
                                                    aiService.modelEndpoints[modelName] = endpoint
                                                }

                                                if aiService.customModels.count == 1 {
                                                    aiService.selectedModel = modelName
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
                        } else if aiService.provider == .appleIntelligence {
                            // Apple Intelligence Configuration
                            VStack(alignment: .leading, spacing: Spacing.lg) {
                                Text("Apple Intelligence Configuration")
                                    .font(Typography.headline)
                                    .foregroundStyle(.primary)

                                VStack(alignment: .leading, spacing: Spacing.lg) {
                                    if #available(macOS 26.0, *) {
                                        let service = AppleIntelligenceService.shared

                                        // Availability Status
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

                                        // Model Name
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
                                        // macOS 26+ required message
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

                                // Action Buttons
                                if #available(macOS 26.0, *) {
                                    HStack(spacing: Spacing.md) {
                                        Button {
                                            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let finalModelName = modelName.isEmpty ? "apple-intelligence" : modelName

                                            if !aiService.customModels.contains(finalModelName) {
                                                aiService.customModels.append(finalModelName)
                                                aiService.modelProviders[finalModelName] = .appleIntelligence
                                                if aiService.customModels.count == 1 {
                                                    aiService.selectedModel = finalModelName
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
                        } else if aiService.provider == .githubModels {
                            // GitHub Models Configuration
                            GitHubModelsConfigurationView(
                                tempModelName: $tempModelName,
                                tempAPIKey: $tempAPIKey,
                                showAPIKey: $showAPIKey,
                                selectedModelName: $selectedModelName,
                                validationStatus: $validationStatus
                            )
                            .padding(.horizontal)
                        } else if aiService.provider == .anthropic {
                            // Anthropic Configuration
                            AnthropicConfigurationView(
                                tempModelName: $tempModelName,
                                tempAPIKey: $tempAPIKey,
                                tempEndpoint: $tempEndpoint,
                                showAPIKey: $showAPIKey,
                                selectedModelName: $selectedModelName,
                                validationStatus: $validationStatus
                            )
                            .padding(.horizontal)
                        }

                        // Status Section
                        if aiService.provider != .appleIntelligence, aiService.provider != .githubModels,
                           aiService.provider != .anthropic
                        {
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
                            .padding(.horizontal)
                            .padding(.bottom)
                        }
                    }
                }
            } // End of outer VStack wrapping provider selection and scroll view
        }
        .onAppear {
            // If there's a selected model, load its config; otherwise set defaults
            if let model = selectedModelName, aiService.customModels.contains(model) {
                loadModelConfig(model)
            } else {
                tempAPIKey = ""
                tempEndpoint = "https://api.openai.com/"
                // Default to "new model" state for GitHub Models and Anthropic
                if aiService.provider == .githubModels || aiService.provider == .anthropic {
                    createNewModel()
                }
            }
        }
        .onChange(of: aiService.provider) { _, newProvider in
            // Reset to "new model" state when switching to GitHub Models or Anthropic
            if newProvider == .githubModels || newProvider == .anthropic {
                createNewModel()
            }
        }
    }

    private func createNewModel() {
        // Clear all fields and deselect - complete clean slate
        selectedModelName = nil
        tempModelName = ""
        tempAPIKey = ""
        // For Anthropic, use empty endpoint (defaults to api.anthropic.com)
        // For others, use OpenAI endpoint
        tempEndpoint = aiService.provider == .anthropic ? "" : "https://api.openai.com/"
        tempEndpointType = .chatCompletions
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
                guard !apiKey.isEmpty else {
                    validationStatus = .invalid("API key is required for Azure endpoints")
                    return
                }

                // Use the /openai/models endpoint to validate Azure credentials without consuming tokens
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
        } catch {
            validationStatus = .invalid(error.localizedDescription)
        }
    }

    private func loadModelConfig(_ model: String) {
        // Switch to the correct provider for this model
        if let modelProvider = aiService.modelProviders[model] {
            aiService.provider = modelProvider
        }

        tempModelName = model
        // Load per-model API key if available
        tempAPIKey = aiService.modelAPIKeys[model] ?? ""
        tempEndpointType = aiService.modelEndpointTypes[model] ?? .chatCompletions

        // Load endpoint based on provider
        switch aiService.provider {
        case .openai:
            tempEndpoint = aiService.modelEndpoints[model] ?? "https://api.openai.com"
        case .anthropic:
            // For Anthropic, empty string means use default (api.anthropic.com)
            tempEndpoint = aiService.modelEndpoints[model] ?? ""
        default:
            tempEndpoint = aiService.modelEndpoints[model] ?? ""
        }
    }

    private func removeModel(_ model: String) {
        aiService.customModels.removeAll { $0 == model }
        // Also remove from provider mapping and per-model settings
        aiService.modelProviders.removeValue(forKey: model)
        aiService.modelEndpoints.removeValue(forKey: model)
        aiService.modelAPIKeys.removeValue(forKey: model)

        // If we removed the selected default model, pick the next available one or clear it
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
        // Always copy endpoint type, defaulting to chatCompletions if not set
        aiService.modelEndpointTypes[newName] = aiService.modelEndpointTypes[model] ?? .chatCompletions
        if let usesOAuth = aiService.modelUsesGitHubOAuth[model] {
            aiService.modelUsesGitHubOAuth[newName] = usesOAuth
        }

        // Select the new model for editing
        selectedModelName = newName
        loadModelConfig(newName)
    }
}

/// Flow layout for quick add buttons
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
    @ObservedObject private var aiService = AIService.shared
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
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("GitHub Models Configuration")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Info section
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.accent)
                    Text("Access AI models through GitHub Models using your GitHub account")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                // Show OAuth status if signed in
                if githubOAuth.isAuthenticated {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.statusConnected)
                            if let user = githubOAuth.currentUser {
                                Text("Signed in as @\(user.login)")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                Text("Signed in with GitHub")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
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
                            .font(Typography.caption)
                        }
                    }
                    .padding(Spacing.sm)
                    .background(Color.green.opacity(0.1))
                    .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                } else {
                    // Sign In Button
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Button {
                            githubOAuth.startWebFlow()
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with GitHub")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(githubOAuth.isAuthenticating)

                        if githubOAuth.isAuthenticating {
                            HStack(spacing: Spacing.sm) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Completing sign in...")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button("Cancel") {
                                    githubOAuth.cancelAuthentication()
                                }
                                .buttonStyle(.link)
                                .font(Typography.caption)
                            }
                            .padding(Spacing.sm)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.sm))
                        }

                        if let error = githubOAuth.authError {
                            HStack(spacing: Spacing.xxs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.statusError)
                                Text(error)
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.statusError)
                            }
                        }
                    }
                }

                // Model Selection
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Model")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        if githubOAuth.isLoadingModels {
                            ProgressView().controlSize(.small)
                            Text("Loading...").font(Typography.micro).foregroundStyle(Theme.textSecondary)
                        } else if !githubOAuth.availableModels.isEmpty {
                            Button {
                                Task { await githubOAuth.fetchModels() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(Typography.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Refresh models list")
                        }
                        Text("Required")
                            .font(Typography.micro)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, Spacing.xxxs)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.xs))
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
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                    } else if let error = githubOAuth.modelsError {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            TextField("openai/gpt-4o", text: $tempModelName)
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: Spacing.xxs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.statusConnecting)
                                    .font(Typography.caption)
                                Text(error)
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Button("Retry") {
                                Task { await githubOAuth.fetchModels() }
                            }
                            .buttonStyle(.link)
                            .font(Typography.caption)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            TextField("openai/gpt-4o", text: $tempModelName)
                                .textFieldStyle(.roundedBorder)
                            if githubOAuth.isAuthenticated {
                                Button("Load Available Models") {
                                    Task { await githubOAuth.fetchModels() }
                                }
                                .buttonStyle(.link)
                                .font(Typography.caption)
                            } else {
                                Text("Sign in to see available models")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }

                    Text("Model ID in format: publisher/model_name")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                // Validation Status
                if isValidating {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Validating...")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    switch validationStatus {
                    case .valid:
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.statusConnected)
                            Text("Configuration valid")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.statusConnected)
                        }
                    case let .invalid(message):
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.statusError)
                            Text(message)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.statusError)
                                .lineLimit(2)
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            .padding(Spacing.lg)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))

            // Action Buttons
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
                .disabled(tempModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .controlSize(.large)

                if let selectedName = selectedModelName,
                   aiService.customModels.contains(selectedName)
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

        // Use the catalog API to validate credentials and check if model exists
        do {
            guard let url = URL(string: "https://models.github.ai/catalog/models") else {
                await MainActor.run {
                    isValidating = false
                    validationStatus = .invalid("Invalid API URL")
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

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
                    // Check if the requested model exists in the catalog
                    if let models = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let modelExists = models.contains { model in
                            guard let id = model["id"] as? String else { return false }
                            return id.lowercased() == modelName.lowercased()
                        }
                        if modelExists {
                            validationStatus = .valid
                        } else {
                            validationStatus = .invalid("Model '\(modelName)' not found in catalog")
                        }
                    } else {
                        // Catalog response parsed but model check skipped - credentials are valid
                        validationStatus = .valid
                    }
                case 401, 403:
                    validationStatus = .invalid("Invalid GitHub authentication or insufficient permissions. Ensure token has 'models:read' scope.")
                default:
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = json["message"] as? String
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

        guard !modelName.isEmpty, !aiService.customModels.contains(modelName) else { return }

        aiService.customModels.append(modelName)
        aiService.modelProviders[modelName] = .githubModels

        // Mark that this model uses OAuth if signed in
        if githubOAuth.isAuthenticated {
            aiService.modelUsesGitHubOAuth[modelName] = true
        }

        if aiService.customModels.count == 1 {
            aiService.selectedModel = modelName
        }
        selectedModelName = modelName
        validationStatus = .notChecked
    }

    private func updateModel() {
        let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !modelName.isEmpty else { return }

        // Remove old model data if name changed
        if let oldName = selectedModelName, oldName != modelName {
            aiService.customModels.removeAll { $0 == oldName }
            aiService.modelProviders.removeValue(forKey: oldName)
            aiService.modelAPIKeys.removeValue(forKey: oldName)
            aiService.modelUsesGitHubOAuth.removeValue(forKey: oldName)

            // Add new model name if not already present
            if !aiService.customModels.contains(modelName) {
                aiService.customModels.append(modelName)
            }

            // Update selected model if it was the renamed one
            if aiService.selectedModel == oldName {
                aiService.selectedModel = modelName
            }
        }

        aiService.modelProviders[modelName] = .githubModels

        // Using OAuth, remove any stored PAT
        aiService.modelAPIKeys.removeValue(forKey: modelName)
        aiService.modelUsesGitHubOAuth[modelName] = true

        selectedModelName = modelName
        validationStatus = .notChecked
    }
}

// MARK: - Anthropic Configuration View

struct AnthropicConfigurationView: View {
    @ObservedObject private var aiService = AIService.shared
    @Binding var tempModelName: String
    @Binding var tempAPIKey: String
    @Binding var tempEndpoint: String
    @Binding var showAPIKey: Bool
    @Binding var selectedModelName: String?
    @Binding var validationStatus: APISettingsView.ValidationStatus

    @State private var isValidating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Anthropic Configuration")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            // Fields card (matching OpenAI style)
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Model Name
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

                // Custom Endpoint (Optional)
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
                    TextField("https://api.anthropic.com", text: $tempEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempEndpoint) { _, _ in
                            validationStatus = .notChecked
                        }
                    Text("Leave empty for the default Anthropic API. Enter a custom URL for proxies or Azure.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                // API Key
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
                                .frame(width: 32, height: 32)
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
            }
            .padding(Spacing.lg)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))

            // Action Buttons (outside the card, matching OpenAI)
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
                    // Update existing model
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
                    // Add new model
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

            // Validation Status Section (matching OpenAI style)
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

        // Validate endpoint URL if provided
        if !endpoint.isEmpty {
            do {
                _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: endpoint)
            } catch {
                validationStatus = .invalid("Invalid endpoint: \(error.localizedDescription)")
                isValidating = false
                return
            }
        }

        // Test the API with a minimal request
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
                // Try to parse error message
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

        // Remove old model if updating
        if let oldName = selectedModelName, oldName != modelName {
            aiService.customModels.removeAll { $0 == oldName }
            aiService.modelProviders.removeValue(forKey: oldName)
            aiService.modelAPIKeys.removeValue(forKey: oldName)
            aiService.modelEndpoints.removeValue(forKey: oldName)
        }

        // Add or update model
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

        selectedModelName = modelName
        validationStatus = .notChecked
    }
}

// MARK: - Anthropic Configuration View

struct AnthropicConfigurationView: View {
    @ObservedObject private var aiService = AIService.shared
    @Binding var tempModelName: String
    @Binding var tempAPIKey: String
    @Binding var tempEndpoint: String
    @Binding var showAPIKey: Bool
    @Binding var selectedModelName: String?
    @Binding var validationStatus: APISettingsView.ValidationStatus

    @State private var isValidating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Anthropic Configuration")
                .font(Typography.headline)
                .foregroundStyle(.primary)

            // Fields card (matching OpenAI style)
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Model Name
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

                // Custom Endpoint (Optional)
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
                    TextField("https://api.anthropic.com", text: $tempEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempEndpoint) { _, _ in
                            validationStatus = .notChecked
                        }
                    Text("Leave empty for the default Anthropic API. Enter a custom URL for proxies or Azure.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                // API Key
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
                                .frame(width: 32, height: 32)
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
            }
            .padding(Spacing.lg)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))

            // Action Buttons (outside the card, matching OpenAI)
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
                    // Update existing model
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
                    // Add new model
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

            // Validation Status Section (matching OpenAI style)
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

        // Validate endpoint URL if provided
        if !endpoint.isEmpty {
            do {
                _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: endpoint)
            } catch {
                validationStatus = .invalid("Invalid endpoint: \(error.localizedDescription)")
                isValidating = false
                return
            }
        }

        // Test the API with a minimal request
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
                // Try to parse error message
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

        // Remove old model if updating
        if let oldName = selectedModelName, oldName != modelName {
            aiService.customModels.removeAll { $0 == oldName }
            aiService.modelProviders.removeValue(forKey: oldName)
            aiService.modelAPIKeys.removeValue(forKey: oldName)
            aiService.modelEndpoints.removeValue(forKey: oldName)
        }

        // Add or update model
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

        selectedModelName = modelName
        validationStatus = .notChecked
    }
}

// MARK: - GitHub Account View

// Removed as it is now integrated into GitHubModelsConfigurationView

#Preview {
    MacSettingsView()
}

// swiftlint:enable file_length type_body_length
