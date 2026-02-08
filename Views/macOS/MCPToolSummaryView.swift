//
//  MCPToolSummaryView.swift
//  ayna
//
//  Created on 11/20/25.
//

import SwiftUI

@MainActor
struct MCPToolSummaryView: View {
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @ObservedObject private var tavilyService = TavilyService.shared
    private var agentSettingsStore = AgentSettingsStore.shared
    @Binding var isExpanded: Bool

    init(isExpanded: Binding<Bool>) {
        _isExpanded = isExpanded
    }

    @MainActor var body: some View {
        if shouldShowToolSummary {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if isExpanded {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.sm) {
                            Button {
                                withAnimation(Motion.easeStandard) {
                                    isExpanded = false
                                }
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Label("Tools", systemImage: "wrench.and.screwdriver")
                                        .font(Typography.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: Typography.Size.xs))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Collapse tools")

                            Spacer()

                            SettingsLink {
                                Label("Manage", systemImage: "slider.horizontal.3")
                                    .font(.system(size: Typography.Size.xs))
                            }
                            .routeSettings(to: .mcp)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.sm) {
                                // Agentic Tools chip - always show
                                Button {
                                    agentSettingsStore.settings.isEnabled.toggle()
                                } label: {
                                    AgenticToolsChip(
                                        isEnabled: agentSettingsStore.settings.isEnabled,
                                        toolCount: 6
                                    )
                                }
                                .buttonStyle(.plain)

                                // Web Search chip - always show if configured
                                if tavilyService.isConfigured {
                                    Button {
                                        tavilyService.isEnabled.toggle()
                                    } label: {
                                        WebSearchChip(isEnabled: tavilyService.isEnabled, isConfigured: tavilyService.isConfigured)
                                    }
                                    .buttonStyle(.plain)
                                }

                                // MCP Server chips
                                ForEach(toolStatusChipModels) { chip in
                                    Button {
                                        toggleServer(chip.id)
                                    } label: {
                                        ToolStatusChip(model: chip)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.easeStandard) {
                            isExpanded = false
                        }
                    }
                } else if !toolSummaryText.isEmpty {
                    Button {
                        withAnimation(Motion.easeStandard) {
                            isExpanded = true
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Label("Tools", systemImage: "wrench.and.screwdriver")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Text("•")
                                .foregroundStyle(Theme.textTertiary)
                            Text(toolSummaryText)
                                .font(.system(size: Typography.Size.xs))
                                .foregroundStyle(toolSummaryColor)
                            Spacer(minLength: Spacing.xxs)
                            Image(systemName: "chevron.up")
                                .font(.system(size: Typography.Size.xs))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand tools")
                }
            }
            .padding(.horizontal, Spacing.contentPadding)
        }
    }

    private func toggleServer(_ id: UUID) {
        guard let config = mcpManager.serverConfigs.first(where: { $0.id == id }) else { return }
        var updatedConfig = config
        updatedConfig.enabled.toggle()
        mcpManager.updateServerConfig(updatedConfig)
    }

    private var shouldShowToolSummary: Bool {
        // Always show since agentic tools are always available
        true
    }

    private var toolStatusChipModels: [ToolStatusChipModel] {
        mcpManager.serverConfigs.map { config in
            let status = mcpManager.getServerStatus(config.name)
            return ToolStatusChipModel(
                id: config.id,
                name: config.name,
                statusText: statusDescription(isEnabled: config.enabled, state: status?.state),
                statusColor: statusColor(isEnabled: config.enabled, state: status?.state),
                toolsCount: max(0, status?.toolsCount ?? 0),
                lastError: status?.lastError,
                isEnabled: config.enabled,
                state: status?.state,
                hasTools: (status?.toolsCount ?? 0) > 0
            )
        }
    }

    private var enabledServerCount: Int {
        toolStatusChipModels.count(where: { $0.isEnabled })
    }

    private var connectedServerCount: Int {
        toolStatusChipModels.count(where: { $0.state?.isConnected ?? false })
    }

    private var readyToolCount: Int {
        var count = toolStatusChipModels
            .filter { $0.state?.isConnected ?? false }
            .reduce(0) { $0 + $1.toolsCount }

        // Add web search tool if configured
        if tavilyService.isEnabled, tavilyService.isConfigured {
            count += 1
        }

        // Add agentic tools if enabled (6 tools)
        if agentSettingsStore.settings.isEnabled {
            count += 6
        }

        return count
    }

    private var toolSummaryText: String {
        guard shouldShowToolSummary else { return "" }

        // Check if no MCP servers configured
        if mcpManager.serverConfigs.isEmpty {
            // Build list of available tools
            var sources: [String] = []
            if agentSettingsStore.settings.isEnabled {
                sources.append("Agentic")
            }
            if tavilyService.isEnabled, tavilyService.isConfigured {
                sources.append("Web Search")
            } else if tavilyService.isEnabled {
                return "Web Search needs API key • \(readyToolCount) tool\(readyToolCount == 1 ? "" : "s") ready"
            }

            if readyToolCount > 0 {
                return "\(readyToolCount) tool\(readyToolCount == 1 ? "" : "s") ready"
            }
            return "All tools are disabled."
        }

        let allDisabled = enabledServerCount == 0 && !tavilyService.isEnabled && !agentSettingsStore.settings.isEnabled
        if allDisabled {
            return "All tools are disabled."
        }

        if connectedServerCount == 0, enabledServerCount > 0 {
            return
                "Waiting for \(enabledServerCount) enabled server\(enabledServerCount == 1 ? "" : "s") to connect…"
        }

        var summary = "\(readyToolCount) tool\(readyToolCount == 1 ? "" : "s") ready"
        if toolStatusChipModels.contains(where: { $0.state?.isError ?? false }) {
            summary += " • Issues detected"
        }
        return summary
    }

    private var toolSummaryColor: Color {
        if toolStatusChipModels.contains(where: { $0.state?.isError ?? false }) {
            return .orange
        }

        if tavilyService.isEnabled, !tavilyService.isConfigured {
            return .orange
        }

        if connectedServerCount == 0, enabledServerCount > 0 {
            return .orange
        }

        if readyToolCount > 0 {
            return .green
        }

        return .secondary
    }

    private func statusDescription(isEnabled: Bool, state: MCPServerStatus.State?) -> String {
        guard isEnabled else { return "Disabled" }

        switch state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .reconnecting:
            return "Reconnecting"
        case .error:
            return "Error"
        case .idle:
            return "Idle"
        case .disabled:
            return "Disabled"
        case .none:
            return "Idle"
        }
    }

