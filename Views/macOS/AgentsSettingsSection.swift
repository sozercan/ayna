//
//  AgentsSettingsSection.swift
//  ayna
//

import SwiftUI

/// Settings section for configuring agentic tool capabilities
struct AgentsSettingsSection: View {
    @Bindable private var agentSettings = AgentSettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Agents")
                        .font(Typography.title2)
                        .fontWeight(.semibold)

                    Text("Configure agentic tool capabilities")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Enable/Disable toggle
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Toggle(isOn: $agentSettings.settings.isEnabled) {
                            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                Text("Enable Agentic Tools")
                                    .font(Typography.headline)
                                Text("Allow AI models to read files, edit code, search, and run commands")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    .padding()
                    .background(Theme.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))

                    if agentSettings.settings.isEnabled {
                        // Tool chain depth
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("Tool Chain Depth")
                                .font(Typography.headline)

                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack {
                                    Text("Maximum consecutive tool calls:")
                                        .font(Typography.subheadline)
                                    Spacer()
                                    Text("\(agentSettings.settings.maxToolChainDepth)")
                                        .font(Typography.subheadline)
                                        .monospacedDigit()
                                }

                                Slider(
                                    value: Binding(
                                        get: { Double(agentSettings.settings.maxToolChainDepth) },
                                        set: { agentSettings.settings.maxToolChainDepth = Int($0) }
                                    ),
                                    in: 1...50,
                                    step: 1
                                )

                                Text(
                                    "Limits how many tools the model can chain together in a single response. Higher values allow more complex workflows but increase risk of runaway chains."
                                )
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding()
                        .background(Theme.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))

                        // Available tools info
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("Available Tools")
                                .font(Typography.headline)

                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                ToolInfoRow(icon: "doc.text", name: "read_file", description: "Read file contents")
                                ToolInfoRow(
                                    icon: "doc.badge.plus", name: "write_file",
                                    description: "Create or overwrite files")
                                ToolInfoRow(
                                    icon: "pencil.line", name: "edit_file",
                                    description: "Make targeted edits to files")
                                ToolInfoRow(
                                    icon: "folder", name: "list_directory",
                                    description: "List directory contents")
                                ToolInfoRow(
                                    icon: "magnifyingglass", name: "search_files",
                                    description: "Search for patterns in files")
                                ToolInfoRow(
                                    icon: "terminal", name: "run_command",
                                    description: "Execute shell commands")
                            }
                        }
                        .padding()
                        .background(Theme.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Spacing.CornerRadius.md))
                    }
                }
                .padding()
            }
        }
        .accessibilityIdentifier("settings.agents.view")
    }
}

private struct ToolInfoRow: View {
    let icon: String
    let name: String
    let description: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(name)
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
