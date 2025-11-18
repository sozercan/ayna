//
//  MCPServerManager.swift
//  ayna
//
//  Created on 11/3/25.
//

import Foundation

/// Manages multiple MCP server connections and tool discovery
class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()

    @Published var serverConfigs: [MCPServerConfig] = []
    @Published var availableTools: [MCPTool] = []
    @Published var availableResources: [MCPResource] = []
    @Published var isDiscovering = false

    private var services: [String: MCPService] = [:] // serverName -> service
    private let queue = DispatchQueue(label: "com.ayna.mcp.manager")

    // Optimization: Cache enabled tools and their OpenAI function format
    private var cachedEnabledTools: [MCPTool] = []
    private var cachedOpenAIFunctions: [[String: Any]] = []
    private var toolLookup: [String: MCPTool] = [:] // O(1) tool lookup by name
    private var cacheVersion = 0

    private init() {
        loadServerConfigs()
    }

    // MARK: - Server Configuration Management

    func addServerConfig(_ config: MCPServerConfig) {
        serverConfigs.append(config)
        saveServerConfigs()

        if config.enabled {
            Task {
                await connectToServer(config)
            }
        }
    }

    func updateServerConfig(_ config: MCPServerConfig) {
        guard let index = serverConfigs.firstIndex(where: { $0.id == config.id }) else { return }

        let wasEnabled = serverConfigs[index].enabled
        serverConfigs[index] = config
        saveServerConfigs()

        // Invalidate cache when server configs change
        cachedEnabledTools = []
        cachedOpenAIFunctions = []

        // Handle connection state changes
        if wasEnabled, !config.enabled {
            // Disconnect in the background
            Task { @MainActor in
                disconnectServer(config.name)
            }
        } else if !wasEnabled, config.enabled {
            Task {
                await connectToServer(config)
            }
        }
    }

    @MainActor
    func removeServerConfig(_ config: MCPServerConfig) {
        disconnectServer(config.name)
        serverConfigs.removeAll { $0.id == config.id }
        saveServerConfigs()
    }

    private func saveServerConfigs() {
        if let encoded = try? JSONEncoder().encode(serverConfigs) {
            AppPreferences.storage.set(encoded, forKey: "mcp_server_configs")
        }
    }

    private func loadServerConfigs() {
        guard let data = AppPreferences.storage.data(forKey: "mcp_server_configs") else {
            // First launch: use default configs
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .info,
                message: "No saved MCP server configs; using defaults"
            )
            serverConfigs = defaultServerConfigs()
            saveServerConfigs()
            return
        }

        do {
            let decoded = try JSONDecoder().decode([MCPServerConfig].self, from: data)
            // Validate that all configs have proper string dictionaries for env
            let validatedConfigs = decoded.map { config -> MCPServerConfig in
                // Ensure env is a proper [String: String] dictionary
                // Filter out any non-string values that might have been corrupted
                var validEnv: [String: String] = [:]
                for (key, value) in config.env {
                    // Only include if both key and value are valid strings
                    if !key.isEmpty, !value.isEmpty {
                        validEnv[key] = value
                    }
                }

                return MCPServerConfig(
                    id: config.id,
                    name: config.name,
                    command: config.command,
                    args: config.args,
                    env: validEnv,
                    enabled: config.enabled
                )
            }
            serverConfigs = validatedConfigs
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .info,
                message: "Loaded MCP server configs",
                metadata: ["count": "\(serverConfigs.count)"]
            )
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to load MCP server configs",
                metadata: ["error": error.localizedDescription]
            )
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Clearing corrupted MCP config data and resetting to defaults"
            )
            // Clear corrupted data and use defaults
            AppPreferences.storage.removeObject(forKey: "mcp_server_configs")
            serverConfigs = defaultServerConfigs()
            saveServerConfigs()
        }
    }

    private func defaultServerConfigs() -> [MCPServerConfig] {
        // Use npx directly with full path
        [
            MCPServerConfig(
                name: "brave-search",
                command: "/opt/homebrew/bin/npx",
                args: ["-y", "@modelcontextprotocol/server-brave-search"],
                env: ["BRAVE_API_KEY": ""], // Add your Brave Search API key here: https://brave.com/search/api/
                enabled: false
            ),
            MCPServerConfig(
                name: "filesystem",
                command: "/opt/homebrew/bin/npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()],
                env: [:],
                enabled: false
            ),
        ]
    }

    // MARK: - Connection Management

    func connectToServer(_ config: MCPServerConfig) async {
        guard config.enabled else { return }

        // Check if already connected (thread-safe)
        let existingService = await MainActor.run {
            services[config.name]
        }

        if let existingService, existingService.isConnected {
            // Already connected - but check if we need to discover tools
            let hasTools = await MainActor.run {
                !availableTools.filter { $0.serverName == config.name }.isEmpty
            }

            if !hasTools {
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Server connected without tools; starting discovery",
                    metadata: ["server": config.name]
                )
                await discoverTools(for: config.name)
            }
            return
        }

        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Attempting to connect to MCP server",
            metadata: ["server": config.name]
        )
        let service = MCPService(serverConfig: config)

        // Store service in dictionary on MainActor for thread safety
        await MainActor.run {
            services[config.name] = service
        }

        do {
            try await service.connect()
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .info,
                message: "Connected to MCP server",
                metadata: ["server": config.name]
            )

            // Auto-discover tools (wrapped in do-catch to prevent discovery failures from crashing)
            do {
                await discoverTools(for: config.name)
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Tool discovery complete",
                    metadata: ["server": config.name]
                )
            } catch {
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .error,
                    message: "Tool discovery failed but connection maintained",
                    metadata: ["server": config.name, "error": error.localizedDescription]
                )
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to connect to MCP server",
                metadata: ["server": config.name, "error": error.localizedDescription]
            )
            await MainActor.run {
                service.lastError = error.localizedDescription

                // Auto-disable the server if it fails to connect
                if let index = self.serverConfigs.firstIndex(where: { $0.name == config.name }) {
                    var updatedConfig = self.serverConfigs[index]
                    updatedConfig.enabled = false
                    self.serverConfigs[index] = updatedConfig
                    self.saveServerConfigs()
                    DiagnosticsLogger.log(
                        .mcpServerManager,
                        level: .error,
                        message: "Auto-disabled server due to connection failure",
                        metadata: ["server": config.name]
                    )
                }

                // Clean up failed service
                self.services.removeValue(forKey: config.name)
            }
        }
    }

    @MainActor
    func disconnectServer(_ serverName: String) {
        services[serverName]?.disconnect()
        services.removeValue(forKey: serverName)

        // Remove tools from this server
        availableTools.removeAll { $0.serverName == serverName }
        availableResources.removeAll { $0.serverName == serverName }
    }

    func connectToAllEnabledServers() async {
        let enabledConfigs = serverConfigs.filter(\.enabled)
        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Connecting to enabled MCP servers",
            metadata: ["count": "\(enabledConfigs.count)", "servers": enabledConfigs.map(\.name).joined(separator: ",")]
        )

        await withTaskGroup(of: Void.self) { group in
            for config in enabledConfigs {
                group.addTask {
                    await self.connectToServer(config)
                }
            }
        }

        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "All enabled servers connected",
            metadata: ["tools": "\(availableTools.count)"]
        )
    }

    @MainActor
    func disconnectAllServers() {
        for serverName in services.keys {
            disconnectServer(serverName)
        }
    }

    // MARK: - Tool Discovery

    func discoverAllTools() async {
        await MainActor.run {
            isDiscovering = true
        }

        do {
            // Capture services snapshot to avoid concurrency issues
            let servicesSnapshot = services

            let results = await withTaskGroup(of: (String, [MCPTool], [MCPResource]).self) { group in
                for (serverName, service) in servicesSnapshot where service.isConnected {
                    group.addTask {
                        let tools = await (try? service.listTools()) ?? []
                        let resources = await (try? service.listResources()) ?? []
                        return (serverName, tools, resources)
                    }
                }

                var allTools: [MCPTool] = []
                var allResources: [MCPResource] = []

                for await (serverName, tools, resources) in group {
                    DiagnosticsLogger.log(
                        .mcpServerManager,
                        level: .info,
                        message: "Discovered tools from server",
                        metadata: ["server": serverName, "tools": "\(tools.count)"]
                    )
                    allTools.append(contentsOf: tools)
                    allResources.append(contentsOf: resources)
                }

                return (allTools, allResources)
            }

            await MainActor.run {
                self.availableTools = results.0
                self.availableResources = results.1
                self.isDiscovering = false
                // Invalidate cache when tools change
                self.cachedEnabledTools = []
                self.cachedOpenAIFunctions = []
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Error during tool discovery",
                metadata: ["error": error.localizedDescription]
            )
            await MainActor.run {
                self.isDiscovering = false
            }
        }
    }

    func discoverTools(for serverName: String) async {
        // Thread-safe access to services dictionary
        let service = await MainActor.run {
            services[serverName]
        }

        guard let service, service.isConnected else {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Cannot discover tools; service not connected",
                metadata: ["server": serverName]
            )
            return
        }

        // Discover tools and resources independently - don't let one failure block the other
        var tools: [MCPTool] = []
        var resources: [MCPResource] = []

        do {
            tools = try await service.listTools()
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .info,
                message: "Discovered tools",
                metadata: ["server": serverName, "count": "\(tools.count)"]
            )
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to list tools",
                metadata: ["server": serverName, "error": error.localizedDescription]
            )
        }

        do {
            resources = try await service.listResources()
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .info,
                message: "Discovered resources",
                metadata: ["server": serverName, "count": "\(resources.count)"]
            )
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to list resources",
                metadata: ["server": serverName, "error": error.localizedDescription]
            )
        }

        await MainActor.run {
            // Remove old tools/resources from this server
            self.availableTools.removeAll { $0.serverName == serverName }
            self.availableResources.removeAll { $0.serverName == serverName }

            // Add newly discovered items
            self.availableTools.append(contentsOf: tools)
            self.availableResources.append(contentsOf: resources)

            // Invalidate cache when tools change
            self.cachedEnabledTools = []
            self.cachedOpenAIFunctions = []
        }

        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Discovery complete",
            metadata: [
                "server": serverName,
                "tools": "\(tools.count)",
                "resources": "\(resources.count)",
            ]
        )
    }

    // MARK: - Tool Execution

    func executeTool(name: String, arguments: [String: Any]) async throws -> String {
        // Optimization: Use O(1) lookup instead of linear search
        guard let tool = toolLookup[name] ?? availableTools.first(where: { $0.name == name }) else {
            throw MCPManagerError.toolNotFound(name)
        }

        // Thread-safe access to services dictionary
        let service = await MainActor.run { services[tool.serverName] }
        guard let service, service.isConnected else {
            throw MCPManagerError.toolNotFound(name)
        }

        do {
            // Add timeout to prevent hanging tool calls
            let result = try await withTimeout(seconds: 30) {
                try await service.callTool(name: name, arguments: arguments)
            }
            return result
        } catch MCPServiceError.timeout {
            throw MCPManagerError.executionFailed(name, "Tool execution timed out after 30 seconds")
        } catch {
            throw MCPManagerError.executionFailed(name, error.localizedDescription)
        }
    }

    // MARK: - Server Status

    func isServerConnected(_ serverName: String) -> Bool {
        services[serverName]?.isConnected ?? false
    }

    func getServerError(_ serverName: String) -> String? {
        services[serverName]?.lastError
    }

    func getConnectedServerCount() -> Int {
        services.values.filter(\.isConnected).count
    }

    // MARK: - Tool Helpers

    func getToolsByServer() -> [String: [MCPTool]] {
        Dictionary(grouping: availableTools) { $0.serverName }
    }

    /// Returns all tools from enabled servers (cached for performance)
    func getEnabledTools() -> [MCPTool] {
        if cachedEnabledTools.isEmpty {
            refreshToolCache()
        }
        return cachedEnabledTools
    }

    /// Returns enabled tools in OpenAI function format (cached for performance)
    func getEnabledToolsAsOpenAIFunctions() -> [[String: Any]] {
        if cachedOpenAIFunctions.isEmpty {
            refreshToolCache()
            cachedOpenAIFunctions = cachedEnabledTools.map { $0.toOpenAIFunction() }
        }
        return cachedOpenAIFunctions
    }

    /// Refresh the enabled tools cache
    private func refreshToolCache() {
        cachedEnabledTools = availableTools.filter { tool in
            serverConfigs.first(where: { $0.name == tool.serverName })?.enabled ?? false
        }
        toolLookup = Dictionary(uniqueKeysWithValues: cachedEnabledTools.map { ($0.name, $0) })
        cachedOpenAIFunctions = [] // Invalidate OpenAI format cache
        cacheVersion += 1
    }
}

// MARK: - Errors

enum MCPManagerError: LocalizedError {
    case toolNotFound(String)
    case executionFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .toolNotFound(name):
            "Tool '\(name)' not found or server not connected"
        case let .executionFailed(name, reason):
            "Failed to execute tool '\(name)': \(reason)"
        }
    }
}
