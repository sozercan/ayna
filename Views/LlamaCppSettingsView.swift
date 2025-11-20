//
//  LlamaCppSettingsView.swift
//  ayna
//
//  Created on 11/19/25.
//

import SwiftUI

struct LlamaCppSettingsView: View {
    @ObservedObject private var service = LlamaCppService.shared
    @State private var newModelURL: String = ""
    @Binding var modelName: String
    @Binding var selectedGGUF: String?

    init(modelName: Binding<String> = .constant(""), selectedGGUF: Binding<String?> = .constant(nil)) {
        _modelName = modelName
        _selectedGGUF = selectedGGUF
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Model Configuration
                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Configuration")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model Name")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("e.g. llama-3-8b", text: $modelName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("GGUF Model File")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if service.availableModels.isEmpty {
                            Text("No models available. Download one below.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else {
                            Picker("", selection: $selectedGGUF) {
                                Text("Select a model...").tag(nil as String?)
                                ForEach(service.availableModels) { model in
                                    Text(model.name).tag(model.name as String?)
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                Divider()

                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Llama.cpp")
                        .font(.headline)
                    Text("Run GGUF models locally with native performance.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Engine Status
                VStack(alignment: .leading, spacing: 12) {
                    Text("Engine")
                        .font(.headline)

                    HStack {
                        LlamaStatusIndicator(status: service.serverStatus)
                        Spacer()

                        if service.serverStatus == .notInstalled {
                            Button("Install Engine") {
                                Task { await service.installServer() }
                            }
                            .disabled(service.isDownloading)
                        } else {
                            if service.serverStatus == .running {
                                Button("Stop Server") {
                                    service.stopServer()
                                }
                                .tint(.red)
                            } else {
                                Button("Start Server") {
                                    service.startServer()
                                }
                                .disabled(service.serverStatus == .installing || service.selectedModel == nil)
                            }

                            Button("Update Engine") {
                                Task { await service.installServer() }
                            }
                            .disabled(service.isDownloading || service.serverStatus == .running)
                        }
                    }

                    if service.isDownloading {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: service.downloadProgress)
                            Text(service.downloadMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !service.serverOutput.isEmpty {
                        DisclosureGroup("Server Logs") {
                            ScrollView {
                                Text(service.serverOutput)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 100)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Models
                VStack(alignment: .leading, spacing: 12) {
                    Text("Models")
                        .font(.headline)

                    if service.availableModels.isEmpty {
                        Text("No models downloaded.")
                            .foregroundStyle(.secondary)
                    } else {
                        List(service.availableModels, selection: $service.selectedModel) { model in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.name)
                                        .font(.body)
                                    Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if service.selectedModel == model.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                Button(role: .destructive) {
                                    service.deleteModel(model)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .tag(model.name)
                        }
                        .frame(height: 150)
                        .listStyle(.bordered)
                    }

                    HStack {
                        TextField("HuggingFace GGUF URL", text: $newModelURL)
                            .textFieldStyle(.roundedBorder)

                        Button("Download") {
                            Task {
                                await service.downloadModel(from: newModelURL)
                                newModelURL = ""
                            }
                        }
                        .disabled(newModelURL.isEmpty || service.isDownloading)
                    }
                    Text("Example: https://huggingface.co/user/repo/resolve/main/model.gguf")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Configuration
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configuration")
                        .font(.headline)

                    Form {
                        TextField("Context Size", value: $service.contextSize, formatter: NumberFormatter())

                        TextField("GPU Layers", value: $service.gpuLayers, formatter: NumberFormatter())

                        TextField("Threads", value: $service.threads, formatter: NumberFormatter())
                    }
                    .disabled(service.serverStatus == .running)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
        }
    }
}

struct LlamaStatusIndicator: View {
    let status: LlamaCppServerStatus

    var color: Color {
        switch status {
        case .running: .green
        case .starting, .installing: .orange
        case .error: .red
        default: .gray
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.rawValue)
                .foregroundStyle(color)
        }
    }
}
