//
//  AgentsSettingsSection.swift
//  Ayna
//
//  Settings UI for native agentic tools configuration.
//

import SwiftUI

/// Settings section for agentic tools configuration
struct AgentsSettingsSection: View {
    @Bindable private var settingsStore = AgentSettingsStore.shared

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            // Enable/Disable Section
            Section {
                Toggle("Enable Agentic Tools", isOn: $settingsStore.settings.isEnabled)
                    .help("Allow AI to read files, write code, and run commands")
            } header: {
                Text("Agentic Mode")
            } footer: {
                Text("When enabled, the AI can use tools to interact with your filesystem and execute commands.")
                    .foregroundStyle(.secondary)
            }

            // Permission Settings
            Section("Default Permissions") {
                permissionPicker(for: "read_file", label: "Read Files")
                permissionPicker(for: "write_file", label: "Write Files")
                permissionPicker(for: "edit_file", label: "Edit Files")
                permissionPicker(for: "list_directory", label: "List Directories")
                permissionPicker(for: "search_files", label: "Search Files")
                permissionPicker(for: "run_command", label: "Run Commands")
            }

            // Safety Settings
            Section("Safety") {
                Toggle(
                    "Require approval outside project",
                    isOn: $settingsStore.settings.requireApprovalOutsideProject
                )
                .help("Always ask before modifying files outside the current project")

                Stepper(
                    "Max tool chain depth: \(settingsStore.settings.maxToolChainDepth)",
                    value: $settingsStore.settings.maxToolChainDepth,
                    in: 5 ... 50
                )
                .help("Maximum consecutive tool calls before requiring user confirmation")

                Picker("Command timeout", selection: $settingsStore.settings.commandTimeoutSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                    Text("5 minutes").tag(300)
                }
                .help("Maximum time a single command can run")
            }

            // Approval Settings
            Section("Approval Behavior") {
                Toggle(
                    "Remember approvals across sessions",
                    isOn: $settingsStore.settings.persistApprovals
                )
                .help("Remember approved operations for next session")

                Picker("Approval timeout", selection: $settingsStore.settings.approvalTimeoutSeconds) {
                    Text("No timeout").tag(0)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                }
                .help("Auto-deny pending approvals after this time")
            }

            // Project Settings
            Section("Project") {
                HStack {
                    Text("Project Root")
                    Spacer()
                    if let path = settingsStore.settings.projectRootPath {
                        Text(path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Auto-detect")
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose...") {
                        chooseProjectRoot()
                    }
                    if settingsStore.settings.projectRootPath != nil {
                        Button("Clear") {
                            settingsStore.settings.projectRootPath = nil
                        }
                    }
                }
            }

            // Reset
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
                .confirmationDialog(
                    "Reset Agentic Settings?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        settingsStore.resetToDefaults()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will reset all agentic tool settings to their defaults.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agentic Tools")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func permissionPicker(for tool: String, label: String) -> some View {
        let binding = Binding<PermissionLevel>(
            get: { settingsStore.settings.permissionLevel(for: tool) },
            set: { settingsStore.settings.setPermissionLevel($0, for: tool) }
        )

        Picker(label, selection: binding) {
            ForEach(PermissionLevel.allCases, id: \.self) { level in
                Text(level.displayName)
                    .tag(level)
            }
        }
        .help(permissionHelp(for: tool))
    }

    private func permissionHelp(for tool: String) -> String {
        switch tool {
        case "read_file":
            "Permission level for reading file contents"
        case "write_file":
            "Permission level for creating or overwriting files"
        case "edit_file":
            "Permission level for modifying existing files"
        case "list_directory":
            "Permission level for listing directory contents"
        case "search_files":
            "Permission level for searching file contents"
        case "run_command":
            "Permission level for executing shell commands"
        default:
            "Permission level for this tool"
        }
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project Root"
        panel.message = "Select the root directory for your project"

        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.projectRootPath = url.path
        }
    }
}

// MARK: - Preview

#Preview {
    AgentsSettingsSection()
        .frame(width: 500, height: 600)
}
