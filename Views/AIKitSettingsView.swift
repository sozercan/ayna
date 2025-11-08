//
//  AIKitSettingsView.swift
//  ayna
//
//  Created on 11/6/25.
//

import SwiftUI

struct AIKitSettingsView: View {
  @StateObject private var aikitService = AIKitService.shared
  @State private var isPulling = false
  @State private var isRunning = false
  @State private var isStopping = false
  @State private var errorMessage: String?
  @State private var showDeleteConfirmation = false
  @State private var showInstallationInstructions = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Debug: Show model count
        Text("Available Models: \(aikitService.availableModels.count)")
          .font(.headline)

        // About Section
        VStack(alignment: .leading, spacing: 12) {
          Text("About AIKit")
            .font(.headline)

          Text("AIKit runs AI models locally using containers")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          HStack(spacing: 4) {
            Image(systemName: "info.circle")
              .foregroundStyle(.blue)
            Text("Requires Podman to run local AI models")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if !aikitService.isPodmanAvailable {
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                  .foregroundStyle(.orange)
                Text("Podman not found")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }

              Button("View Installation Instructions") {
                showInstallationInstructions = true
              }
              .font(.caption)
            }
            .padding(.top, 8)
          }
        }

        Divider()

        // Model Selection Section
        VStack(alignment: .leading, spacing: 12) {
          Text("Model Selection")
            .font(.headline)

          Text("Select Model")
            .font(.caption)
            .foregroundStyle(.secondary)

          Picker("", selection: $aikitService.selectedModelId) {
            ForEach(aikitService.availableModels) { model in
              Text("\(model.displayName) (\(model.size))").tag(model.id)
            }
          }
          .labelsHidden()
          .onChange(of: aikitService.selectedModelId) { _, _ in
            aikitService.updateContainerStatus()
          }
        }

        if let model = aikitService.selectedModel {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Image:")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(model.imageURL)
                .font(.caption)
                .textSelection(.enabled)
            }

            HStack {
              Text("Model Name:")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(model.name)
                .font(.caption)
                .textSelection(.enabled)
            }
          }
        }

        Divider()

        // Container Status Section
        VStack(alignment: .leading, spacing: 12) {
          Text("Container Status")
            .font(.headline)

          HStack {
            StatusIndicator(status: aikitService.containerStatus)
            Text(aikitService.statusMessage.isEmpty ? aikitService.containerStatus.rawValue : aikitService.statusMessage)
              .font(.subheadline)
            Spacer()
          }

          if let error = errorMessage {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }

        Divider()

      Divider()

        // Container Management Section
        VStack(alignment: .leading, spacing: 12) {
          Text("Container Management")
            .font(.headline)

          // Pull button
          Button(action: pullModel) {
            HStack {
              if isPulling {
                ProgressView()
                  .controlSize(.small)
                  .padding(.trailing, 4)
              }
              Text(isPulling ? "Pulling..." : "Pull Model")
            }
            .frame(maxWidth: .infinity)
          }
          .disabled(
            !aikitService.isPodmanAvailable || isPulling || aikitService.containerStatus == .running
              ||
            aikitService.containerStatus == .notSupported ||
            aikitService.pulledImages.contains(aikitService.selectedModelId)
          )

          HStack(spacing: 12) {
            // Run button
            Button(action: runContainer) {
              HStack {
                if isRunning {
                  ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                }
                Text(isRunning ? "Starting..." : "Run Container")
              }
              .frame(maxWidth: .infinity)
            }
            .disabled(
              !aikitService.isPodmanAvailable ||
              isRunning ||
              aikitService.containerStatus == .running ||
              aikitService.containerStatus == .notPulled ||
              aikitService.containerStatus == .pulling ||
              aikitService.containerStatus == .notSupported
            )

            // Stop button
            Button(action: stopContainer) {
              HStack {
                if isStopping {
                  ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                }
                Text(isStopping ? "Stopping..." : "Stop Container")
              }
              .frame(maxWidth: .infinity)
            }
            .disabled(isStopping || aikitService.containerStatus != .running)
          }

          // Delete button
          Button(role: .destructive, action: { showDeleteConfirmation = true }) {
            Text("Delete Model Image")
              .frame(maxWidth: .infinity)
          }
          .disabled(!aikitService.pulledImages.contains(aikitService.selectedModelId))

          // Instructions
          VStack(alignment: .leading, spacing: 8) {
            Text("Steps:")
              .font(.caption)
              .fontWeight(.medium)
            Text("1. Select a model from the list above")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("2. Click 'Pull Model' to download the container image")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("3. Click 'Run Container' to start the AI model")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("4. The model will be available at http://localhost:8080")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.top, 8)
        }

        Divider()

        // Configuration Section
        VStack(alignment: .leading, spacing: 12) {
          Text("Configuration")
            .font(.headline)

          HStack {
            Text("Endpoint:")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(aikitService.defaultEndpoint)
              .font(.caption)
              .textSelection(.enabled)
          }

          Text("Set your AI Provider to 'AIKit' in the API settings to use this endpoint")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding()
    .alert("Delete Model Image", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        deleteImage()
      }
    } message: {
      Text("Are you sure you want to delete the pulled image for \(aikitService.selectedModel?.displayName ?? "this model")? You will need to pull it again to use it.")
    }
    .sheet(isPresented: $showInstallationInstructions) {
      InstallationInstructionsView()
    }
  }

  private func pullModel() {
    isPulling = true
    errorMessage = nil

    Task {
      do {
        try await aikitService.pullModel()
        await MainActor.run {
          isPulling = false
        }
      } catch {
        await MainActor.run {
          isPulling = false
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func runContainer() {
    isRunning = true
    errorMessage = nil

    Task {
      do {
        try await aikitService.runContainer()
        await MainActor.run {
          isRunning = false
        }
      } catch {
        await MainActor.run {
          isRunning = false
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func stopContainer() {
    isStopping = true
    errorMessage = nil

    Task {
      do {
        try await aikitService.stopContainer()
        await MainActor.run {
          isStopping = false
        }
      } catch {
        await MainActor.run {
          isStopping = false
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func deleteImage() {
    errorMessage = nil

    Task {
      do {
        try await aikitService.deleteImage()
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
        }
      }
    }
  }
}

struct StatusIndicator: View {
  let status: ContainerStatus

  var body: some View {
    Circle()
      .fill(statusColor)
      .frame(width: 8, height: 8)
  }

  var statusColor: Color {
    switch status {
    case .notPulled:
      return .gray
    case .pulling, .starting, .stopping:
      return .orange
    case .pulled, .stopped:
      return .yellow
    case .running:
      return .green
    case .error:
      return .red
    case .notSupported:
      return .gray
    }
  }
}

struct InstallationInstructionsView: View {
  @Environment(\.dismiss) var dismiss

  var body: some View {
    VStack(spacing: 20) {
      HStack {
        Text("AIKit Installation Requirements")
          .font(.title2)
          .fontWeight(.semibold)
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .font(.title3)
        }
        .buttonStyle(.plain)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text("System Requirements")
              .font(.headline)
            Text("• macOS 14 (Sonoma) or later")
            Text("• Podman installed")
          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            Text("Installation Steps")
              .font(.headline)

            Text("1. Install Podman")
              .fontWeight(.medium)
            Text("   Install Podman using Homebrew:")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text("brew install podman")
              .font(.system(.caption, design: .monospaced))
              .padding(8)
              .background(Color(.textBackgroundColor))
              .cornerRadius(6)

            Text("2. Initialize Podman Machine (first time only)")
              .fontWeight(.medium)
            Text("   Create and start the Podman virtual machine:")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(
              """
              podman machine init
              podman machine start
              """
            )
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .background(Color(.textBackgroundColor))
            .cornerRadius(6)

            Text("3. Verify Installation")
              .fontWeight(.medium)
            Text("   Check that Podman is working:")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text("podman --version")
              .font(.system(.caption, design: .monospaced))
              .padding(8)
              .background(Color(.textBackgroundColor))
              .cornerRadius(6)
          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            Text("Manual Alternative")
              .font(.headline)
            Text("You can also run AIKit models manually with Podman:")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(
              """
              podman run -d --rm -p 8080:8080 \\
                ghcr.io/kaito-project/aikit/llama3.1:8b
              """)
              .font(.system(.caption, design: .monospaced))
              .padding(8)
              .background(Color(.textBackgroundColor))
              .cornerRadius(6)

            Text("Then select AIKit provider in settings")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            Text("More Information")
              .font(.headline)
            Link("AIKit Documentation", destination: URL(string: "https://kaito-project.github.io/aikit/")!)
            Link("Podman Documentation", destination: URL(string: "https://podman.io/docs")!)
          }
        }
        .padding()
      }
    }
    .padding()
    .frame(width: 600, height: 500)
  }
}

#Preview {
  AIKitSettingsView()
    .frame(width: 650, height: 500)
}
