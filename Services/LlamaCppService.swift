//
//  LlamaCppService.swift
//  ayna
//
//  Created on 11/19/25.
//

import Combine
import Foundation

enum LlamaCppServerStatus: String {
    case notInstalled = "Not Installed"
    case installing = "Installing..."
    case ready = "Ready"
    case starting = "Starting..."
    case running = "Running"
    case stopping = "Stopping..."
    case error = "Error"
}

struct LlamaModel: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let path: URL
    let size: Int64
}

@MainActor
class LlamaCppService: ObservableObject {
    static let shared = LlamaCppService()

    // Configuration
    private let targetBuild = "b7108"
    private let port = 8081

    @Published var serverStatus: LlamaCppServerStatus = .notInstalled
    @Published var serverOutput: String = ""
    @Published var availableModels: [LlamaModel] = []
    @Published var downloadProgress: Double = 0
    @Published var isDownloading: Bool = false
    @Published var downloadMessage: String = ""

    // Settings
    @Published var selectedModel: String? {
        didSet {
            AppPreferences.storage.set(selectedModel, forKey: "llama_selected_model")
        }
    }

    @Published var contextSize: Int {
        didSet {
            AppPreferences.storage.set(contextSize, forKey: "llama_context_size")
        }
    }

    @Published var gpuLayers: Int {
        didSet {
            AppPreferences.storage.set(gpuLayers, forKey: "llama_gpu_layers")
        }
    }

    @Published var threads: Int {
        didSet {
            AppPreferences.storage.set(threads, forKey: "llama_threads")
        }
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    private var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ayna/llama")
    }

    private var binURL: URL {
        appSupportURL.appendingPathComponent("bin")
    }

    private var modelsURL: URL {
        appSupportURL.appendingPathComponent("models")
    }

    private var serverExecutableURL: URL {
        binURL.appendingPathComponent("build/bin/llama-server")
    }

    init() {
        let storedContextSize = AppPreferences.storage.integer(forKey: "llama_context_size")
        contextSize = storedContextSize == 0 ? 4096 : storedContextSize

        let storedGpuLayers = AppPreferences.storage.integer(forKey: "llama_gpu_layers")
        gpuLayers = storedGpuLayers == 0 ? 99 : storedGpuLayers

        let storedThreads = AppPreferences.storage.integer(forKey: "llama_threads")
        threads = storedThreads == 0 ? 4 : storedThreads

        selectedModel = AppPreferences.storage.string(forKey: "llama_selected_model")

        checkInstallation()
        refreshModels()
    }

    func checkInstallation() {
        if FileManager.default.fileExists(atPath: serverExecutableURL.path) {
            if serverStatus == .notInstalled {
                serverStatus = .ready
            }
        } else {
            serverStatus = .notInstalled
        }
    }

    func refreshModels() {
        do {
            if !FileManager.default.fileExists(atPath: modelsURL.path) {
                try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
            }

            let files = try FileManager.default.contentsOfDirectory(at: modelsURL, includingPropertiesForKeys: [.fileSizeKey])

            availableModels = files.filter { $0.pathExtension == "gguf" }.compactMap { url in
                let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
                return LlamaModel(name: url.lastPathComponent, path: url, size: Int64(resources?.fileSize ?? 0))
            }

            // Select first model if none selected
            if selectedModel == nil, let first = availableModels.first {
                selectedModel = first.name
            }
        } catch {
            DiagnosticsLogger.log(.llamaCppService, level: .error, message: "Failed to list models: \(error.localizedDescription)")
        }
    }

    func installServer() async {
        guard !isDownloading else { return }

        serverStatus = .installing
        isDownloading = true
        downloadMessage = "Downloading llama.cpp..."
        downloadProgress = 0

        do {
            try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

            // Determine architecture
            #if arch(arm64)
                let arch = "arm64"
            #else
                let arch = "x64"
            #endif

            // Construct URL
            // Example: https://github.com/ggml-org/llama.cpp/releases/download/b7108/llama-b7108-bin-macos-arm64.zip
            let filename = "llama-\(targetBuild)-bin-macos-\(arch).zip"
            let downloadURLString = "https://github.com/ggml-org/llama.cpp/releases/download/\(targetBuild)/\(filename)"

            guard let url = URL(string: downloadURLString) else {
                throw NSError(domain: "LlamaCppService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            let (localURL, _) = try await URLSession.shared.download(from: url)

            downloadMessage = "Extracting..."

            // Unzip
            let destinationURL = binURL

            // Clean up previous installation
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", localURL.path, "-d", destinationURL.path]

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                serverStatus = .ready
                DiagnosticsLogger.log(.llamaCppService, level: .info, message: "✅ llama.cpp installed successfully")
            } else {
                throw NSError(domain: "LlamaCppService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unzip failed"])
            }

        } catch {
            DiagnosticsLogger.log(.llamaCppService, level: .error, message: "❌ Failed to install llama.cpp: \(error.localizedDescription)")
            serverStatus = .error
        }

        isDownloading = false
        downloadMessage = ""
    }

