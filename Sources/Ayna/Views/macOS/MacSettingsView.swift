// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

// swiftlint:disable file_length

struct MacSettingsView: View {
    @ObservedObject private var aiService = AIService.shared
    @ObservedObject private var settingsRouter = SettingsRouter.shared
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
                    Label("Agents", systemImage: "brain")
                }
                .tag(SettingsTab.agents)

            MemorySettingsSection()
                .tabItem {
                    Label("Memory", systemImage: "memorychip")
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

                if aiService.hasImageModelWithOutputOptions {
                    Picker("Output Format", selection: $aiService.outputFormat) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpeg")
                    }
                    .help("Image file format (GPT Image models)")

                    if aiService.outputFormat != "png" {
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
                        .help("JPEG compression level (100 = no compression)")
                    }
                }
            } header: {
                Text("Image Generation")
            } footer: {
                Text("These settings apply when using image generation models")
                    .font(Typography.caption)
            }

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

struct WebSearchSettingsSection: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @State private var showAPIKey = false

    var body: some View {
        Section {
            Toggle("Enable Web Search", isOn: $tavilyService.isEnabled)
                .help("Allow models to search the web for current information")
                .accessibilityIdentifier("settings.webSearch.enableToggle")

            if tavilyService.isEnabled {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: tavilyService.isConfigured ? "bolt.fill" : "magnifyingglass")
                        .foregroundStyle(Theme.accent)
                        .font(Typography.caption)
                    Text("Using: \(tavilyService.isConfigured ? "Tavily" : "DuckDuckGo")")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

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
                            Text("Optional")
                                .font(Typography.micro)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, Spacing.xxxs)
                                .background(Color.secondary.opacity(0.1))
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
                                .frame(width: Spacing.Component.avatarSmall, height: Spacing.Component.avatarSmall)
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
            Text("Web search works without an API key using DuckDuckGo. For higher quality results with AI-generated answers, configure a Tavily API key.")
                .font(Typography.caption)
        }
    }
}

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
                        do {
                            try GlobalHotkeyService.shared.registerSaved()
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
                        GlobalHotkeyService.shared.unregister()
                        AccessibilityService.shared.stopMonitoring()
                    }
                }

            if isEnabled {
                LabeledContent("Hotkey") {
                    HotkeyRecorderView()
                }
                .accessibilityIdentifier("settings.attachFromApp.hotkey")

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
            Text("Press the hotkey anywhere to capture content from the focused app and ask questions about it. Requires Accessibility permission.")
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

struct ToolsSettingsView: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @StateObject private var mcpManager = MCPServerManager.shared
    @Bindable private var agentSettings = AgentSettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Tools")
                        .font(Typography.title2)
                        .fontWeight(.semibold)

                    let webSearchCount = tavilyService.isEnabled ? 1 : 0
                    let agenticToolCount = agentSettings.settings.isEnabled ? BuiltinToolService.toolNames.count : 0
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

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
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

                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text("Agentic Tools")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.textSecondary)

                        AgenticToolsRow()
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

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
        .accessibilityIdentifier("settings.tools.view")
    }
}

struct WebSearchToolRow: View {
    @ObservedObject private var tavilyService = TavilyService.shared
    @State private var isExpanded = false
    @State private var showAPIKey = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("", isOn: $tavilyService.isEnabled)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.tools.webSearch.toggle")

                Circle()
                    .fill(statusColor)
                    .frame(width: Spacing.Component.statusDot, height: Spacing.Component.statusDot)

                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("Web Search")
                        .font(Typography.headline)

                    HStack(spacing: Spacing.xxs) {
                        Text(statusDescription)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)

                        if tavilyService.isEnabled {
                            Text("•")
                                .foregroundStyle(Theme.textSecondary)
                            Text("1 tool")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }

                Spacer()

                Menu {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(isExpanded ? "Hide Settings" : "Configure", systemImage: "gear")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
            }
            .padding()

            if isExpanded, tavilyService.isEnabled {
                Divider()
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: tavilyService.isConfigured ? "bolt.fill" : "magnifyingglass")
                            .foregroundStyle(Theme.accent)
                            .font(Typography.caption)
                        Text("Using: \(tavilyService.isConfigured ? "Tavily" : "DuckDuckGo")")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    HStack {
                        Text("Tavily API Key")
                            .font(Typography.subheadline)
                        Spacer()
                        if tavilyService.isConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.statusConnected)
                                .font(Typography.caption)
                        } else {
                            Text("Optional")
                                .font(Typography.micro)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, Spacing.xxxs)
                                .background(Color.secondary.opacity(0.1))
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
                                .frame(width: Spacing.Component.avatarSmall, height: Spacing.Component.avatarSmall)
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

                    Text("Web search works without an API key using DuckDuckGo. Add a Tavily key for higher quality results.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
            }
        }
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
    }

    private var statusColor: Color {
        if !tavilyService.isEnabled {
            Theme.statusDisconnected
        } else {
            Theme.statusConnected
        }
    }

    private var statusDescription: String {
        if !tavilyService.isEnabled {
            "Disabled"
        } else if tavilyService.isConfigured {
            "Tavily"
        } else {
            "DuckDuckGo"
        }
    }
}

