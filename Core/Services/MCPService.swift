//
//  MCPService.swift
//  ayna
//
//  Created on 11/3/25.
//

import Combine
import Foundation
import os

#if compiler(>=6.0)
    #warning("MCPService uses @unchecked Sendable - thread safety ensured manually via Task { @MainActor } and [weak self]")
#endif

protocol MCPServicing: AnyObject, Sendable {
    var serverConfig: MCPServerConfig { get }
    var isConnected: Bool { get }
    var lastError: String? { get set }
    var delegate: MCPServiceDelegate? { get set }

    func connect() async throws
    func disconnect()
    func listTools() async throws -> [MCPTool]
    func listResources() async throws -> [MCPResource]
    func callTool(name: String, arguments: [String: Any]) async throws -> String
}

@MainActor
protocol MCPServiceDelegate: AnyObject {
    func mcpService(_ service: MCPServicing, didTerminateWithError error: String?)
}

/// Service for communicating with MCP servers via stdio
class MCPService: ObservableObject, MCPServicing, @unchecked Sendable {
    private var process: Process?
    private var standardInput: Pipe?
    private var standardOutput: Pipe?
    private var standardError: Pipe?

    private var healthCheckTimer: DispatchSourceTimer?
    private var isDisconnectingManually = false

    private var requestId = 0
    private var pendingRequests: [Int: CheckedContinuation<MCPResponse, Error>] = [:]
    // requestQueue removed to use MainActor for thread safety

    let serverConfig: MCPServerConfig
    @Published var isConnected = false
    @Published var lastError: String?
    weak var delegate: MCPServiceDelegate?

    private var outputBuffer = ""

    init(serverConfig: MCPServerConfig) {
        self.serverConfig = serverConfig
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    // This routine wires up the MCP subprocess, pipes, and async stream handlers in one place so we
    // can share the same cleanup/error propagation. Splitting it today would duplicate fragile state
    // management, so we temporarily allow the longer body until the connection pipeline is refactored.
    func connect() async throws {
        guard !isConnected else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Find the command executable with error handling
        DiagnosticsLogger.log(
            .mcpService,
            level: .info,
            message: "Looking for executable",
            metadata: ["command": serverConfig.command]
        )
        let commandPath: String
        do {
            commandPath = try findExecutable(serverConfig.command)
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "Using executable path",
                metadata: ["path": commandPath]
            )
        } catch {
            let errorMsg = "Executable not found: \(serverConfig.command) - \(error.localizedDescription)"
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: errorMsg
            )
            Task { @MainActor [weak self] in
                self?.lastError = errorMsg
            }
            throw MCPServiceError.initializationFailed(errorMsg)
        }

        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = serverConfig.args

