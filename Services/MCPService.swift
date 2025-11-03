//
//  MCPService.swift
//  ayna
//
//  Created on 11/3/25.
//

import Foundation

/// Service for communicating with MCP servers via stdio
class MCPService: ObservableObject {
    private var process: Process?
    private var standardInput: Pipe?
    private var standardOutput: Pipe?
    private var standardError: Pipe?

    private var requestId = 0
    private var pendingRequests: [Int: CheckedContinuation<MCPResponse, Error>] = [:]
    private let requestQueue = DispatchQueue(label: "com.ayna.mcp.requests")

    let serverConfig: MCPServerConfig
    @Published var isConnected = false
    @Published var lastError: String?

    private var outputBuffer = ""

    init(serverConfig: MCPServerConfig) {
        self.serverConfig = serverConfig
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    func connect() async throws {
        guard !isConnected else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Find the command executable
        print("🔍 Looking for executable: \(serverConfig.command)")
        let commandPath = try findExecutable(serverConfig.command)
        print("✅ Using executable path: \(commandPath)")
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
        process.environment = environment.merging(serverConfig.env) { _, new in new }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.standardInput = inputPipe
        self.standardOutput = outputPipe
        self.standardError = errorPipe

        // Set up output reading
        let serverName = serverConfig.name
        outputPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let output = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.handleOutput(output)
                }
            }
        }

        // Set up error reading (stderr - may include info messages)
        errorPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let output = String(data: data, encoding: .utf8) {
                print("MCP Server (\(serverName)) stderr: \(output)")
                // Only treat it as an error if it contains error keywords
                if output.lowercased().contains("error") || output.lowercased().contains("failed") {
                    Task { @MainActor in
                        self?.lastError = output
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            disconnect()
            DispatchQueue.main.async {
                self.lastError = "Failed to start process: \(error.localizedDescription)"
            }
            throw MCPServiceError.initializationFailed("Process failed to start: \(error.localizedDescription)")
        }

        // Wait a bit for the process to start
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        // Initialize the connection with timeout
        // If the process has already exited, initialization will fail with a timeout
        do {
            print("🔄 Initializing MCP server: \(serverName)")
            try await withTimeout(seconds: 5) {
                try await self.initialize()
            }
            print("✅ MCP server initialized: \(serverName)")
            DispatchQueue.main.async {
                self.isConnected = true
            }
        } catch {
            print("❌ MCP initialization failed for \(serverName): \(error)")
            disconnect()
            DispatchQueue.main.async {
                self.lastError = "Initialization failed: \(error.localizedDescription)"
            }
            throw error
        }
    }

    func disconnect() {
        // Clear readability handlers to break retain cycles
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil

        process?.terminate()
        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil

        DispatchQueue.main.async {
            self.isConnected = false
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
              let toolsArray = result["tools"] as? [[String: Any]] else {
            throw MCPServiceError.invalidResponse("Failed to parse tools list")
        }

        return try toolsArray.compactMap { toolDict in
            try parseTool(from: toolDict)
        }
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
                   let text = item["text"] as? String {
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
              let resourcesArray = result["resources"] as? [[String: Any]] else {
            throw MCPServiceError.invalidResponse("Failed to parse resources list")
        }

        return resourcesArray.compactMap { resourceDict in
            parseResource(from: resourceDict)
        }
    }

    // MARK: - Low-level JSON-RPC

    private func sendRequest(method: String, params: [String: AnyCodable]?) async throws -> MCPResponse {
        return try await withCheckedThrowingContinuation { continuation in
            requestQueue.async {
                self.requestId += 1
                let id = self.requestId

                self.pendingRequests[id] = continuation

                let request = MCPRequest(id: id, method: method, params: params)

                do {
                    let data = try JSONEncoder().encode(request)
                    guard var jsonString = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: MCPServiceError.encodingFailed)
                        return
                    }

                    jsonString += "\n"

                    guard let inputHandle = self.standardInput?.fileHandleForWriting else {
                        continuation.resume(throwing: MCPServiceError.notConnected)
                        return
                    }

                    if let data = jsonString.data(using: .utf8) {
                        inputHandle.write(data)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
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
    }

    private func processJSONRPCMessage(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(MCPResponse.self, from: data)

            if let id = response.id {
                requestQueue.async {
                    if let continuation = self.pendingRequests.removeValue(forKey: id) {
                        continuation.resume(returning: response)
                    }
                }
            }
        } catch {
            print("Failed to decode MCP response: \(error)")
            print("JSON: \(json)")
        }
    }

    // MARK: - Parsing Helpers

    private func parseTool(from dict: [String: Any]) throws -> MCPTool {
        guard let name = dict["name"] as? String,
              let description = dict["description"] as? String,
              let inputSchema = dict["inputSchema"] as? [String: Any] else {
            throw MCPServiceError.invalidResponse("Invalid tool format")
        }

        let schema = try parseJSONSchema(from: inputSchema)

        return MCPTool(
            name: name,
            description: description,
            inputSchema: schema,
            serverName: serverConfig.name
        )
    }

    private func parseJSONSchema(from dict: [String: Any]) throws -> JSONSchema {
        guard let type = dict["type"] as? String else {
            throw MCPServiceError.invalidResponse("Missing schema type")
        }

        let properties: [String: AnyCodable]?
        if let propsDict = dict["properties"] as? [String: Any] {
            properties = propsDict.mapValues { AnyCodable($0) }
        } else {
            properties = nil
        }

        let required = dict["required"] as? [String]

        let items: AnyCodable?
        if let itemsDict = dict["items"] {
            items = AnyCodable(itemsDict)
        } else {
            items = nil
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
              let name = dict["name"] as? String else {
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
            print("🔍 Checking: \(fullPath)")
            let exists = FileManager.default.fileExists(atPath: fullPath)
            let isExecutable = FileManager.default.isExecutableFile(atPath: fullPath)
            print("   exists: \(exists), isExecutable: \(isExecutable)")

            if isExecutable {
                print("✅ Found executable '\(command)' at: \(fullPath)")
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
                   FileManager.default.isExecutableFile(atPath: path) {
                    print("✅ Found executable '\(command)' using shell: \(path)")
                    return path
                }
            }
        } catch {
            print("❌ Failed to find executable using shell: \(error)")
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
            return "Not connected to MCP server"
        case .encodingFailed:
            return "Failed to encode request"
        case .initializationFailed(let message):
            return "Failed to initialize MCP server: \(message)"
        case .invalidResponse(let message):
            return "Invalid response from MCP server: \(message)"
        case .toolExecutionFailed(let message):
            return "Tool execution failed: \(message)"
        case .timeout:
            return "Operation timed out"
        }
    }
}

// MARK: - Timeout Helper

func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCPServiceError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
