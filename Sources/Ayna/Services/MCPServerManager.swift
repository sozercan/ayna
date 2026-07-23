//
//  MCPServerManager.swift
//  ayna
//
//  Created on 11/3/25.
//

#if os(macOS)
import Combine
import Foundation
import os

/// Manages multiple MCP server connections and tool discovery
@MainActor
class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()

    private let serviceFactory: (MCPServerConfig) -> MCPServicing
    private let retryDelayProvider: (Int) -> TimeInterval
    private let reconnectDelayProvider: () -> TimeInterval

    @Published var serverConfigs: [MCPServerConfig] = []
    @Published var availableTools: [MCPTool] = []
    @Published var availableResources: [MCPResource] = []
    @Published var isDiscovering = false
    @Published private(set) var serverStatuses: [String: MCPServerStatus] = [:]

    private var services: [String: MCPServicing] = [:] // serverName -> service
    private var connectingServers: Set<String> = []
    private var pendingReconnects: Set<String> = []

    // Optimization: Cache enabled tools and their OpenAI function format
    private var cachedEnabledTools: [MCPTool] = []
    private var cachedOpenAIFunctions: [[String: Any]] = []
    private var toolLookup: [String: MCPTool] = [:] // O(1) tool lookup by name
    private var isToolCacheValid = false
    private var isOpenAIFunctionCacheValid = false
    private var cacheVersion = 0

    init(
        serviceFactory: @escaping (MCPServerConfig) -> MCPServicing = { MCPService(serverConfig: $0) },
        retryDelayProvider: @escaping (Int) -> TimeInterval = { pow(2.0, Double($0 - 1)) },
        reconnectDelayProvider: @escaping () -> TimeInterval = { 2 }
    ) {
        self.serviceFactory = serviceFactory
        self.retryDelayProvider = retryDelayProvider
        self.reconnectDelayProvider = reconnectDelayProvider
        loadServerConfigs()
        initializeStatusEntries()
        MCPProcessTracker.shared.cleanupOrphanedProcesses()
    }

    // MARK: - Server Configuration Management

    func addServerConfig(_ config: MCPServerConfig) {
        serverConfigs.append(config)
        saveServerConfigs()
        invalidateToolCaches()
        setStatus(for: config, state: config.enabled ? .idle : .disabled, clearExistingError: true)

        if config.enabled {
            Task {
                await connectToServer(config)
            }
        }
    }

    func updateServerConfig(_ config: MCPServerConfig) {
        guard let index = serverConfigs.firstIndex(where: { $0.id == config.id }) else { return }

        let previousConfig = serverConfigs[index]
        let wasEnabled = previousConfig.enabled
        serverConfigs[index] = config
        saveServerConfigs()

        if previousConfig.name != config.name {
            let existingStatus = serverStatuses.removeValue(forKey: previousConfig.name)
            if let existingStatus {
                setStatus(for: config, state: existingStatus.state, error: existingStatus.lastError)
            } else {
                setStatus(for: config, state: config.enabled ? .idle : .disabled)
            }
        } else {
            setStatus(for: config, state: nil)
        }

        // Invalidate cache when server configs change
        invalidateToolCaches()

        let requiresRestart = shouldRestartServer(previousConfig: previousConfig, updatedConfig: config)

        // Handle connection state changes
        if wasEnabled, !config.enabled {
            // Disconnect in the background
            Task { @MainActor in
                disconnectServer(config.name)
            }
            setStatus(for: config, state: .disabled)
        } else if !wasEnabled, config.enabled {
            setStatus(for: config, state: .idle, clearExistingError: true)
            Task {
                await connectToServer(config)
            }
        } else if requiresRestart {
            Task {
                await restartServer(previousName: previousConfig.name, with: config)
            }
        }
    }

    @MainActor
    func removeServerConfig(_ config: MCPServerConfig) {
        disconnectServer(config.name)
        serverConfigs.removeAll { $0.id == config.id }
        saveServerConfigs()
        serverStatuses.removeValue(forKey: config.name)
        invalidateToolCaches()
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
                for (key, value) in config.env where !key.isEmpty {
                    validEnv[key] = value
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
        // No default servers - users add their own
        []
    }

    // MARK: - Connection Management

    func connectToServer(_ config: MCPServerConfig, autoDisableOnFailure: Bool = true) async {
        guard config.enabled else {
            setStatus(for: config, state: .disabled)
            return
        }

        if let existingService = services[config.name], existingService.isConnected {
            let hasTools = !availableTools.filter { $0.serverName == config.name }.isEmpty

            if !hasTools {
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Server connected without tools; starting discovery",
                    metadata: ["server": config.name]
                )
                await discoverTools(for: config.name)
            }
            setStatus(for: config, state: .connected)
            return
        }

        setStatus(for: config, state: .connecting)

        if connectingServers.contains(config.name) {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .debug,
                message: "Connection attempt already in progress",
                metadata: ["server": config.name]
            )
            return
        }

        connectingServers.insert(config.name)
        defer { connectingServers.remove(config.name) }

        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Attempting to connect to MCP server",
            metadata: ["server": config.name]
        )

        if let existing = services[config.name] {
            existing.delegate = nil
            existing.disconnect()
        }
        let service = serviceFactory(config)
        service.delegate = self
        services[config.name] = service

        let maxAttempts = 3
        for attempt in 1 ... maxAttempts {
            do {
                try await service.connect()
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Connected to MCP server",
                    metadata: [
                        "server": config.name,
                        "attempt": "#\(attempt)"
                    ]
                )

                await discoverTools(for: config.name)
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Tool discovery complete",
                    metadata: ["server": config.name]
                )
                setStatus(for: config, state: .connected, clearExistingError: true)
                return
            } catch {
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .error,
                    message: "Failed to connect to MCP server",
                    metadata: [
                        "server": config.name,
                        "attempt": "#\(attempt)",
                        "error": error.localizedDescription
                    ]
                )

                service.disconnect()

                if attempt < maxAttempts {
                    let delay = max(TimeInterval.zero, retryDelayProvider(attempt))
                    DiagnosticsLogger.log(
                        .mcpServerManager,
                        level: .info,
                        message: "Retrying connection",
                        metadata: [
                            "server": config.name,
                            "delay": "\(delay)s"
                        ]
                    )
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    continue
                }

                service.lastError = error.localizedDescription
                services.removeValue(forKey: config.name)
                setStatus(for: config, state: .error(error.localizedDescription))

                if autoDisableOnFailure,
                   let index = serverConfigs.firstIndex(where: { $0.name == config.name })
                {
                    var updatedConfig = serverConfigs[index]
                    updatedConfig.enabled = false
                    serverConfigs[index] = updatedConfig
                    saveServerConfigs()
                    DiagnosticsLogger.log(
                        .mcpServerManager,
                        level: .error,
                        message: "Auto-disabled server due to repeated connection failures",
                        metadata: ["server": config.name]
                    )
                    setStatus(for: updatedConfig, state: .disabled)
                }

                availableTools.removeAll { $0.serverName == config.name }
                availableResources.removeAll { $0.serverName == config.name }
                invalidateToolCaches()
                refreshStatusToolCount(for: config.name)
                break
            }
        }
    }

    private func shouldRestartServer(previousConfig: MCPServerConfig, updatedConfig: MCPServerConfig) -> Bool {
        guard previousConfig.enabled, updatedConfig.enabled else { return false }

        let changedName = previousConfig.name != updatedConfig.name
        let changedCommand = previousConfig.command != updatedConfig.command
        let changedArgs = previousConfig.args != updatedConfig.args
        let changedEnv = previousConfig.env != updatedConfig.env

        return changedName || changedCommand || changedArgs || changedEnv
    }

    private func restartServer(previousName: String?, with config: MCPServerConfig) async {
        let nameToDisconnect = previousName ?? config.name
        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Restarting MCP server to apply config changes",
            metadata: [
                "server": config.name,
                "previous": nameToDisconnect
            ]
        )

        disconnectServer(nameToDisconnect)
        setStatus(for: config, state: .connecting, clearExistingError: true)
        await connectToServer(config, autoDisableOnFailure: false)
    }

    private func scheduleReconnect(for config: MCPServerConfig) {
        guard !pendingReconnects.contains(config.name) else {
            return
        }

        pendingReconnects.insert(config.name)
        setStatus(for: config, state: .reconnecting)
        let delaySeconds = max(TimeInterval.zero, reconnectDelayProvider())
        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Scheduling MCP reconnect",
            metadata: [
                "server": config.name,
                "delay": "\(delaySeconds)s"
            ]
        )

        Task { [weak self] in
            guard let self else { return }
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }

            await performScheduledReconnect(for: config.name)
        }
    }

    @MainActor
    private func performScheduledReconnect(for serverName: String) async {
        pendingReconnects.remove(serverName)

        guard let latestConfig = serverConfigs.first(where: { $0.name == serverName }),
              latestConfig.enabled
        else {
            if let config = serverConfigs.first(where: { $0.name == serverName }) {
                setStatus(for: config, state: .disabled)
            }
            return
        }

        setStatus(for: latestConfig, state: .connecting)
        await connectToServer(latestConfig, autoDisableOnFailure: false)
    }

    @MainActor
    func disconnectServer(_ serverName: String) {
        services[serverName]?.disconnect()
        services.removeValue(forKey: serverName)
        pendingReconnects.remove(serverName)

        // Remove tools from this server
        availableTools.removeAll { $0.serverName == serverName }
        availableResources.removeAll { $0.serverName == serverName }
        invalidateToolCaches()
        refreshStatusToolCount(for: serverName)

        if let config = serverConfigs.first(where: { $0.name == serverName }) {
            let newState: MCPServerStatus.State = config.enabled ? .idle : .disabled
            setStatus(for: config, state: newState)
        }
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

    private struct DiscoveryResult: Sendable {
        let serverName: String
        let tools: [MCPTool]
        let resources: [MCPResource]
    }

    func discoverAllTools() async {
        isDiscovering = true

        // Capture services snapshot to avoid concurrency issues
        let servicesSnapshot = services.filter { $0.value.isConnected }

        let results = await withTaskGroup(of: DiscoveryResult.self) { group in
            for (serverName, service) in servicesSnapshot {
                group.addTask {
                    await Self.discoverCatalog(from: service, serverName: serverName)
                }
            }

            var discoveredResults: [DiscoveryResult] = []
            for await result in group {
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Discovered MCP catalog from server",
                    metadata: [
                        "server": result.serverName,
                        "tools": "\(result.tools.count)",
                        "resources": "\(result.resources.count)"
                    ]
                )
                discoveredResults.append(result)
            }

            return discoveredResults
        }

        availableTools = results.flatMap(\.tools)
        availableResources = results.flatMap(\.resources)
        isDiscovering = false
        // Invalidate cache when tools change
        invalidateToolCaches()
        refreshAllStatusToolCounts()
    }

    func discoverTools(for serverName: String) async {
        guard let service = services[serverName], service.isConnected else {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Cannot discover tools; service not connected",
                metadata: ["server": serverName]
            )
            return
        }

        // Discover tools and resources independently - don't let one failure block the other
        let result = await Self.discoverCatalog(from: service, serverName: serverName)

        // Remove old tools/resources from this server
        availableTools.removeAll { $0.serverName == serverName }
        availableResources.removeAll { $0.serverName == serverName }

        // Add newly discovered items
        availableTools.append(contentsOf: result.tools)
        availableResources.append(contentsOf: result.resources)

        // Invalidate cache when tools change
        invalidateToolCaches()
        refreshStatusToolCount(for: serverName)

        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Discovery complete",
            metadata: [
                "server": serverName,
                "tools": "\(result.tools.count)",
                "resources": "\(result.resources.count)"
            ]
        )
    }

    private nonisolated static func discoverCatalog(
        from service: MCPServicing,
        serverName: String
    ) async -> DiscoveryResult {
        async let tools = listTools(from: service, serverName: serverName)
        async let resources = listResources(from: service, serverName: serverName)

        return await DiscoveryResult(
            serverName: serverName,
            tools: tools,
            resources: resources
        )
    }

    private nonisolated static func listTools(
        from service: MCPServicing,
        serverName: String
    ) async -> [MCPTool] {
        do {
            let tools = try await service.listTools()
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .info,
                message: "Discovered tools",
                metadata: ["server": serverName, "count": "\(tools.count)"]
            )
            return tools
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to list tools",
                metadata: ["server": serverName, "error": error.localizedDescription]
            )
            return []
        }
    }

    private nonisolated static func listResources(
        from service: MCPServicing,
        serverName: String
    ) async -> [MCPResource] {
        do {
            let resources = try await service.listResources()
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .info,
                message: "Discovered resources",
                metadata: ["server": serverName, "count": "\(resources.count)"]
            )
            return resources
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to list resources",
                metadata: ["server": serverName, "error": error.localizedDescription]
            )
            return []
        }
    }

    // MARK: - Tool Execution

    nonisolated func executeTool(name: String, arguments: [String: Any]) async throws -> String {
        struct ToolExecutionContext: @unchecked Sendable {
            let service: MCPServicing
            let arguments: [String: AnyCodable]
        }

        let sendableArguments = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
            result[pair.key] = AnyCodable(pair.value)
        }

        let context = try await MainActor.run { () throws -> ToolExecutionContext in
            // Optimization: Use O(1) lookup instead of linear search
            guard let tool = toolLookup[name] ?? availableTools.first(where: { $0.name == name }) else {
                throw MCPManagerError.toolNotFound(name)
            }

            guard let service = services[tool.serverName], service.isConnected else {
                throw MCPManagerError.toolNotFound(name)
            }

            return ToolExecutionContext(service: service, arguments: sendableArguments)
        }

        do {
            return try await withTimeout(seconds: 30) {
                let bridgedArguments = context.arguments.mapValues { $0.value }
                return try await context.service.callTool(name: name, arguments: bridgedArguments)
            }
        } catch MCPServiceError.timeout {
            throw MCPManagerError.executionFailed(name, "Tool execution timed out after 30 seconds")
        } catch {
            throw MCPManagerError.executionFailed(name, error.localizedDescription)
        }
    }

    // MARK: - Server Status

    func isServerConnected(_ serverName: String) -> Bool {
        if case .connected? = serverStatuses[serverName]?.state {
            return true
        }
        return services[serverName]?.isConnected ?? false
    }

    func getServerError(_ serverName: String) -> String? {
        serverStatuses[serverName]?.lastError ?? services[serverName]?.lastError
    }

    func getConnectedServerCount() -> Int {
        serverStatuses.values.count(where: {
            if case .connected = $0.state {
                return true
            }
            return false
        })
    }

    func getServerStatus(_ serverName: String) -> MCPServerStatus? {
        serverStatuses[serverName]
    }

    // MARK: - Tool Helpers

    func getToolsByServer() -> [String: [MCPTool]] {
        Dictionary(grouping: availableTools) { $0.serverName }
    }

    /// Returns all tools from enabled servers (cached for performance)
    func getEnabledTools() -> [MCPTool] {
        if !isToolCacheValid {
            refreshToolCache()
        }
        return cachedEnabledTools
    }

    /// Returns enabled tools in OpenAI function format (cached for performance)
    func getEnabledToolsAsOpenAIFunctions() -> [[String: Any]] {
        if !isToolCacheValid {
            refreshToolCache()
        }
        if !isOpenAIFunctionCacheValid {
            cachedOpenAIFunctions = cachedEnabledTools.map { $0.toOpenAIFunction() }
            isOpenAIFunctionCacheValid = true
        }
        return cachedOpenAIFunctions
    }

    /// Mark tool-derived caches stale after config or discovery changes.
    private func invalidateToolCaches() {
        cachedEnabledTools = []
        cachedOpenAIFunctions = []
        toolLookup = [:]
        isToolCacheValid = false
        isOpenAIFunctionCacheValid = false
    }

    /// Refresh the enabled tools cache.
    private func refreshToolCache() {
        let enabledServerNames = Set(serverConfigs.lazy.filter(\.enabled).map(\.name))
        cachedEnabledTools = availableTools.filter { tool in
            enabledServerNames.contains(tool.serverName)
        }
        toolLookup = Dictionary(cachedEnabledTools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        cachedOpenAIFunctions = [] // Invalidate OpenAI format cache
        isToolCacheValid = true
        isOpenAIFunctionCacheValid = false
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

// MARK: - MCPServiceDelegate

extension MCPServerManager: MCPServiceDelegate {
    func mcpService(_ service: MCPServicing, didTerminateWithError error: String?) {
        let serverName = service.serverConfig.name
        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .error,
            message: "MCP service disconnected",
            metadata: [
                "server": serverName,
                "error": error ?? "unknown"
            ]
        )

        services.removeValue(forKey: serverName)
        availableTools.removeAll { $0.serverName == serverName }
        availableResources.removeAll { $0.serverName == serverName }
        invalidateToolCaches()

        guard let config = serverConfigs.first(where: { $0.name == serverName }), config.enabled else {
            if let config = serverConfigs.first(where: { $0.name == serverName }) {
                setStatus(for: config, state: .disabled, error: error)
            }
            return
        }

        setStatus(for: config, state: .reconnecting, error: error)
        scheduleReconnect(for: config)
    }
}

// MARK: - Status Helpers

private extension MCPServerManager {
    func initializeStatusEntries() {
        let now = Date()
        serverStatuses = Dictionary(
            uniqueKeysWithValues: serverConfigs.map { config in
                (
                    config.name,
                    MCPServerStatus(
                        configID: config.id,
                        name: config.name,
                        state: config.enabled ? .idle : .disabled,
                        lastError: nil,
                        toolsCount: availableTools.count(where: { $0.serverName == config.name }),
                        lastUpdated: now
                    )
                )
            }
        )
    }

    func setStatus(
        for config: MCPServerConfig,
        state: MCPServerStatus.State?,
        error: String? = nil,
        clearExistingError: Bool = false
    ) {
        let existingStatus = serverStatuses[config.name]
        let resolvedState = state ?? existingStatus?.state ?? (config.enabled ? .idle : .disabled)

        var resolvedError = error ?? existingStatus?.lastError
        if clearExistingError {
            resolvedError = nil
        }
        if case let .error(message) = resolvedState {
            resolvedError = message
        }

        let toolCount = availableTools.count(where: { $0.serverName == config.name })
        serverStatuses[config.name] = MCPServerStatus(
            configID: config.id,
            name: config.name,
            state: resolvedState,
            lastError: resolvedError,
            toolsCount: toolCount,
            lastUpdated: Date()
        )
    }

    func refreshStatusToolCount(for serverName: String) {
        guard let config = serverConfigs.first(where: { $0.name == serverName }) else { return }
        setStatus(for: config, state: nil)
    }

    func refreshAllStatusToolCounts() {
        for config in serverConfigs {
            setStatus(for: config, state: nil)
        }
    }
}
#endif
