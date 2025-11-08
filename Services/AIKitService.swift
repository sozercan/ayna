//
//  AIKitService.swift
//  ayna
//
//  Created on 11/6/25.
//

import Foundation
#if canImport(Containerization)
import Containerization
import ContainerizationOCI
#endif

// AIKit Model Definition
struct AIKitModel: Identifiable, Codable {
  let id: String
  let name: String
  let displayName: String
  let size: String
  let imagePath: String
  let license: String

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
    }
  }

  @Published var containerStatus: ContainerStatus = .notPulled
  @Published var statusMessage: String = ""
  @Published var pulledImages: Set<String> = []
  @Published var isContainerizationAvailable: Bool = false

  // Hard-coded CPU models from AIKit (excluding Apple Silicon)
  let availableModels: [AIKitModel] = [
    AIKitModel(
      id: "llama-3.2-1b",
      name: "llama-3.2-1b-instruct",
      displayName: "🦙 Llama 3.2 1B Instruct",
      size: "1B",
      imagePath: "llama3.2:1b",
      license: "Llama"
    ),
    AIKitModel(
      id: "llama-3.2-3b",
      name: "llama-3.2-3b-instruct",
      displayName: "🦙 Llama 3.2 3B Instruct",
      size: "3B",
      imagePath: "llama3.2:3b",
      license: "Llama"
    ),
    AIKitModel(
      id: "llama-3.1-8b",
      name: "llama-3.1-8b-instruct",
      displayName: "🦙 Llama 3.1 8B Instruct",
      size: "8B",
      imagePath: "llama3.1:8b",
      license: "Llama"
    ),
    AIKitModel(
      id: "llama-3.3-70b",
      name: "llama-3.3-70b-instruct",
      displayName: "🦙 Llama 3.3 70B Instruct",
      size: "70B",
      imagePath: "llama3.3:70b",
      license: "Llama"
    ),
    AIKitModel(
      id: "mixtral-8x7b",
      name: "mixtral-8x7b-instruct",
      displayName: "Ⓜ️ Mixtral 8x7B Instruct",
      size: "8x7B",
      imagePath: "mixtral:8x7b",
      license: "Apache"
    ),
    AIKitModel(
      id: "phi-4-14b",
      name: "phi-4-14b-instruct",
      displayName: "🅿️ Phi 4 14B Instruct",
      size: "14B",
      imagePath: "phi4:14b",
      license: "MIT"
    ),
    AIKitModel(
      id: "gemma-2-2b",
      name: "gemma-2-2b-instruct",
      displayName: "🔡 Gemma 2 2B Instruct",
      size: "2B",
      imagePath: "gemma2:2b",
      license: "Gemma"
    ),
    AIKitModel(
      id: "qwq-32b",
      name: "qwq-32b",
      displayName: "QwQ 32B",
      size: "32B",
      imagePath: "qwq:32b",
      license: "Apache 2.0"
    ),
    AIKitModel(
      id: "codestral-22b",
      name: "codestral-22b",
      displayName: "⌨️ Codestral 22B",
      size: "22B",
      imagePath: "codestral:22b",
      license: "MNLP"
    ),
    AIKitModel(
      id: "gpt-oss-20b",
      name: "gpt-oss-20b",
      displayName: "🤖 GPT-OSS 20B",
      size: "20B",
      imagePath: "gpt-oss:20b",
      license: "Apache 2.0"
    ),
    AIKitModel(
      id: "gpt-oss-120b",
      name: "gpt-oss-120b",
      displayName: "🤖 GPT-OSS 120B",
      size: "120B",
      imagePath: "gpt-oss:120b",
      license: "Apache 2.0"
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
      self.pulledImages = Set(savedPulled)
    }

    // Check if Containerization framework is available
    checkContainerizationAvailability()

    // Update initial status
    updateContainerStatus()
  }

  func checkContainerizationAvailability() {
    #if canImport(Containerization)
    // Check if running on macOS 26+ and Apple Silicon
    if #available(macOS 26, *) {
      #if arch(arm64)
      isContainerizationAvailable = true
      #else
      isContainerizationAvailable = false
      #endif
    } else {
      isContainerizationAvailable = false
    }
    #else
    isContainerizationAvailable = false
    #endif
  }

  var selectedModel: AIKitModel? {
    availableModels.first { $0.id == selectedModelId }
  }

  func updateContainerStatus() {
    guard let model = selectedModel else {
      containerStatus = .notPulled
      statusMessage = "No model selected"
      return
    }

    if !isContainerizationAvailable {
      containerStatus = .notSupported
      statusMessage = "Requires macOS 26+ with Apple Silicon"
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
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
    process.arguments = ["list", "-a"]
    
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()
    
    do {
      try process.run()
      process.waitUntilExit()
      
      if process.terminationStatus == 0 {
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: outputData, encoding: .utf8) {
          // Check if the container name appears in the output and is running
          let lines = output.components(separatedBy: .newlines)
          for line in lines {
            if line.contains(containerName) && line.contains("running") {
              // Store the container name for future operations
              self.containerName = containerName
              return true
            }
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

    guard isContainerizationAvailable else {
      throw AIKitError.containerizationNotSupported
    }

    await MainActor.run {
      containerStatus = .pulling
      statusMessage = "Pulling \(model.displayName)..."
    }

    #if canImport(Containerization)
    do {
      // Use the default ImageStore for pulling images
      let store = ImageStore.default

      // Pull the image from the AIKit registry
      // The pull method will download the image for the current platform
      _ = try await store.pull(
        reference: model.imageURL,
        platform: .current
      )

      await MainActor.run {
        pulledImages.insert(model.id)
        UserDefaults.standard.set(Array(pulledImages), forKey: "aikit_pulled_images")
        containerStatus = .pulled
        statusMessage = "Model pulled successfully"
      }
    } catch {
      await MainActor.run {
        containerStatus = .error
        statusMessage = "Failed to pull: \(error.localizedDescription)"
      }
      throw error
    }
    #else
    throw AIKitError.containerizationNotSupported
    #endif
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

    #if canImport(Containerization)
    if #available(macOS 26, *) {
      do {
        // Use the container CLI to run the container
        // This is equivalent to: container run -d --rm --name aikit-MODEL -p 8080:8080 -c 4 -m 8G IMAGE
        let containerName = "aikit-\(model.id)"
        
        // First, try to remove any existing stopped container with the same name
        let removeProcess = Process()
        removeProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        removeProcess.arguments = ["rm", containerName]
        removeProcess.standardOutput = Pipe()
        removeProcess.standardError = Pipe()
        try? removeProcess.run()
        removeProcess.waitUntilExit()
        // Ignore errors - container may not exist
        
        // Now run the container
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        process.arguments = [
          "run",
          "-d",                    // Detached mode
          "--rm",                  // Auto-remove when stopped
          "--name", containerName, // Container name
          "-c", "4",              // 4 CPUs
          "-m", "8G",             // 8GB memory
          "-p", "8080:8080",      // Port mapping
          model.imageURL          // Image reference
        ]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
          let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
          let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
          throw AIKitError.containerStartFailed(errorMessage)
        }
        
        // Get the container ID from output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if let containerId = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
          self.containerName = containerId
        }
        
        await MainActor.run {
          containerStatus = .running
          statusMessage = "Container running on \(defaultEndpoint)"
        }
      } catch {
        await MainActor.run {
          containerStatus = .error
          statusMessage = "Failed to start: \(error.localizedDescription)"
        }
        throw error
      }
    } else {
      throw AIKitError.containerizationNotSupported
    }
    #else
    throw AIKitError.containerizationNotSupported
    #endif
  }

  func stopContainer() async throws {
    #if canImport(Containerization)
    guard let containerName = containerName else {
      throw AIKitError.noContainerRunning
    }
    
    await MainActor.run {
      containerStatus = .stopping
      statusMessage = "Stopping container..."
    }
    
    do {
      // Use the container CLI to stop the container
      // This is equivalent to: container stop CONTAINER_ID
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
      process.arguments = ["stop", containerName]
      
      let errorPipe = Pipe()
      process.standardError = errorPipe
      
      try process.run()
      process.waitUntilExit()
      
      if process.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        throw AIKitError.containerStopFailed(errorMessage)
      }
      
      self.containerName = nil
      
      await MainActor.run {
        containerStatus = .stopped
        statusMessage = "Container stopped"
      }
    } catch {
      await MainActor.run {
        containerStatus = .error
        statusMessage = "Failed to stop: \(error.localizedDescription)"
      }
      throw error
    }
    #else
    throw AIKitError.containerizationNotSupported
    #endif
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
  case containerizationNotSupported
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
    case .containerizationNotSupported:
      return "Containerization is only supported on macOS 26+ with Apple Silicon. Install the Container CLI: https://github.com/apple/container"
    case .containerStartFailed(let message):
      return "Failed to start container: \(message)"
    case .containerStopFailed(let message):
      return "Failed to stop container: \(message)"
    }
  }
}
