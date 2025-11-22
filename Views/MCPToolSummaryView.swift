//
//  MCPToolSummaryView.swift
//  ayna
//
//  Created on 11/20/25.
//

import SwiftUI

struct MCPToolSummaryView: View {
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @State private var isToolSectionExpanded = false

    var body: some View {
        if shouldShowToolSummary {
            VStack(alignment: .leading, spacing: 8) {
                if isToolSectionExpanded {
                    HStack(spacing: 8) {
                        Label("MCP Tools", systemImage: "wrench.and.screwdriver")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        SettingsLink {
                            Label("Manage", systemImage: "slider.horizontal.3")
                                .font(.caption2)
                        }
                        .routeSettings(to: .mcp)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isToolSectionExpanded = false
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Collapse MCP tools")
                    }

                    if toolStatusChipModels.isEmpty {
                        Text("Waiting for MCP servers…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
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
                } else if !toolSummaryText.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isToolSectionExpanded = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(toolSummaryText)
                                .font(.caption2)
                                .foregroundStyle(toolSummaryColor)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand MCP tools")
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
        !mcpManager.serverConfigs.isEmpty
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
        toolStatusChipModels
            .filter { $0.state?.isConnected ?? false }
            .reduce(0) { $0 + $1.toolsCount }
    }

    private var toolSummaryText: String {
        guard shouldShowToolSummary else { return "" }

        if enabledServerCount == 0 {
            return "All MCP servers are disabled."
        }

        if connectedServerCount == 0 {
            return
                "Waiting for \(enabledServerCount) enabled server\(enabledServerCount == 1 ? "" : "s") to connect…"
        }

        var summary =
            "\(connectedServerCount) connected • \(readyToolCount) tool\(readyToolCount == 1 ? "" : "s") ready"
        if toolStatusChipModels.contains(where: { $0.state?.isError ?? false }) {
            summary += " • Issues detected"
        }
        return summary
    }

    private var toolSummaryColor: Color {
        if toolStatusChipModels.contains(where: { $0.state?.isError ?? false }) {
            return .orange
        }

        if connectedServerCount == 0 {
            return enabledServerCount == 0 ? .secondary : .orange
        }
        return .green
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

struct ToolStatusChip: View {
    let model: ToolStatusChipModel

    var body: some View {
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