struct AgenticToolsRow: View {
    @Bindable private var agentSettings = AgentSettingsStore.shared

    var body: some View {
        HStack {
            Toggle("", isOn: $agentSettings.settings.isEnabled)
                .labelsHidden()
                .accessibilityIdentifier("settings.tools.agentic.toggle")

            Circle()
                .fill(statusColor)
                .frame(width: Spacing.Component.statusDot, height: Spacing.Component.statusDot)

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
                        Text("\(BuiltinToolService.toolNames.count) tools")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            Spacer()

            Menu {
                Button {
                    SettingsRouter.shared.route(to: .agents)
                } label: {
                    Label("Configure", systemImage: "gear")
                }
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
        agentSettings.settings.isEnabled ? Theme.statusConnected : Theme.statusDisconnected
    }

    private var statusDescription: String {
        agentSettings.settings.isEnabled ? "Enabled" : "Disabled"
    }
}

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
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { _, _ in
                    onToggle()
                }

            Circle()
                .fill(statusColor)
                .frame(width: Spacing.Component.statusDot, height: Spacing.Component.statusDot)

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
                                            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

                                            if !modelName.isEmpty {
                                                if selectedName != modelName {
                                                    aiService.customModels.removeAll { $0 == selectedName }
                                                    aiService.modelProviders.removeValue(forKey: selectedName)
                                                    aiService.modelAPIKeys.removeValue(forKey: selectedName)
                                                    aiService.modelEndpoints.removeValue(forKey: selectedName)
                                                    aiService.modelEndpointTypes.removeValue(forKey: selectedName)

                                                    if !aiService.customModels.contains(modelName) {
                                                        aiService.customModels.append(modelName)
                                                    }

                                                    if aiService.selectedModel == selectedName {
                                                        aiService.selectedModel = modelName
                                                    }
                                                }

                                                aiService.modelProviders[modelName] = .openai
                                                aiService.modelEndpointTypes[modelName] = tempEndpointType

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
                                            let modelName = tempModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let endpoint = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let apiKey = tempAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

                                            if !modelName.isEmpty, !aiService.customModels.contains(modelName) {
                                                aiService.customModels.append(modelName)
                                                aiService.modelProviders[modelName] = .openai
                                                aiService.modelEndpointTypes[modelName] = tempEndpointType

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
                        } else if aiService.provider == .anthropic {
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

                        if aiService.provider != .appleIntelligence, aiService.provider != .anthropic {
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
            }
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

    private func createNewModel() {
        selectedModelName = nil
        tempModelName = ""
        tempAPIKey = ""
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
        if let modelProvider = aiService.modelProviders[model] {
            aiService.provider = modelProvider
        }

        tempModelName = model
        tempAPIKey = aiService.modelAPIKeys[model] ?? ""
        tempEndpointType = aiService.modelEndpointTypes[model] ?? .chatCompletions

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

        selectedModelName = newName
        loadModelConfig(newName)
    }
}

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
                    TextField("claude-sonnet-4-20250514", text: $tempModelName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempModelName) { _, _ in
                            validationStatus = .notChecked
                        }
                    Text("Claude model identifier (e.g., claude-sonnet-4-20250514, claude-opus-4-20250514)")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

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
                    TextField("https://api.anthropic.com or http://localhost:8000", text: $tempEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tempEndpoint) { _, _ in
                            validationStatus = .notChecked
                        }
                    Text("Leave empty for the default Anthropic API. Enter a custom HTTPS URL for proxies or Azure; HTTP is only allowed for localhost development.")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

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
                    Text("Your Anthropic API key (stored securely)")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Spacing.lg)
            .background(Theme.backgroundSecondary)
            .clipShape(.rect(cornerRadius: Spacing.CornerRadius.md))

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

        if !endpoint.isEmpty {
            do {
                _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: endpoint)
            } catch {
                validationStatus = .invalid("Invalid endpoint: \(error.localizedDescription)")
                isValidating = false
                return
            }
        }

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

        if let oldName = selectedModelName, oldName != modelName {
            aiService.customModels.removeAll { $0 == oldName }
            aiService.modelProviders.removeValue(forKey: oldName)
            aiService.modelAPIKeys.removeValue(forKey: oldName)
            aiService.modelEndpoints.removeValue(forKey: oldName)
            aiService.modelEndpointTypes.removeValue(forKey: oldName)
        }

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

#Preview {
    MacSettingsView()
}

#endif