    private func statusColor(isEnabled: Bool, state: MCPServerStatus.State?) -> Color {
        guard isEnabled else { return Theme.statusDisconnected }

        switch state {
        case .connected:
            return Theme.statusConnected
        case .connecting:
            return Theme.statusConnecting
        case .reconnecting:
            return .yellow
        case .error:
            return Theme.statusError
        case .idle:
            return Theme.textSecondary
        case .disabled:
            return Theme.statusDisconnected
        case .none:
            return Theme.textSecondary
        }
    }
}

/// Chip for Web Search tool status
@MainActor
struct WebSearchChip: View {
    let isEnabled: Bool
    let isConfigured: Bool

    var statusColor: Color {
        if !isEnabled {
            return Theme.statusDisconnected
        }
        return isConfigured ? Theme.statusConnected : Theme.statusConnecting
    }

    var statusText: String {
        if !isEnabled {
            return "Disabled"
        }
        return isConfigured ? "Configured" : "API key required"
    }

    @MainActor var body: some View {
        HStack(spacing: Spacing.lg) {
            Circle()
                .fill(statusColor)
                .frame(width: Spacing.Component.statusDot, height: Spacing.Component.statusDot)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Web Search")
                    .font(Typography.caption)
                    .fontWeight(.semibold)

                HStack(spacing: Spacing.xs) {
                    Text(statusText)
                        .font(.system(size: Typography.Size.xs))
                        .foregroundStyle(statusColor)

                    if isEnabled, isConfigured {
                        Text("1 tool")
                            .font(.system(size: Typography.Size.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg)
                .stroke(statusColor.opacity(0.25), lineWidth: Spacing.Border.standard)
        )
    }
}

/// Chip for Agentic Tools status
@MainActor
struct AgenticToolsChip: View {
    let isEnabled: Bool
    let toolCount: Int

    var statusColor: Color {
        isEnabled ? Theme.statusConnected : Theme.statusDisconnected
    }

    var statusText: String {
        isEnabled ? "Ready" : "Disabled"
    }

    @MainActor var body: some View {
        HStack(spacing: Spacing.lg) {
            Circle()
                .fill(statusColor)
                .frame(width: Spacing.Component.statusDot, height: Spacing.Component.statusDot)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Agentic Tools")
                    .font(Typography.caption)
                    .fontWeight(.semibold)

                HStack(spacing: Spacing.xs) {
                    Text(statusText)
                        .font(.system(size: Typography.Size.xs))
                        .foregroundStyle(statusColor)

                    if isEnabled {
                        Text("\(toolCount) tools")
                            .font(.system(size: Typography.Size.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg)
                .stroke(statusColor.opacity(0.25), lineWidth: Spacing.Border.standard)
        )
    }
}

struct ToolStatusChipModel: Identifiable {
    let id: UUID
    let name: String
    let statusText: String
    let statusColor: Color
    let toolsCount: Int
    let lastError: String?
    let isEnabled: Bool
    let state: MCPServerStatus.State?
    let hasTools: Bool
}

@MainActor
struct ToolStatusChip: View {
    let model: ToolStatusChipModel

    @MainActor var body: some View {
        HStack(spacing: Spacing.lg) {
            Circle()
                .fill(model.statusColor)
                .frame(width: Spacing.Component.statusDot, height: Spacing.Component.statusDot)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(model.name)
                    .font(Typography.caption)
                    .fontWeight(.semibold)

                HStack(spacing: Spacing.xs) {
                    Text(model.statusText)
                        .font(.system(size: Typography.Size.xs))
                        .foregroundStyle(model.statusColor)

                    if model.toolsCount > 0 {
                        Text("\(model.toolsCount) tool\(model.toolsCount == 1 ? "" : "s")")
                            .font(.system(size: Typography.Size.xs))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            if let error = model.lastError, !error.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Typography.Size.xs))
                    .foregroundStyle(Theme.statusConnecting)
                    .help(error)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.CornerRadius.lg)
                .stroke(model.statusColor.opacity(0.25), lineWidth: Spacing.Border.standard)
        )
    }
}

extension MCPServerStatus.State {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
