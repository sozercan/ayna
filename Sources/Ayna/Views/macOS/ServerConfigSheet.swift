#if os(macOS)
//
//  ServerConfigSheet.swift
//  ayna
//
//  Created on 11/3/25.
//

import Foundation
import SwiftUI

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
                    .font(Typography.title2)
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
                        envVars
                            .filter { !$0.key.isEmpty }
                            .map { ($0.key, $0.value) },
                        uniquingKeysWith: { _, last in last }
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
#endif
