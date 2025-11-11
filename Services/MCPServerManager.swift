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

        // Handle connection state changes
        if wasEnabled && !config.enabled {
            // Disconnect in the background
            Task { @MainActor in
                disconnectServer(config.name)
            }
        } else if !wasEnabled && config.enabled {
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
            UserDefaults.standard.set(encoded, forKey: "mcp_server_configs")
        }
    }

    private func loadServerConfigs() {
        if let data = UserDefaults.standard.data(forKey: "mcp_server_configs"),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            serverConfigs = decoded
        } else {
            // First launch: use default configs
            serverConfigs = defaultServerConfigs()
            saveServerConfigs()
        }
    }

    private func defaultServerConfigs() -> [MCPServerConfig] {
        // Use npx directly with full path
        return [
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
            )
        ]
    }

    // MARK: - Connection Management

    func connectToServer(_ config: MCPServerConfig) async {
        guard config.enabled else { return }

        // Don't reconnect if already connected
        if services[config.name]?.isConnected == true {
            return
        }

        let service = MCPService(serverConfig: config)
        services[config.name] = service

        do {
            try await service.connect()
            print("✅ Connected to MCP server: \(config.name)")

            // Auto-discover tools
            await discoverTools(for: config.name)
        } catch {
            print("❌ Failed to connect to \(config.name): \(error.localizedDescription)")
            await MainActor.run {
                service.lastError = error.localizedDescription

                // Auto-disable the server if it fails to connect
                if let index = self.serverConfigs.firstIndex(where: { $0.name == config.name }) {
                    var updatedConfig = self.serverConfigs[index]
                    updatedConfig.enabled = false
                    self.serverConfigs[index] = updatedConfig
                    self.saveServerConfigs()
                    print("⚠️ Auto-disabled server '\(config.name)' due to connection failure")
                }
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
        await withTaskGroup(of: Void.self) { group in
            for config in serverConfigs where config.enabled {
                group.addTask {
                    await self.connectToServer(config)
                }
            }
        }
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

        // Capture services snapshot to avoid concurrency issues
        let servicesSnapshot = services

        let results = await withTaskGroup(of: (String, [MCPTool], [MCPResource]).self) { group in
            for (serverName, service) in servicesSnapshot where service.isConnected {
                group.addTask {
                    let tools = (try? await service.listTools()) ?? []
                    let resources = (try? await service.listResources()) ?? []
                    return (serverName, tools, resources)
                }
            }

            var allTools: [MCPTool] = []
            var allResources: [MCPResource] = []
            
            for await (serverName, tools, resources) in group {
                print("Discovered \(tools.count) tools from \(serverName)")
                allTools.append(contentsOf: tools)
                allResources.append(contentsOf: resources)
            }
            
            return (allTools, allResources)
        }

        await MainActor.run {
            self.availableTools = results.0
            self.availableResources = results.1
            self.isDiscovering = false
        }
    }

    func discoverTools(for serverName: String) async {
        guard let service = services[serverName], service.isConnected else {
            return
        }

        do {
            let tools = try await service.listTools()
            let resources = try await service.listResources()

            await MainActor.run {
                // Remove old tools from this server
                self.availableTools.removeAll { $0.serverName == serverName }
                self.availableResources.removeAll { $0.serverName == serverName }

                // Add new tools
                self.availableTools.append(contentsOf: tools)
                self.availableResources.append(contentsOf: resources)
            }

            print("Discovered \(tools.count) tools from \(serverName)")
        } catch {
            print("Failed to discover tools from \(serverName): \(error)")
        }
    }

    // MARK: - Tool Execution

    func executeTool(name: String, arguments: [String: Any]) async throws -> String {
        // Find which server provides this tool
        guard let tool = availableTools.first(where: { $0.name == name }),
              let service = services[tool.serverName],
              service.isConnected else {
            throw MCPManagerError.toolNotFound(name)
        }

        do {
            let result = try await service.callTool(name: name, arguments: arguments)
            return result
        } catch {
            throw MCPManagerError.executionFailed(name, error.localizedDescription)
        }
    }

    // MARK: - Server Status

    func isServerConnected(_ serverName: String) -> Bool {
        return services[serverName]?.isConnected ?? false
    }

    func getServerError(_ serverName: String) -> String? {
        return services[serverName]?.lastError
    }

    func getConnectedServerCount() -> Int {
        return services.values.filter { $0.isConnected }.count
    }

    // MARK: - Tool Helpers

    func getToolsByServer() -> [String: [MCPTool]] {
        Dictionary(grouping: availableTools) { $0.serverName }
    }

    func getEnabledTools() -> [MCPTool] {
        return availableTools.filter { tool in
            serverConfigs.first(where: { $0.name == tool.serverName })?.enabled ?? false
        }
    }
}

// MARK: - Errors

enum MCPManagerError: LocalizedError {
    case toolNotFound(String)
    case executionFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool '\(name)' not found or server not connected"
        case .executionFailed(let name, let reason):
            return "Failed to execute tool '\(name)': \(reason)"
        }
    }
}
