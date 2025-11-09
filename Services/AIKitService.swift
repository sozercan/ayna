//
//  AIKitService.swift
//  ayna
//
//  Created on 11/6/25.
//

import Foundation

// AIKit Model Definition
struct AIKitModel: Identifiable, Codable {
  let id: String
  let name: String
  let displayName: String
  let size: String
  let imagePath: String

  var imageURL: String {
    "ghcr.io/kaito-project/aikit/\(imagePath)"
  }
}

enum ContainerStatus: String {
  case notPulled = "Not Pulled"
  case pulling = "Pulling..."
  case pulled = "Ready"
  case starting = "Starting..."
  case running = "Running"
  case stopping = "Stopping..."
  case stopped = "Stopped"
  case error = "Error"
  case notSupported = "Not Supported"
}

class AIKitService: ObservableObject {
  static let shared = AIKitService()

  // Default endpoint for AIKit containers
  let defaultEndpoint = "http://localhost:8080"

  @Published var selectedModelId: String {
    didSet {
      UserDefaults.standard.set(selectedModelId, forKey: "aikit_selected_model")
      updateContainerStatus()
    }
  }

  @Published var containerStatus: ContainerStatus = .notPulled
  @Published var statusMessage: String = ""
  @Published var pulledImages: Set<String> = []
  @Published var isPodmanAvailable: Bool = false

  // Hard-coded CPU models from AIKit (excluding Apple Silicon)
  let availableModels: [AIKitModel] = [
    AIKitModel(
      id: "llama-3.2-1b",
      name: "llama-3.2-1b-instruct",
      displayName: "🦙 Llama 3.2 1B Instruct",
      size: "1B",
      imagePath: "llama3.2:1b"
    ),
    AIKitModel(
      id: "llama-3.2-3b",
      name: "llama-3.2-3b-instruct",
      displayName: "🦙 Llama 3.2 3B Instruct",
      size: "3B",
      imagePath: "llama3.2:3b"
    ),
    AIKitModel(
      id: "llama-3.1-8b",
      name: "llama-3.1-8b-instruct",
      displayName: "🦙 Llama 3.1 8B Instruct",
      size: "8B",
      imagePath: "llama3.1:8b"
    ),
    AIKitModel(
      id: "llama-3.3-70b",
      name: "llama-3.3-70b-instruct",
      displayName: "🦙 Llama 3.3 70B Instruct",
      size: "70B",
      imagePath: "llama3.3:70b"
    ),
    AIKitModel(
      id: "mixtral-8x7b",
      name: "mixtral-8x7b-instruct",
      displayName: "Ⓜ️ Mixtral 8x7B Instruct",
      size: "8x7B",
      imagePath: "mixtral:8x7b"
    ),
    AIKitModel(
      id: "phi-4-14b",
      name: "phi-4-14b-instruct",
      displayName: "🅿️ Phi 4 14B Instruct",
      size: "14B",
      imagePath: "phi4:14b"
    ),
    AIKitModel(
      id: "gemma-2-2b",
      name: "gemma-2-2b-instruct",
      displayName: "🔡 Gemma 2 2B Instruct",
      size: "2B",
      imagePath: "gemma2:2b"
    ),
    AIKitModel(
      id: "qwq-32b",
      name: "qwq-32b",
      displayName: "QwQ 32B",
      size: "32B",
      imagePath: "qwq:32b"
    ),
    AIKitModel(
      id: "codestral-22b",
      name: "codestral-22b",
      displayName: "⌨️ Codestral 22B",
      size: "22B",
      imagePath: "codestral:22b"
    ),
    AIKitModel(
      id: "gpt-oss-20b",
      name: "gpt-oss-20b",
      displayName: "🤖 GPT-OSS 20B",
      size: "20B",
      imagePath: "gpt-oss:20b"
    ),
    AIKitModel(
      id: "gpt-oss-120b",
      name: "gpt-oss-120b",
      displayName: "🤖 GPT-OSS 120B",
      size: "120B",
      imagePath: "gpt-oss:120b"
    )
  ]

  // Container management - stores the container name/ID
  private var containerName: String?