    func downloadModel(from urlString: String) async {
        guard let url = URL(string: urlString), !isDownloading else { return }

        isDownloading = true
        downloadMessage = "Downloading model..."
        downloadProgress = 0

        do {
            try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
            let destinationURL = modelsURL.appendingPathComponent(url.lastPathComponent)

            let downloader = ModelDownloader()
            let localURL = try await downloader.download(url: url) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress
                }
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: localURL, to: destinationURL)

            refreshModels()
            selectedModel = destinationURL.lastPathComponent
            DiagnosticsLogger.log(.llamaCppService, level: .info, message: "✅ Model downloaded: \(destinationURL.lastPathComponent)")

        } catch {
            DiagnosticsLogger.log(.llamaCppService, level: .error, message: "❌ Failed to download model: \(error.localizedDescription)")
        }

        isDownloading = false
        downloadMessage = ""
    }

    func startServer() {
        guard serverStatus == .ready || serverStatus == .error || serverStatus == .stopping else { return }
        guard let modelName = selectedModel else {
            DiagnosticsLogger.log(.llamaCppService, level: .error, message: "❌ No model selected")
            return
        }

        let modelPath = modelsURL.appendingPathComponent(modelName).path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            DiagnosticsLogger.log(.llamaCppService, level: .error, message: "❌ Model file not found: \(modelPath)")
            return
        }

        serverStatus = .starting
        serverOutput = ""

        let process = Process()
        process.executableURL = serverExecutableURL

        // Arguments
        let args = [
            "--model", modelPath,
            "--ctx-size", String(contextSize),
            "--port", String(port),
            "--n-gpu-layers", String(gpuLayers),
            "--threads", String(threads),
            "--jinja",
        ]

        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            let string = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.serverOutput += string
                // Check for readiness
                if string.contains("HTTP server listening") {
                    self?.serverStatus = .running
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            let string = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.serverOutput += string
                // Llama server often logs to stderr
                if string.contains("HTTP server listening") {
                    self?.serverStatus = .running
                }
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.serverStatus = .ready
                DiagnosticsLogger.log(.llamaCppService, level: .info, message: "🛑 llama-server stopped")
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            DiagnosticsLogger.log(.llamaCppService, level: .info, message: "🚀 llama-server started on port \(port)")
        } catch {
            DiagnosticsLogger.log(.llamaCppService, level: .error, message: "❌ Failed to start llama-server: \(error.localizedDescription)")
            serverStatus = .error
        }
    }

    func stopServer() {
        guard let process, process.isRunning else { return }
        serverStatus = .stopping
        process.terminate()
        self.process = nil
        outputPipe = nil
        errorPipe = nil
    }

    func deleteModel(_ model: LlamaModel) {
        do {
            try FileManager.default.removeItem(at: model.path)
            refreshModels()
            if selectedModel == model.name {
                selectedModel = availableModels.first?.name
            }
        } catch {
            DiagnosticsLogger.log(.llamaCppService, level: .error, message: "❌ Failed to delete model: \(error.localizedDescription)")
        }
    }

    func ensureServerRunning(modelName: String) async throws {
        if serverStatus == .running && selectedModel == modelName {
            return
        }

        if serverStatus == .running || serverStatus == .starting {
            stopServer()
            // Wait for server to stop
            var attempts = 0
            while serverStatus != .ready && serverStatus != .notInstalled && attempts < 50 {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                attempts += 1
            }
        }

        selectedModel = modelName
        startServer()

        // Wait for server to start
        var attempts = 0
        while serverStatus != .running && attempts < 600 { // 60 seconds timeout
            if serverStatus == .error {
                throw NSError(domain: "LlamaCppService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to start server: \(serverOutput)"])
            }
            // If status becomes .ready while we are expecting it to start, it means it crashed/stopped
            if serverStatus == .ready {
                throw NSError(domain: "LlamaCppService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Server stopped unexpectedly: \(serverOutput)"])
            }

            // Check if server is responding via HTTP even if we missed the log
            if await checkServerHealth() {
                serverStatus = .running
                break
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            attempts += 1
        }

        if serverStatus != .running {
            throw NSError(domain: "LlamaCppService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Server start timeout. Last output: \(serverOutput)"])
        }
    }

    private func checkServerHealth() async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
        } catch {
            return false
        }
        return false
    }
}

final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var session: URLSession?

    func download(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progressHandler = progress

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.default
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session?.downloadTask(with: url)
            task?.resume()
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // Move to a temp location that persists after this delegate method
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: tempFile)
            continuation?.resume(returning: tempFile)
            continuation = nil
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(progress)
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let continuation {
            continuation.resume(throwing: error)
            self.continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
