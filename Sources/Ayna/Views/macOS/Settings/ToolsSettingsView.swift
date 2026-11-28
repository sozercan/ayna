// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

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
                        status: mcpManager.getServerStatus(config.id),
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

#endif