  init() {
    // Load selected model
    let savedModel = UserDefaults.standard.string(forKey: "aikit_selected_model") ?? "llama-3.1-8b"
    self.selectedModelId = savedModel

    // Load pulled images
    if let savedPulled = UserDefaults.standard.array(forKey: "aikit_pulled_images") as? [String] {
      self.pulledImages  = Set(savedPulled)
    }

    // Check if Podman is available
    checkPodmanAvailability()

    // Update initial status
    updateContainerStatus()
  }

  // Cached path to podman binary
  private var podmanPath: String?

  func checkPodmanAvailability() {
    // Check common installation paths for podman
    let commonPaths = [
      "/opt/podman/bin/podman",
      "/usr/local/bin/podman",
      "/opt/homebrew/bin/podman",
      "/usr/bin/podman"
    ]

    for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
      podmanPath = path
      isPodmanAvailable = true
      return
    }

    // Fall back to checking PATH using which
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["podman"]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus == 0 {
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: outputData, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
          !path.isEmpty {
          podmanPath = path
          isPodmanAvailable = true
          return
        }
      }
    } catch {
      isPodmanAvailable = false
    }

    isPodmanAvailable = false
  }

  var selectedModel: AIKitModel? {
    availableModels.first { $0.id == selectedModelId }
  }

  // Find and select a model by its name (used when selecting from the main model list)
  func selectModelByName(_ name: String) {
    if let model = availableModels.first(where: { $0.name == name }) {
      selectedModelId = model.id
    }
  }

  func updateContainerStatus() {
    guard let model = selectedModel else {
      containerStatus = .notPulled
      statusMessage = "No model selected"
      return
    }

    if !isPodmanAvailable {
      containerStatus = .notSupported
      statusMessage = "Podman not found. Install with: brew install podman"
      return
    }

    // Check if container is already running
    Task {
      if await isContainerRunning(modelId: model.id) {
        await MainActor.run {
          containerStatus = .running
          statusMessage = "Container running on \(defaultEndpoint)"
        }
        return
      }

      // Otherwise check if image is pulled
      await MainActor.run {
        if pulledImages.contains(model.id) {
          containerStatus = .pulled
          statusMessage = "Model ready to run"
        } else {
          containerStatus = .notPulled
          statusMessage = "Model not pulled"
        }
      }
    }
  }

  private func isContainerRunning(modelId: String) async -> Bool {
    let containerName = "aikit-\(modelId)"

    guard let podmanPath = podmanPath else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: podmanPath)
    process.arguments = [
      "ps", "--filter", "name=\(containerName)", "--format", "{{.Names}}"]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus == 0 {
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: outputData, encoding: .utf8) {
          let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmedOutput.isEmpty && trimmedOutput == containerName {
            // Store the container name for future operations
            self.containerName = containerName
            return true
          }
        }
      }
    } catch {
      // If we can't check, assume not running
      return false
    }

    return false
  }

  // MARK: - Container Operations

  func pullModel() async throws {
    guard let model = selectedModel else {
      throw AIKitError.noModelSelected
    }

    guard isPodmanAvailable else {
      throw AIKitError.podmanNotAvailable
    }

    await MainActor.run {
      containerStatus = .pulling
      statusMessage = "Pulling \(model.displayName)..."
    }

    guard let podmanPath = podmanPath else {
      throw AIKitError.podmanNotAvailable
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: podmanPath)
    process.arguments = ["pull", model.imageURL]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        await MainActor.run {
          containerStatus = .error
          statusMessage = "Failed to pull: \(errorMessage)"
        }
        throw AIKitError.imagePullFailed(errorMessage)
      }

      await MainActor.run {
        pulledImages.insert(model.id)
        UserDefaults.standard.set(Array(pulledImages), forKey: "aikit_pulled_images")
        containerStatus = .pulled
        statusMessage = "Model pulled successfully"
      }
    } catch let error as AIKitError {
      throw error
    } catch {
      await MainActor.run {
        containerStatus = .error
        statusMessage = "Failed to pull: \(error.localizedDescription)"
      }
      throw error
    }
  }

  func runContainer() async throws {
    guard let model = selectedModel else {
      throw AIKitError.noModelSelected
    }

    guard pulledImages.contains(model.id) else {
      throw AIKitError.modelNotPulled
    }

    // Check if container is already running
    if await isContainerRunning(modelId: model.id) {
      await MainActor.run {
        containerStatus = .running
        statusMessage = "Container already running on \(defaultEndpoint)"
      }
      return
    }

    await MainActor.run {
      containerStatus = .starting
      statusMessage = "Starting container..."
    }

    let containerName = "aikit-\(model.id)"

    guard let podmanPath = podmanPath else {
      throw AIKitError.podmanNotAvailable
    }

    // First, try to remove any existing stopped container with the same name
    let removeProcess = Process()
    removeProcess.executableURL = URL(fileURLWithPath: podmanPath)
    removeProcess.arguments = ["rm", "-f", containerName]
    removeProcess.standardOutput = Pipe()
    removeProcess.standardError = Pipe()
    try? removeProcess.run()
    removeProcess.waitUntilExit()
    // Ignore errors - container may not exist

    // Now run the container
    let process = Process()
    process.executableURL = URL(fileURLWithPath: podmanPath)
    process.arguments = [
      "run",
      "-d",  // Detached mode
      "--rm",  // Auto-remove when stopped
      "--name", containerName,  // Container name
      "-p", "8080:8080",  // Port mapping
      model.imageURL  // Image reference
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        await MainActor.run {
          containerStatus = .error
          statusMessage = "Failed to start: \(errorMessage)"
        }
        throw AIKitError.containerStartFailed(errorMessage)
      }

      // Get the container ID from output
      let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
      if let containerId = String(data: outputData, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines) {
        self.containerName = containerId
      }

      await MainActor.run {
        containerStatus = .running
        statusMessage = "Container running on \(defaultEndpoint)"
      }
    } catch let error as AIKitError {
      throw error
    } catch {
      await MainActor.run {
        containerStatus = .error
        statusMessage = "Failed to start: \(error.localizedDescription)"
      }
      throw error
    }
  }

  func stopContainer() async throws {
    guard let containerName = containerName else {
      throw AIKitError.noContainerRunning
    }

    guard let podmanPath = podmanPath else {
      throw AIKitError.podmanNotAvailable
    }

    await MainActor.run {
      containerStatus = .stopping
      statusMessage = "Stopping container..."
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: podmanPath)
    process.arguments = ["stop", containerName]

    let errorPipe = Pipe()
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        await MainActor.run {
          containerStatus = .error
          statusMessage = "Failed to stop: \(errorMessage)"
        }
        throw AIKitError.containerStopFailed(errorMessage)
      }

      self.containerName = nil

      await MainActor.run {
        containerStatus = .stopped
        statusMessage = "Container stopped"
      }
    } catch let error as AIKitError {
      throw error
    } catch {
      await MainActor.run {
        containerStatus = .error
        statusMessage = "Failed to stop: \(error.localizedDescription)"
      }
      throw error
    }
  }

  func deleteImage() async throws {
    guard let model = selectedModel else {
      throw AIKitError.noModelSelected
    }

    // Stop container if running
    if containerStatus == .running {
      try await stopContainer()
    }

    // Remove from pulled images
    await MainActor.run {
      pulledImages.remove(model.id)
      UserDefaults.standard.set(Array(pulledImages), forKey: "aikit_pulled_images")
      updateContainerStatus()
    }
  }
}

// MARK: - Errors

enum AIKitError: LocalizedError {
  case noModelSelected
  case modelNotPulled
  case noContainerRunning
  case podmanNotAvailable
  case imagePullFailed(String)
  case containerStartFailed(String)
  case containerStopFailed(String)

  var errorDescription: String? {
    switch self {
    case .noModelSelected:
      return "No model selected"
    case .modelNotPulled:
      return "Model needs to be pulled first"
    case .noContainerRunning:
      return "No container is currently running"
    case .podmanNotAvailable:
      return "Podman is not installed. Install with: brew install podman"
    case .imagePullFailed(let message):
      return "Failed to pull image: \(message)"
    case .containerStartFailed(let message):
      return "Failed to start container: \(message)"
    case .containerStopFailed(let message):
      return "Failed to stop container: \(message)"
    }
  }
}
