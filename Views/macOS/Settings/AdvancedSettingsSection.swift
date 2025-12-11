//
//  AdvancedSettingsSection.swift
//  ayna
//
//  Extracted from MacSettingsView.swift - MCP tools and advanced settings
//

import SwiftUI

// Note: The MCP and Tools settings views are already well-organized in MacSettingsView.swift
// This file contains additional advanced settings components and utilities

/// Flow layout for arranging views in a wrapping horizontal flow
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
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.frames[index].minX,
                    y: bounds.minY + result.frames[index].minY
                ),
                proposal: .unspecified
            )
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

/// Server configuration sheet for adding/editing MCP servers
struct ServerConfigSheet: View {
    let config: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var arguments: String = ""
    @State private var workingDirectory: String = ""
    @State private var environmentVariables: String = ""
    @State private var enabled: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(config == nil ? "Add MCP Server" : "Edit MCP Server")
                    .font(Typography.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Name
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Server Name")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        TextField("My MCP Server", text: $name)
                            .textFieldStyle(.roundedBorder)
                        Text("A friendly name for this server")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Command
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Command")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        TextField("/usr/local/bin/my-mcp-server", text: $command)
                            .textFieldStyle(.roundedBorder)
                        Text("Full path to the MCP server executable")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Arguments
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Arguments")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        TextField("--port 3000 --verbose", text: $arguments)
                            .textFieldStyle(.roundedBorder)
                        Text("Space-separated command line arguments")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Working Directory
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Working Directory")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        HStack {
                            TextField("~/Projects/my-server", text: $workingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseForDirectory()
                            }
                        }
                        Text("Directory to run the server from (optional)")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Environment Variables
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Environment Variables")
                            .font(Typography.subheadline)
                            .fontWeight(.medium)
                        TextEditor(text: $environmentVariables)
                            .font(Typography.code)
                            .frame(height: 80)
                            .scrollContentBackground(.hidden)
                            .padding(Spacing.xs)
                            .background(Theme.background)
                            .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: Spacing.CornerRadius.sm)
                                    .stroke(Theme.separator, lineWidth: 1)
                            )
                        Text("KEY=value pairs, one per line")
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Enabled Toggle
                    Toggle("Enable server on save", isOn: $enabled)
                }
                .padding()
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveConfig()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 550)
        .onAppear {
            if let config {
                name = config.name
                command = config.command
                arguments = config.arguments.joined(separator: " ")
                workingDirectory = config.workingDirectory ?? ""
                environmentVariables = config.env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                enabled = config.enabled
            }
        }
    }

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func saveConfig() {
        let args = arguments.split(separator: " ").map(String.init)
        var env: [String: String] = [:]

        for line in environmentVariables.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }

        let newConfig = MCPServerConfig(
            name: name,
            command: command,
            arguments: args,
            env: env,
            enabled: enabled,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory
        )

        onSave(newConfig)
    }
}