        // Set up environment with proper PATH
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/opt/homebrew/opt/node/bin",
            NSHomeDirectory() + "/.nvm/versions/node/*/bin"
        ]
        let existingPath = environment["PATH"] ?? ""
        let newPath = (commonPaths + [existingPath]).joined(separator: ":")
        environment["PATH"] = newPath

        // Merge with user-provided environment
        // Only merge if env is not empty to avoid potential type issues
        if !serverConfig.env.isEmpty {
            for (key, value) in serverConfig.env {
                environment[key] = value
            }
        }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        standardInput = inputPipe
        standardOutput = outputPipe
        standardError = errorPipe
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            handleProcessTermination(exitCode: process.terminationStatus)
        }

        // Set up output reading with error handling
        let serverName = serverConfig.name
        outputPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            do {
                let data = handle.availableData
                guard !data.isEmpty else { return }

                if let output = String(data: data, encoding: .utf8) {
                    Task { @MainActor in
                        self?.handleOutput(output)
                    }
                }
            } catch {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .error,
                    message: "Error reading MCP output",
                    metadata: ["server": serverName, "error": error.localizedDescription]
                )
            }
        }

        // Set up error reading (stderr - may include info messages)
        errorPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            do {
                let data = handle.availableData
                guard !data.isEmpty else { return }

                if let output = String(data: data, encoding: .utf8) {
                    DiagnosticsLogger.log(
                        .mcpService,
                        level: .info,
                        message: "MCP server stderr",
                        metadata: ["server": serverName, "output": output]
                    )
                    // Only treat it as an error if it contains error keywords
                    if output.lowercased().contains("error") || output.lowercased().contains("failed") {
                        Task { @MainActor in
                            self?.lastError = output
                        }
                    }
                }
            } catch {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .error,
                    message: "Error reading stderr",
                    metadata: ["server": serverName, "error": error.localizedDescription]
                )
            }
        }

        do {
            try process.run()
            MCPProcessTracker.shared.register(serverName: serverName, pid: process.processIdentifier)

            // Initialize the MCP session
            try await initialize()
        } catch {
            disconnect()
            let errorMsg = "Failed to start process: \(error.localizedDescription)"
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: errorMsg
            )
            Task { @MainActor [weak self] in
                self?.lastError = errorMsg
            }
            throw MCPServiceError.initializationFailed(errorMsg)
        }

        Task { @MainActor in
            self.isConnected = true
            self.lastError = nil
        }

        startHealthCheckTimer()
    }

    func disconnect() {
        guard !isDisconnectingManually else { return }
        isDisconnectingManually = true

        stopHealthCheckTimer()

        // Clean up handlers BEFORE terminating to stop processing
        cleanupProcessResources()

        // Capture process reference before clearing
        let processToTerminate = process
        process = nil

        // Unregister from process tracker
        MCPProcessTracker.shared.unregister(serverName: serverConfig.name)

        // Terminate and wait for exit in background to avoid zombie processes
        if let processToTerminate, processToTerminate.isRunning {
            processToTerminate.terminate()
            Task.detached {
                processToTerminate.waitUntilExit()
            }
        }

        Task { @MainActor [weak self] in
            self?.isConnected = false
            self?.isDisconnectingManually = false
        }
    }

    // MARK: - MCP Protocol Methods

    private func initialize() async throws {
        let response = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": AnyCodable("2024-11-05"),
                "capabilities": AnyCodable([
                    "roots": ["list_changed": true],
                    "sampling": [:]
                ] as [String: Any]),
                "clientInfo": AnyCodable([
                    "name": "ayna",
                    "version": "1.0.0"
                ] as [String: String])
            ]
        )

        guard response.error == nil else {
            throw MCPServiceError.initializationFailed(response.error?.message ?? "Unknown error")
        }

        // Send initialized notification
        try await sendNotification(method: "notifications/initialized")
    }

    func listTools() async throws -> [MCPTool] {
        let response = try await sendRequest(method: "tools/list", params: nil)

        guard let result = response.result?.value as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]]
        else {
            throw MCPServiceError.invalidResponse("Failed to parse tools list")
        }

        // Parse tools individually, skipping invalid ones instead of crashing
        var validTools: [MCPTool] = []
        for (index, toolDict) in toolsArray.enumerated() {
            do {
                let tool = try parseTool(from: toolDict)
                validTools.append(tool)
            } catch {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .error,
                    message: "Skipping invalid tool",
                    metadata: [
                        "server": serverConfig.name,
                        "index": "\(index)",
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        return validTools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let response = try await sendRequest(
            method: "tools/call",
            params: [
                "name": AnyCodable(name),
                "arguments": AnyCodable(arguments)
            ]
        )

        guard let result = response.result?.value as? [String: Any] else {
            throw MCPServiceError.invalidResponse("Failed to parse tool call result")
        }

        // Handle different content types
        if let content = result["content"] as? [[String: Any]] {
            // Multiple content items
            let texts = content.compactMap { item -> String? in
                if item["type"] as? String == "text",
                   let text = item["text"] as? String
                {
                    return text
                }
                return nil
            }
            return texts.joined(separator: "\n")
        } else if let text = result["content"] as? String {
            // Single text content
            return text
        } else {
            throw MCPServiceError.invalidResponse("Unexpected content format in tool result")
        }
    }

    func listResources() async throws -> [MCPResource] {
        let response = try await sendRequest(method: "resources/list", params: nil)

        guard let result = response.result?.value as? [String: Any],
              let resourcesArray = result["resources"] as? [[String: Any]]
        else {
            throw MCPServiceError.invalidResponse("Failed to parse resources list")
        }

        return resourcesArray.compactMap { resourceDict in
            parseResource(from: resourceDict)
        }
    }

    // MARK: - Low-level JSON-RPC

    @MainActor
    private func sendRequest(method: String, params: [String: AnyCodable]?) async throws -> MCPResponse {
        requestId += 1
        let id = requestId

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            let request = MCPRequest(id: id, method: method, params: params)

            do {
                let data = try JSONEncoder().encode(request)
                guard var jsonString = String(data: data, encoding: .utf8) else {
                    pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: MCPServiceError.encodingFailed)
                    return
                }

                jsonString += "\n"

                guard let inputHandle = standardInput?.fileHandleForWriting else {
                    pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: MCPServiceError.notConnected)
                    return
                }

                if let data = jsonString.data(using: .utf8) {
                    inputHandle.write(data)
                }
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: AnyCodable]? = nil) async throws {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params?.mapValues { $0.value } ?? [:]
        ]

        let data = try JSONSerialization.data(withJSONObject: notification)
        guard var jsonString = String(data: data, encoding: .utf8) else {
            throw MCPServiceError.encodingFailed
        }

        jsonString += "\n"

        guard let inputHandle = standardInput?.fileHandleForWriting else {
            throw MCPServiceError.notConnected
        }

        if let data = jsonString.data(using: .utf8) {
            inputHandle.write(data)
        }
    }

    private func handleOutput(_ output: String) {
        do {
            outputBuffer += output

            // Process complete JSON-RPC messages (newline-delimited)
            let lines = outputBuffer.components(separatedBy: "\n")

            // Keep the last incomplete line in the buffer
            if let last = lines.last, !output.hasSuffix("\n") {
                outputBuffer = last
            } else {
                outputBuffer = ""
            }

            // Process complete lines
            for line in lines.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                processJSONRPCMessage(trimmed)
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Error handling MCP output",
                metadata: ["server": serverConfig.name, "error": error.localizedDescription]
            )
        }
    }

    private func processJSONRPCMessage(_ json: String) {
        guard let data = json.data(using: .utf8) else {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to convert JSON string to data",
                metadata: ["server": serverConfig.name]
            )
            return
        }

        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(MCPResponse.self, from: data)

            if let id = response.id {
                Task { @MainActor in
                    if let continuation = self.pendingRequests.removeValue(forKey: id) {
                        continuation.resume(returning: response)
                    } else {
                        DiagnosticsLogger.log(
                            .mcpService,
                            level: .error,
                            message: "Received response for unknown request",
                            metadata: ["id": "\(id)"]
                        )
                    }
                }
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to decode MCP response",
                metadata: ["server": serverConfig.name, "error": error.localizedDescription, "payload": json]
            )
        }
    }

    // MARK: - Parsing Helpers

    private func parseTool(from dict: [String: Any]) throws -> MCPTool {
        guard let name = dict["name"] as? String else {
            throw MCPServiceError.invalidResponse("Tool missing 'name' field")
        }

        guard let description = dict["description"] as? String else {
            throw MCPServiceError.invalidResponse("Tool '\(name)' missing 'description' field")
        }

        guard let inputSchema = dict["inputSchema"] as? [String: Any] else {
            throw MCPServiceError.invalidResponse("Tool '\(name)' missing 'inputSchema' field")
        }

        do {
            let schema = try parseJSONSchema(from: inputSchema)

            return MCPTool(
                name: name,
                description: description,
                inputSchema: schema,
                serverName: serverConfig.name
            )
        } catch {
            throw MCPServiceError.invalidResponse("Failed to parse schema for tool '\(name)': \(error.localizedDescription)")
        }
    }

    private func parseJSONSchema(from dict: [String: Any]) throws -> JSONSchema {
        guard let type = dict["type"] as? String else {
            throw MCPServiceError.invalidResponse("Missing schema type")
        }

        let properties: [String: AnyCodable]? = if let propsDict = dict["properties"] as? [String: Any] {
            propsDict.mapValues { AnyCodable($0) }
        } else {
            nil
        }

        let required = dict["required"] as? [String]

        let items: AnyCodable? = if let itemsDict = dict["items"] {
            AnyCodable(itemsDict)
        } else {
            nil
        }

        return JSONSchema(
            type: type,
            properties: properties,
            required: required,
            items: items
        )
    }

    private func parseResource(from dict: [String: Any]) -> MCPResource? {
        guard let uri = dict["uri"] as? String,
              let name = dict["name"] as? String
        else {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Skipping invalid resource",
                metadata: ["server": serverConfig.name]
            )
            return nil
        }

        return MCPResource(
            uri: uri,
            name: name,
            description: dict["description"] as? String,
            mimeType: dict["mimeType"] as? String,
            serverName: serverConfig.name
        )
    }

    // MARK: - Helper Methods

    private func findExecutable(_ command: String) throws -> String {
        // If command is already an absolute path, validate it exists
        if command.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw MCPServiceError.initializationFailed("Executable not found at path: \(command)")
            }
            return command
        }

        // Common locations to search for executables
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]

        // Search in common paths
        for path in searchPaths {
            let fullPath = "\(path)/\(command)"
            DiagnosticsLogger.log(
                .mcpService,
                level: .debug,
                message: "Checking executable path",
                metadata: ["path": fullPath]
            )
            let exists = FileManager.default.fileExists(atPath: fullPath)
            let isExecutable = FileManager.default.isExecutableFile(atPath: fullPath)
            DiagnosticsLogger.log(
                .mcpService,
                level: .debug,
                message: "Executable candidate",
                metadata: ["exists": "\(exists)", "executable": "\(isExecutable)", "path": fullPath]
            )

            if isExecutable {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .info,
                    message: "Found executable",
                    metadata: ["command": command, "path": fullPath]
                )
                return fullPath
            }
        }

        // Fallback: Try to use 'which' command with a proper shell environment
        // This is important because the sandboxed app may not have access to the same PATH
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        shellProcess.arguments = ["-l", "-c", "which \(command)"]

        // Set up environment to use the user's actual PATH
        var environment = ProcessInfo.processInfo.environment
        // Add common paths to ensure we find executables
        let commonPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = commonPaths
        shellProcess.environment = environment

        let pipe = Pipe()
        shellProcess.standardOutput = pipe
        shellProcess.standardError = Pipe()

        do {
            try shellProcess.run()
            shellProcess.waitUntilExit()

            if shellProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty,
                   FileManager.default.isExecutableFile(atPath: path)
                {
                    DiagnosticsLogger.log(
                        .mcpService,
                        level: .info,
                        message: "Found executable via shell",
                        metadata: ["command": command, "path": path]
                    )
                    return path
                }
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to find executable via shell",
                metadata: ["command": command, "error": "\(error)"]
            )
        }

        // Could not find executable
        let errorMsg = """
        Could not find executable '\(command)'.

        Please ensure Node.js and npm are installed:
        - Install via Homebrew: brew install node
        - Or download from: https://nodejs.org/

        Searched in:
        \(searchPaths.joined(separator: "\n"))
        """
        throw MCPServiceError.initializationFailed(errorMsg)
    }

    // MARK: - Connection Monitoring

    private func startHealthCheckTimer() {
        stopHealthCheckTimer()

        let queue = DispatchQueue(label: "com.ayna.mcp.healthcheck.\(serverConfig.name)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !(process?.isRunning ?? false) {
                handleProcessTermination(exitCode: process?.terminationStatus)
            }
        }
        timer.resume()
        healthCheckTimer = timer
    }

    private func stopHealthCheckTimer() {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
    }

    private func handleProcessTermination(exitCode: Int32?) {
        stopHealthCheckTimer()
        cleanupProcessResources()
        process = nil
        let message: String? =
            if let exitCode, exitCode != 0 {
                "Exited with code \(exitCode)"
            } else {
                nil
            }
        handleUnexpectedDisconnect(reason: message)
    }

    private func handleUnexpectedDisconnect(reason: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if isDisconnectingManually {
                isDisconnectingManually = false
                return
            }

            let message = reason ?? "MCP server process ended unexpectedly"
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Lost MCP connection",
                metadata: [
                    "server": serverConfig.name,
                    "reason": message
                ]
            )
            MCPProcessTracker.shared.unregister(serverName: serverConfig.name)
            lastError = message
            isConnected = false
            delegate?.mcpService(self, didTerminateWithError: message)
        }
    }

    private func cleanupProcessResources() {
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
    }
}

// MARK: - Errors

enum MCPServiceError: LocalizedError {
    case notConnected
    case encodingFailed
    case initializationFailed(String)
    case invalidResponse(String)
    case toolExecutionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to MCP server"
        case .encodingFailed:
            "Failed to encode request"
        case let .initializationFailed(message):
            "Failed to initialize MCP server: \(message)"
        case let .invalidResponse(message):
            "Invalid response from MCP server: \(message)"
        case let .toolExecutionFailed(message):
            "Tool execution failed: \(message)"
        case .timeout:
            "Operation timed out"
        }
    }
}

// MARK: - Timeout Helper

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MCPServiceError.timeout
        }

        guard let result = try await group.next() else {
            throw MCPServiceError.timeout
        }
        group.cancelAll()
        return result
    }
}
