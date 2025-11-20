//
//  MCPConnection.swift
//  ayna
//
//  Created on 11/19/25.
//

import Foundation

/// Actor responsible for low-level MCP server communication and state management
actor MCPConnection {
    private var process: Process?
    private var standardInput: Pipe?
    private var standardOutput: Pipe?
    private var standardError: Pipe?

    private var requestId = 0
    private var pendingRequests: [Int: CheckedContinuation<MCPResponse, Error>] = [:]
    
    private var buffer = Data()
    private let newline = "\n".data(using: .utf8)!

    // Callbacks for state updates
    private var onStatusChange: (@Sendable (Bool) -> Void)?
    private var onError: (@Sendable (String) -> Void)?
    // var onNotification: ((String, [String: AnyCodable]?) -> Void)? // Future use

    init() {}
    
    func setCallbacks(
        onStatusChange: (@Sendable (Bool) -> Void)?,
        onError: (@Sendable (String) -> Void)?
    ) {
        self.onStatusChange = onStatusChange
        self.onError = onError
    }

    /*
    deinit {
        // Actors don't have deinit in the same way for cleanup, 
        // but we should ensure process is terminated if the actor dies.
        // However, we can't easily do async work here.
        // Reliance on explicit disconnect is preferred.
        // process?.terminate()
    }
    */

    // MARK: - Connection Management

    func connect(config: MCPServerConfig) async throws {
        // Cleanup existing if any
        if process != nil {
            disconnect()
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Find executable
        let commandPath = try findExecutable(config.command)
        
        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = config.args

        // Environment setup
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/opt/homebrew/opt/node/bin",
            NSHomeDirectory() + "/.nvm/versions/node/*/bin",
        ]
        let existingPath = environment["PATH"] ?? ""
        let newPath = (commonPaths + [existingPath]).joined(separator: ":")
        environment["PATH"] = newPath

        if !config.env.isEmpty {
            for (key, value) in config.env {
                environment[key] = value
            }
        }
        process.environment = environment
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.standardInput = inputPipe
        self.standardOutput = outputPipe
        self.standardError = errorPipe

        // Setup Output Handling
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            Task { [weak self] in
                await self?.handleData(data)
            }
        }

        // Setup Error Handling
        let serverName = config.name
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            if let output = String(data: data, encoding: .utf8) {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .info,
                    message: "MCP server stderr",
                    metadata: ["server": serverName, "output": output]
                )
                
                if output.lowercased().contains("error") || output.lowercased().contains("failed") {
                    Task { [weak self] in
                        await self?.reportError(output)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            disconnect()
            throw MCPServiceError.initializationFailed("Failed to start process: \(error.localizedDescription)")
        }

        // Wait a bit for process to start
        try await Task.sleep(nanoseconds: 500_000_000)

        // Initialize Protocol
        do {
            try await withTimeout(seconds: 5) {
                try await self.initializeProtocol()
            }
            onStatusChange?(true)
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
        
        process?.terminate()
        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
        
        // Cancel all pending requests
        for continuation in pendingRequests.values {
            continuation.resume(throwing: MCPServiceError.notConnected)
        }
        pendingRequests.removeAll()
        buffer.removeAll()
        
        onStatusChange?(false)
    }

    // MARK: - High Level Methods

    func listTools(serverName: String) async throws -> [MCPTool] {
        let response = try await sendRequest(method: "tools/list", params: nil)

        guard let result = response.result?.value as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]]
        else {
            throw MCPServiceError.invalidResponse("Failed to parse tools list")
        }

        var validTools: [MCPTool] = []
        for toolDict in toolsArray {
            if let tool = try? parseTool(from: toolDict, serverName: serverName) {
                validTools.append(tool)
            }
        }
        return validTools
    }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> String {
        let response = try await sendRequest(
            method: "tools/call",
            params: [
                "name": AnyCodable(name),
                "arguments": AnyCodable(arguments),
            ],
        )

        guard let result = response.result?.value as? [String: Any] else {
            throw MCPServiceError.invalidResponse("Failed to parse tool call result")
        }
        
        // Log the raw result for debugging
        DiagnosticsLogger.log(
            .mcpService,
            level: .debug,
            message: "Tool call result received",
            metadata: ["result": "\(result)"]
        )

        // Check for error flag in result
        if let isError = result["isError"] as? Bool, isError {
            // If it's an error, try to extract the error message from content
            if let content = result["content"] as? [[String: Any]] {
                let errorTexts = content.compactMap { item -> String? in
                    if item["type"] as? String == "text",
                       let text = item["text"] as? String {
                        return text
                    }
                    return nil
                }
                if !errorTexts.isEmpty {
                    return "Error: " + errorTexts.joined(separator: "\n")
                }
            }
            return "Error: Tool execution failed (unknown error)"
        }

        // Handle different content types
        if let content = result["content"] as? [[String: Any]] {
            // Multiple content items
            let texts = content.compactMap { item -> String? in
                if item["type"] as? String == "text",
                   let text = item["text"] as? String
                {
                    return text
                } else if item["type"] as? String == "image",
                          let _ = item["data"] as? String,
                          let mime = item["mimeType"] as? String {
                    return "[Image: \(mime)]" // Placeholder for image support
                } else if item["type"] as? String == "resource",
                          let resource = item["resource"] as? [String: Any],
                          let uri = resource["uri"] as? String {
                    return "[Resource: \(uri)]"
                }
                return nil
            }
            
            let joinedText = texts.joined(separator: "\n")
            if joinedText.isEmpty {
                return "Tool executed successfully but returned no text content."
            }
            return joinedText
        } else if let text = result["content"] as? String {
            return text
        } else {
            // Try to dump the whole result if we can't parse specific content
            if let jsonData = try? JSONSerialization.data(withJSONObject: result),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
            throw MCPServiceError.invalidResponse("Unexpected content format in tool result")
        }
    }

    func listResources(serverName: String) async throws -> [MCPResource] {
        let response = try await sendRequest(method: "resources/list", params: nil)

        guard let result = response.result?.value as? [String: Any],
              let resourcesArray = result["resources"] as? [[String: Any]]
        else {
            throw MCPServiceError.invalidResponse("Failed to parse resources list")
        }

        return resourcesArray.compactMap { resourceDict in
            parseResource(from: resourceDict, serverName: serverName)
        }
    }

    // MARK: - Parsing Helpers

    private func parseTool(from dict: [String: Any], serverName: String) throws -> MCPTool {
        guard let name = dict["name"] as? String else {
            throw MCPServiceError.invalidResponse("Tool missing 'name' field")
        }

        guard let description = dict["description"] as? String else {
            throw MCPServiceError.invalidResponse("Tool '\(name)' missing 'description' field")
        }

        guard let inputSchema = dict["inputSchema"] as? [String: Any] else {
            throw MCPServiceError.invalidResponse("Tool '\(name)' missing 'inputSchema' field")
        }

        let schema = try parseJSONSchema(from: inputSchema)

        return MCPTool(
            name: name,
            description: description,
            inputSchema: schema,
            serverName: serverName
        )
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

    private func parseResource(from dict: [String: Any], serverName: String) -> MCPResource? {
        guard let uri = dict["uri"] as? String,
              let name = dict["name"] as? String
        else { return nil }

        return MCPResource(
            uri: uri,
            name: name,
            description: dict["description"] as? String,
            mimeType: dict["mimeType"] as? String,
            serverName: serverName
        )
    }

    // MARK: - Protocol Methods

    private func initializeProtocol() async throws {
        let response = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": AnyCodable("2024-11-05"),
                "capabilities": AnyCodable([
                    "roots": ["list_changed": true],
                    "sampling": [:],
                ] as [String: Any]),
                "clientInfo": AnyCodable([
                    "name": "ayna",
                    "version": "1.0.0",
                ] as [String: String]),
            ]
        )

        guard response.error == nil else {
            throw MCPServiceError.initializationFailed(response.error?.message ?? "Unknown error")
        }

        try await sendNotification(method: "notifications/initialized")
    }

    func sendRequest(method: String, params: [String: AnyCodable]?) async throws -> MCPResponse {
        guard process != nil else { throw MCPServiceError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            requestId += 1
            let id = requestId
            pendingRequests[id] = continuation

            let request = MCPRequest(id: id, method: method, params: params)

            do {
                let data = try JSONEncoder().encode(request)
                try sendData(data)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: [String: AnyCodable]? = nil) async throws {
        guard process != nil else { throw MCPServiceError.notConnected }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params?.mapValues { $0.value } ?? [:],
        ]

        let data = try JSONSerialization.data(withJSONObject: notification)
        try sendData(data)
    }

    private func sendData(_ data: Data) throws {
        guard let inputHandle = standardInput?.fileHandleForWriting else {
            throw MCPServiceError.notConnected
        }
        
        inputHandle.write(data)
        inputHandle.write(newline)
    }

    // MARK: - Input Handling

    private func handleData(_ data: Data) {
        buffer.append(data)

        // Process complete messages separated by newlines
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            
            if !lineData.isEmpty {
                processJSONRPCMessage(lineData)
            }
        }
    }

    private func processJSONRPCMessage(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(MCPResponse.self, from: data)

            if let id = response.id {
                if let continuation = pendingRequests.removeValue(forKey: id) {
                    continuation.resume(returning: response)
                } else {
                    // Could be a request from server to client (not supported yet) or duplicate
                    DiagnosticsLogger.log(.mcpService, level: .error, message: "Received response for unknown request ID: \(id)")
                }
            } else {
                // Notification or Request from server
                // TODO: Handle server-sent requests/notifications
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to decode MCP response",
                metadata: ["error": error.localizedDescription]
            )
        }
    }
    
    private func reportError(_ message: String) {
        onError?(message)
    }

    // MARK: - Helpers

    private func findExecutable(_ command: String) throws -> String {
        if command.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw MCPServiceError.initializationFailed("Executable not found at path: \(command)")
            }
            return command
        }

        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]

        for path in searchPaths {
            let fullPath = "\(path)/\(command)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        // Fallback to 'which'
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        shellProcess.arguments = ["-l", "-c", "which \(command)"]
        
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        shellProcess.environment = environment

        let pipe = Pipe()
        shellProcess.standardOutput = pipe
        
        try shellProcess.run()
        shellProcess.waitUntilExit()

        if shellProcess.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw MCPServiceError.initializationFailed("Could not find executable '\(command)'")
    }
}
