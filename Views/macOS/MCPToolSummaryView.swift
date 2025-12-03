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
    @Binding var isExpanded: Bool

    @MainActor var body: some View {
        if shouldShowToolSummary {
            VStack(alignment: .leading, spacing: 4) {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isExpanded = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Label("Tools", systemImage: "wrench.and.screwdriver")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Collapse tools")

                            Spacer()

                            SettingsLink {
                                Label("Manage", systemImage: "slider.horizontal.3")
                                    .font(.caption2)
                            }
                            .routeSettings(to: .mcp)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = false
                        }
                    }
                } else if !toolSummaryText.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Label("Tools", systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text(toolSummaryText)
                                .font(.caption2)
                                .foregroundStyle(toolSummaryColor)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand tools")
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func toggleServer(_ id: UUID) {
        guard let config = mcpManager.serverConfigs.first(where: { $0.id == id }) else { return }
        var updatedConfig = config
        updatedConfig.enabled.toggle()
        mcpManager.updateServerConfig(updatedConfig)
    }

    private var shouldShowToolSummary: Bool {
        !mcpManager.serverConfigs.isEmpty || tavilyService.isConfigured
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
        if tavilyService.isEnabled && tavilyService.isConfigured {
            count += 1
        }

        return count
    }

    private var toolSummaryText: String {
        guard shouldShowToolSummary else { return "" }

        // Check if only web search is available (no MCP servers)
        if mcpManager.serverConfigs.isEmpty {
            if tavilyService.isEnabled && tavilyService.isConfigured {
                return "Web Search ready • 1 tool"
            } else if tavilyService.isEnabled {
                return "Web Search needs API key"
            }
            return ""
        }

        if enabledServerCount == 0 && !tavilyService.isEnabled {
            return "All tools are disabled."
        }

        if connectedServerCount == 0 && enabledServerCount > 0 {
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

        if tavilyService.isEnabled && !tavilyService.isConfigured {
            return .orange
        }

        if connectedServerCount == 0 && enabledServerCount > 0 {
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
        guard isEnabled else { return .gray }

        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .reconnecting:
            return .yellow
        case .error:
            return .red
        case .idle:
            return .secondary
        case .disabled:
            return .gray
        case .none:
            return .secondary
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
            return .gray
        }
        return isConfigured ? .green : .orange
    }

    var statusText: String {
        if !isEnabled {
            return "Disabled"
        }
        return isConfigured ? "Configured" : "API key required"
    }

    @MainActor var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Web Search")
                    .font(.caption)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)

                    if isEnabled && isConfigured {
                        Text("1 tool")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.25), lineWidth: 1)
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
        HStack(spacing: 10) {
            Circle()
                .fill(model.statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.caption)
                    .fontWeight(.semibold)

                HStack(spacing: 6) {
                    Text(model.statusText)
                        .font(.caption2)
                        .foregroundStyle(model.statusColor)

                    if model.toolsCount > 0 {
                        Text("\(model.toolsCount) tool\(model.toolsCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = model.lastError, !error.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(model.statusColor.opacity(0.25), lineWidth: 1)
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
