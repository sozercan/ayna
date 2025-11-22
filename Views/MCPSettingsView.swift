//
//  MCPSettingsView.swift
//  ayna
//
//  Created on 11/3/25.
//

import Foundation
import SwiftUI

struct MCPSettingsView: View {
    @StateObject private var mcpManager = MCPServerManager.shared
    @State private var showingAddServer = false
    @State private var editingServer: MCPServerConfig?

    var body: some View {
        VStack(spacing: 0) {
            // Header with stats
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP Servers")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("\(mcpManager.getConnectedServerCount()) connected • \(mcpManager.availableTools.count) tools available")
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

                Button(action: {
                    showingAddServer = true
                }) {
                    Label("Add Server", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            // Server List
            if mcpManager.serverConfigs.isEmpty {
                VStack(spacing: 12) {
                    Spacer()

                    Image(systemName: "server.rack")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("No MCP Servers")
                        .font(.headline)

                    Text("Add an MCP server to enable tools like search and file access")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Add Your First Server") {
                        showingAddServer = true
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(mcpManager.serverConfigs) { config in
                            ServerConfigRow(
                                config: config,
                                status: mcpManager.getServerStatus(config.name),
                                tools: mcpManager.availableTools.filter { $0.serverName == config.name },
                                onEdit: {
                                    editingServer = config
                                },
                                onDelete: {
                                    mcpManager.removeServerConfig(config)
                                },
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
                    }
                    .padding()
                }
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

// MARK: - Server Config Row

struct ServerConfigRow: View {
    let config: MCPServerConfig
    let status: MCPServerStatus?
    let tools: [MCPTool]
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void
    let onRetry: () -> Void

    @State private var showingTools = false
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(config.name)
                    .font(.headline)

                Text(statusDescription)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())

                Spacer()

                // Tool count badge
                if !tools.isEmpty {
                    Text("\(tools.count) tools")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }

                // Toggle
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .onChange(of: isEnabled) { _, _ in
                        onToggle()
                    }

                // Actions
                Menu {
                    Button("Edit") {
                        onEdit()
                    }

                    if canRetry {
                        Button("Retry Connection") {
                            onRetry()
                        }
                    }

                    if !tools.isEmpty {
                        Button("Show Tools") {
                            showingTools.toggle()
                        }
                    }

                    Divider()

                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }

            // Command
            HStack {
                Text(config.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                if !config.args.isEmpty {
                    Text(config.args.joined(separator: " "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let lastUpdatedText {
                Text("Updated \(lastUpdatedText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Error message
            if let errorMessage = status?.lastError, !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)

                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Tools list (expandable)
            if showingTools, !tools.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Available Tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(tools) { tool in
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)

                            Text(tool.name)
                                .font(.caption)

                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch status?.state {
        case .connected:
            .green
        case .connecting:
            .orange
        case .reconnecting:
            .yellow
        case .error:
            .red
        case .disabled:
            .gray
        case .idle:
            .secondary
        case .none:
            config.enabled ? .secondary : .gray
        }
    }

    private var statusDescription: String {
        switch status?.state {
        case .connected:
            "Connected"
        case .connecting:
            "Connecting"
        case .reconnecting:
            "Reconnecting"
        case .error:
            "Error"
        case .disabled:
            "Disabled"
        case .idle:
            "Idle"
        case .none:
            config.enabled ? "Idle" : "Disabled"
        }
    }

    private var lastUpdatedText: String? {
        guard let lastUpdated = status?.lastUpdated else { return nil }
        return Self.relativeFormatter.localizedString(for: lastUpdated, relativeTo: Date())
    }

    private var canRetry: Bool {
        guard config.enabled else { return false }
        switch status?.state {
        case .connected, .connecting, .reconnecting:
            return false
        case .disabled:
            return false
        default:
            return true
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

// MARK: - Server Config Sheet

struct ServerConfigSheet: View {
    let config: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var command: String
    @State private var args: String
    @State private var envVars: [EnvVar]

    init(config: MCPServerConfig?, onSave: @escaping (MCPServerConfig) -> Void, onCancel: @escaping () -> Void) {
        self.config = config
        self.onSave = onSave
        self.onCancel = onCancel

        _name = State(initialValue: config?.name ?? "")
        _command = State(initialValue: config?.command ?? "npx")
        _args = State(initialValue: config?.args.joined(separator: " ") ?? "")
        _envVars = State(initialValue: config?.env.map { EnvVar(key: $0.key, value: $0.value) } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(config == nil ? "Add MCP Server" : "Edit MCP Server")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
            }
            .padding()

            Divider()

            // Form
            Form {
                Section {
                    TextField("Server Name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    TextField("Command", text: $command)
                        .textFieldStyle(.roundedBorder)

                    TextField("Arguments", text: $args)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Basic Configuration")
                }

                Section {
                    ForEach($envVars) { $envVar in
                        HStack {
                            TextField("Key", text: $envVar.key)
                                .textFieldStyle(.roundedBorder)

                            TextField("Value", text: $envVar.value)
                                .textFieldStyle(.roundedBorder)

                            Button(action: {
                                envVars.removeAll { $0.id == envVar.id }
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("Add Environment Variable") {
                        envVars.append(EnvVar(key: "", value: ""))
                    }
                } header: {
                    Text("Environment Variables")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            // Footer
            HStack {
                Spacer()

                Button("Save") {
                    let argsArray = args
                        .split(separator: " ")
                        .map { String($0) }
                        .filter { !$0.isEmpty }

                    let envDict = Dictionary(
                        uniqueKeysWithValues: envVars
                            .filter { !$0.key.isEmpty }
                            .map { ($0.key, $0.value) }
                    )

                    let newConfig = MCPServerConfig(
                        id: config?.id ?? UUID(),
                        name: name,
                        command: command,
                        args: argsArray,
                        env: envDict,
                        enabled: config?.enabled ?? true
                    )

                    onSave(newConfig)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || command.isEmpty)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
}

// MARK: - Helper Types

struct EnvVar: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

// MARK: - Preview

#Preview {
    MCPSettingsView()
}
