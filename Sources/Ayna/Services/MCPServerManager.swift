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

@MainActor
private final class MCPServiceGenerationDelegate: MCPServiceDelegate {
    weak var manager: MCPServerManager?
    let serverName: String
    let generation: UInt64

    init(manager: MCPServerManager, serverName: String, generation: UInt64) {
        self.manager = manager
        self.serverName = serverName
        self.generation = generation
    }

    func mcpService(_ service: MCPServicing, didTerminateWithError error: String?) {
        manager?.handleServiceTermination(
            service,
            serverName: serverName,
            generation: generation,
            error: error
        )
    }
}

@MainActor
private struct ManagedMCPService {
    let configID: UUID
    let generation: UInt64
    let service: MCPServicing
    let delegate: MCPServiceGenerationDelegate
}

private struct ManagedMCPTask: Sendable {
    let operationID: UUID
    let generation: UInt64
    let task: Task<Void, Never>

    init(operationID: UUID = UUID(), generation: UInt64, task: Task<Void, Never>) {
        self.operationID = operationID
        self.generation = generation
        self.task = task
    }
}

// swiftlint:disable type_body_length
/// Manages multiple MCP server connections and tool discovery
@MainActor
class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()

    private let serviceFactory: (MCPServerConfig) -> MCPServicing
    private let retryDelayProvider: (Int) -> TimeInterval
    private let reconnectDelayProvider: () -> TimeInterval
    private let reconnectSleeper: @MainActor @Sendable (TimeInterval) async throws -> Void

    @Published var serverConfigs: [MCPServerConfig] = []
    @Published var availableTools: [MCPTool] = []
    @Published var availableResources: [MCPResource] = []
    @Published var isDiscovering = false
    @Published private(set) var serverStatuses: [String: MCPServerStatus] = [:]

        private var services: [String: ManagedMCPService] = [:]
        private var serverGenerations: [String: UInt64] = [:]
        private var connectionTasks: [String: ManagedMCPTask] = [:]
        private var reconnectTasks: [String: ManagedMCPTask] = [:]
        private var discoveryTasks: [String: ManagedMCPTask] = [:]
        private var committedDiscoveryGenerations: [String: UInt64] = [:]
        private var discoveryBatchTask: ManagedMCPTask?
        private var discoveryBatchGeneration: UInt64 = 0

    // Optimization: Cache enabled tools and their OpenAI function format
    private var cachedEnabledTools: [MCPTool] = []
    private var cachedOpenAIFunctions: [[String: Any]] = []
    private var toolLookup: [String: MCPTool] = [:] // O(1) tool lookup by name
    private var cacheVersion = 0

    init(
        serviceFactory: @escaping (MCPServerConfig) -> MCPServicing = { MCPService(serverConfig: $0) },
        retryDelayProvider: @escaping (Int) -> TimeInterval = { pow(2.0, Double($0 - 1)) },
        reconnectDelayProvider: @escaping () -> TimeInterval = { 2 },
        reconnectSleeper: @escaping @MainActor @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.serviceFactory = serviceFactory
        self.retryDelayProvider = retryDelayProvider
        self.reconnectDelayProvider = reconnectDelayProvider
        self.reconnectSleeper = reconnectSleeper
        loadServerConfigs()
        initializeStatusEntries()
        MCPProcessTracker.shared.cleanupOrphanedProcesses()
    }

    // MARK: - Server Configuration Management

    func addServerConfig(_ config: MCPServerConfig) {
        serverConfigs.append(config)
        saveServerConfigs()
        setStatus(for: config, state: config.enabled ? .idle : .disabled, clearExistingError: true)

        if config.enabled {
                launchConnection(to: config)
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
        cachedEnabledTools = []
        cachedOpenAIFunctions = []

        let requiresRestart = shouldRestartServer(previousConfig: previousConfig, updatedConfig: config)

        // Handle connection state changes
        if wasEnabled, !config.enabled {
                disconnectServer(previousConfig.name)
            setStatus(for: config, state: .disabled)
        } else if !wasEnabled, config.enabled {
                if previousConfig.name != config.name {
                    disconnectServer(previousConfig.name)
            }
                setStatus(for: config, state: .idle, clearExistingError: true)
                launchConnection(to: config)
        } else if requiresRestart {
                restartServer(previousName: previousConfig.name, with: config)
        }
    }

    @MainActor
    func removeServerConfig(_ config: MCPServerConfig) {
        disconnectServer(config.name)
        serverConfigs.removeAll { $0.id == config.id }
        saveServerConfigs()
        serverStatuses.removeValue(forKey: config.name)
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

        func connectToServer(_ requestedConfig: MCPServerConfig, autoDisableOnFailure: Bool = true) async {
            guard let config = currentConfig(matching: requestedConfig) else { return }
        guard config.enabled else {
            setStatus(for: config, state: .disabled)
            return
        }

            if let managed = services[config.name], managed.service.isConnected {
                if !availableTools.contains(where: { $0.serverName == config.name }),
                   let operation = startDiscoveryOperation(
                       serverName: config.name,
                       generation: managed.generation,
                       service: managed.service
                )
                {
                    await awaitOperation(operation)
                }
                if isCurrentService(managed.service, serverName: config.name, generation: managed.generation) {
                    setStatus(for: config, state: .connected, clearExistingError: true)
            }
            return
        }

            guard let operation = startConnectionOperation(
                config: config,
                autoDisableOnFailure: autoDisableOnFailure
            ) else {
                return
            }
            await awaitOperation(operation)
        }

        private func launchConnection(to requestedConfig: MCPServerConfig, autoDisableOnFailure: Bool = true) {
            guard let config = currentConfig(matching: requestedConfig), config.enabled else { return }

            if let managed = services[config.name], managed.service.isConnected {
                if !availableTools.contains(where: { $0.serverName == config.name }) {
                    _ = startDiscoveryOperation(
                        serverName: config.name,
                        generation: managed.generation,
                        service: managed.service
            )
                }
            return
        }
            _ = startConnectionOperation(config: config, autoDisableOnFailure: autoDisableOnFailure)
        }

        private func startConnectionOperation(
            config: MCPServerConfig,
            autoDisableOnFailure: Bool
        ) -> ManagedMCPTask? {
            if let existing = connectionTasks[config.name],
               existing.generation == serverGenerations[config.name]
            {
                return existing
            }

            let generation = advanceGeneration(for: config.name)
            cancelServerTasks(for: config.name)

            if let previous = services.removeValue(forKey: config.name) {
                previous.service.delegate = nil
                previous.service.disconnect()
            }
            removeArtifacts(for: config.name)

            let service = serviceFactory(config)
            let delegate = MCPServiceGenerationDelegate(
                manager: self,
                serverName: config.name,
                generation: generation
            )
            service.delegate = delegate
            services[config.name] = ManagedMCPService(
                configID: config.id,
                generation: generation,
                service: service,
                delegate: delegate
            )
            setStatus(for: config, state: .connecting, clearExistingError: true)

            let task = Task { @MainActor [weak self, service] in
                guard let self else { return }
                await self.runConnection(
                    config: config,
                    service: service,
                    generation: generation,
                    autoDisableOnFailure: autoDisableOnFailure
                )
                self.clearConnectionTask(serverName: config.name, generation: generation)
            }
            let operation = ManagedMCPTask(generation: generation, task: task)
            connectionTasks[config.name] = operation
            return operation
        }

        private func runConnection(
            config: MCPServerConfig,
            service: MCPServicing,
            generation: UInt64,
            autoDisableOnFailure: Bool
        ) async {
        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Attempting to connect to MCP server",
                metadata: ["server": config.name, "generation": "\(generation)"]
        )

        let maxAttempts = 3
        for attempt in 1 ... maxAttempts {
                guard isCurrentService(service, serverName: config.name, generation: generation),
                      !Task.isCancelled
                else {
                    service.disconnect()
                    return
                }

            do {
                try await service.connect()
                    try Task.checkCancellation()
                    guard isCurrentService(service, serverName: config.name, generation: generation) else {
                        service.disconnect()
                        return
                    }

                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Connected to MCP server",
                    metadata: [
                        "server": config.name,
                            "attempt": "#\(attempt)",
                            "generation": "\(generation)"
                    ]
                )

                    guard let discovery = startDiscoveryOperation(
                        serverName: config.name,
                        generation: generation,
                        service: service
                    ) else {
                        service.disconnect()
                        return
                    }
                    await awaitOperation(discovery)
                    try Task.checkCancellation()
                    var lastAwaitedOperationID = discovery.operationID
                    while committedDiscoveryGenerations[config.name] != generation,
                          let replacement = discoveryTasks[config.name],
                          replacement.generation == generation,
                          replacement.operationID != lastAwaitedOperationID
                    {
                        lastAwaitedOperationID = replacement.operationID
                        await awaitOperation(replacement)
                        try Task.checkCancellation()
                    }
                    guard committedDiscoveryGenerations[config.name] == generation else {
                        cancelConnectionGeneration(service: service, config: config, generation: generation)
                        return
                    }
                    guard isCurrentService(service, serverName: config.name, generation: generation) else {
                        service.disconnect()
                        return
                    }

                setStatus(for: config, state: .connected, clearExistingError: true)
                return
                } catch is CancellationError {
                    cancelConnectionGeneration(service: service, config: config, generation: generation)
                    return
            } catch {
                    guard isCurrentService(service, serverName: config.name, generation: generation) else {
                        service.disconnect()
                        return
                    }

                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .error,
                    message: "Failed to connect to MCP server",
                    metadata: [
                        "server": config.name,
                        "attempt": "#\(attempt)",
                            "error": error.localizedDescription,
                            "generation": "\(generation)"
                    ]
                )
                service.disconnect()

                if attempt < maxAttempts {
                    let delay = max(TimeInterval.zero, retryDelayProvider(attempt))
                        if delay > 0 {
                            do {
                                try await Task.sleep(for: .seconds(delay))
                            } catch {
                                cancelConnectionGeneration(service: service, config: config, generation: generation)
                                return
                            }
                        }
                        continue
                    }

                    finishFailedConnection(
                        service: service,
                        config: config,
                        generation: generation,
                        error: error,
                        autoDisableOnFailure: autoDisableOnFailure
                    )
                    return
                }
            }
        }

        private func cancelConnectionGeneration(
            service: MCPServicing,
            config: MCPServerConfig,
            generation: UInt64
        ) {
            service.disconnect()
            guard isCurrentService(service, serverName: config.name, generation: generation) else { return }

            service.delegate = nil
            services.removeValue(forKey: config.name)
            cancelDiscoveryTask(for: config.name, generation: generation)
            removeArtifacts(for: config.name)
            if let latest = currentConfig(matching: config) {
                setStatus(for: latest, state: latest.enabled ? .idle : .disabled)
            }
                    DiagnosticsLogger.log(
                        .mcpServerManager,
                        level: .info,
                message: "MCP server connection cancelled",
                metadata: ["server": config.name, "generation": "\(generation)"]
                    )
                }

        private func finishFailedConnection(
            service: MCPServicing,
            config: MCPServerConfig,
            generation: UInt64,
            error: Error,
            autoDisableOnFailure: Bool
        ) {
            guard isCurrentService(service, serverName: config.name, generation: generation) else { return }

                service.lastError = error.localizedDescription
            service.delegate = nil
                services.removeValue(forKey: config.name)
            cancelDiscoveryTask(for: config.name, generation: generation)
            removeArtifacts(for: config.name)
                setStatus(for: config, state: .error(error.localizedDescription))

            guard autoDisableOnFailure,
                  let index = serverConfigs.firstIndex(where: { $0.id == config.id })
            else {
                return
            }

                    var updatedConfig = serverConfigs[index]
                    updatedConfig.enabled = false
                    serverConfigs[index] = updatedConfig
                    saveServerConfigs()
            setStatus(for: updatedConfig, state: .disabled)
                    DiagnosticsLogger.log(
                        .mcpServerManager,
                        level: .error,
                        message: "Auto-disabled server due to repeated connection failures",
                        metadata: ["server": config.name]
                    )
    }

    private func shouldRestartServer(previousConfig: MCPServerConfig, updatedConfig: MCPServerConfig) -> Bool {
        guard previousConfig.enabled, updatedConfig.enabled else { return false }
            return previousConfig.name != updatedConfig.name
                || previousConfig.command != updatedConfig.command
                || previousConfig.args != updatedConfig.args
                || previousConfig.env != updatedConfig.env
    }

        private func restartServer(previousName: String, with config: MCPServerConfig) {
        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Restarting MCP server to apply config changes",
                metadata: ["server": config.name, "previous": previousName]
        )
            disconnectServer(previousName)
        setStatus(for: config, state: .connecting, clearExistingError: true)
            launchConnection(to: config, autoDisableOnFailure: false)
    }

        private func scheduleReconnect(for config: MCPServerConfig, generation: UInt64) {
            guard serverGenerations[config.name] == generation,
                  reconnectTasks[config.name] == nil
            else {
            return
        }

        setStatus(for: config, state: .reconnecting)
        let delaySeconds = max(TimeInterval.zero, reconnectDelayProvider())
            let task = Task { @MainActor [weak self] in
            guard let self else { return }
                do {
            if delaySeconds > 0 {
                        try await reconnectSleeper(delaySeconds)
            }
                    try Task.checkCancellation()
                } catch {
                    self.clearReconnectTask(serverName: config.name, generation: generation)
                    return
                }
                self.performScheduledReconnect(serverName: config.name, generation: generation)
        }
            reconnectTasks[config.name] = ManagedMCPTask(generation: generation, task: task)
    }

        private func performScheduledReconnect(serverName: String, generation: UInt64) {
            guard reconnectTasks[serverName]?.generation == generation else { return }
            reconnectTasks.removeValue(forKey: serverName)

            guard serverGenerations[serverName] == generation,
                  let config = serverConfigs.first(where: { $0.name == serverName }),
                  config.enabled
        else {
            return
        }
            launchConnection(to: config, autoDisableOnFailure: false)
    }

    func disconnectServer(_ serverName: String) {
            _ = advanceGeneration(for: serverName)
            cancelServerTasks(for: serverName)

            if let managed = services.removeValue(forKey: serverName) {
                managed.service.delegate = nil
                managed.service.disconnect()
            }
            removeArtifacts(for: serverName)

        if let config = serverConfigs.first(where: { $0.name == serverName }) {
                setStatus(for: config, state: config.enabled ? .idle : .disabled)
        }
    }

    func connectToAllEnabledServers() async {
        let enabledConfigs = serverConfigs.filter(\.enabled)
            for config in enabledConfigs {
                launchConnection(to: config)
        }

            let operations = enabledConfigs.compactMap { connectionTasks[$0.name] }
            await awaitOperations(operations)
    }

    func disconnectAllServers() {
            discoveryBatchTask?.task.cancel()
            discoveryBatchTask = nil
            isDiscovering = false

            let serverNames = Set(serverConfigs.map(\.name))
                .union(services.keys)
                .union(connectionTasks.keys)
                .union(reconnectTasks.keys)
                .union(discoveryTasks.keys)
            for serverName in serverNames {
            disconnectServer(serverName)
        }
    }

    // MARK: - Tool Discovery

    func discoverAllTools() async {
            discoveryBatchTask?.task.cancel()
            discoveryBatchGeneration &+= 1
            let generation = discoveryBatchGeneration
            isDiscovering = true

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.discoveryBatchTask?.generation == generation {
                        self.discoveryBatchTask = nil
                        self.isDiscovering = false
                }
            }
                guard !Task.isCancelled else { return }

                let snapshot = Array(self.services.map { ($0.key, $0.value) })
                let operations = snapshot.compactMap { serverName, managed in
                    self.startDiscoveryOperation(
                        serverName: serverName,
                        generation: managed.generation,
                        service: managed.service,
                        forceNew: true
                )
            }
                await self.awaitSharedOperations(operations)

                guard self.discoveryBatchTask?.generation == generation,
                      !Task.isCancelled
                else {
                    return
        }
            self.refreshAllStatusToolCounts()
        }
            let operation = ManagedMCPTask(generation: generation, task: task)
            discoveryBatchTask = operation
            await awaitOperation(operation)
    }

    func discoverTools(for serverName: String) async {
            guard let managed = services[serverName], managed.service.isConnected,
                  let operation = startDiscoveryOperation(
                      serverName: serverName,
                      generation: managed.generation,
                      service: managed.service,
                      forceNew: true
                  )
            else {
                return
            }
            await awaitOperation(operation)
        }

        private func startDiscoveryOperation(
            serverName: String,
            generation: UInt64,
            service: MCPServicing,
            forceNew: Bool = false
        ) -> ManagedMCPTask? {
            guard isCurrentService(service, serverName: serverName, generation: generation),
                  service.isConnected
            else {
                return nil
            }
            if let existing = discoveryTasks[serverName], existing.generation == generation, !forceNew {
                if !existing.task.isCancelled {
                    return existing
                }
                discoveryTasks.removeValue(forKey: serverName)
            }
            if forceNew,
               let existing = discoveryTasks[serverName],
               existing.generation == generation,
               committedDiscoveryGenerations[serverName] == generation
            {
                existing.task.cancel()
            }

            committedDiscoveryGenerations.removeValue(forKey: serverName)
            let operationID = UUID()
            let task = Task { @MainActor [weak self, service] in
                guard let self else { return }
                await self.runDiscovery(
                    serverName: serverName,
                    generation: generation,
                    operationID: operationID,
                    service: service
                )
                self.clearDiscoveryTask(
                    serverName: serverName,
                    generation: generation,
                    operationID: operationID
                )
            }
            let operation = ManagedMCPTask(operationID: operationID, generation: generation, task: task)
            discoveryTasks[serverName] = operation
            return operation
        }

        private func runDiscovery(
            serverName: String,
            generation: UInt64,
            operationID: UUID,
            service: MCPServicing
        ) async {
            guard isCurrentService(service, serverName: serverName, generation: generation),
                  service.isConnected
            else {
            return
        }

        var tools: [MCPTool] = []
        var resources: [MCPResource] = []

        do {
            tools = try await service.listTools()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to list tools",
                metadata: ["server": serverName, "error": error.localizedDescription]
            )
        }
        guard isCurrentService(service, serverName: serverName, generation: generation),
              discoveryTasks[serverName]?.operationID == operationID,
              !Task.isCancelled
            else {
                return
            }

        do {
            resources = try await service.listResources()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
        } catch {
            DiagnosticsLogger.log(
                .mcpServerManager,
                level: .error,
                message: "Failed to list resources",
                metadata: ["server": serverName, "error": error.localizedDescription]
            )
        }
            guard isCurrentService(service, serverName: serverName, generation: generation),
                  discoveryTasks[serverName]?.operationID == operationID,
                  !Task.isCancelled
            else {
                return
        }

            availableTools.removeAll { $0.serverName == serverName }
            availableResources.removeAll { $0.serverName == serverName }
            availableTools.append(contentsOf: tools)
            availableResources.append(contentsOf: resources)
            committedDiscoveryGenerations[serverName] = generation
            invalidateToolCache()
            refreshStatusToolCount(for: serverName)

        DiagnosticsLogger.log(
            .mcpServerManager,
            level: .info,
            message: "Discovery complete",
            metadata: [
                "server": serverName,
                "tools": "\(tools.count)",
                    "resources": "\(resources.count)",
                    "generation": "\(generation)"
            ]
        )
    }

        private func awaitOperation(_ operation: ManagedMCPTask) async {
            await withTaskCancellationHandler {
                await operation.task.value
            } onCancel: {
                operation.task.cancel()
            }
        }

        private func awaitOperations(_ operations: [ManagedMCPTask]) async {
            await withTaskCancellationHandler {
                for operation in operations {
                    await operation.task.value
                }
            } onCancel: {
                for operation in operations {
                    operation.task.cancel()
                }
            }
        }

        private func awaitSharedOperations(_ operations: [ManagedMCPTask]) async {
            for operation in operations {
                guard !Task.isCancelled else { return }
                await operation.task.value
            }
        }

        private func currentConfig(matching config: MCPServerConfig) -> MCPServerConfig? {
            serverConfigs.first { $0.id == config.id && $0.name == config.name }
        }

        @discardableResult
        private func advanceGeneration(for serverName: String) -> UInt64 {
            let next = (serverGenerations[serverName] ?? 0) &+ 1
            serverGenerations[serverName] = next
            return next
        }

        private func isCurrentService(
            _ service: MCPServicing,
            serverName: String,
            generation: UInt64
        ) -> Bool {
            guard let managed = services[serverName], managed.generation == generation else { return false }
            return (managed.service as AnyObject) === (service as AnyObject)
        }

        private func cancelServerTasks(for serverName: String) {
            connectionTasks.removeValue(forKey: serverName)?.task.cancel()
            reconnectTasks.removeValue(forKey: serverName)?.task.cancel()
            discoveryTasks.removeValue(forKey: serverName)?.task.cancel()
            committedDiscoveryGenerations.removeValue(forKey: serverName)
        }

        private func cancelDiscoveryTask(for serverName: String, generation: UInt64) {
            guard discoveryTasks[serverName]?.generation == generation else { return }
            discoveryTasks.removeValue(forKey: serverName)?.task.cancel()
        }

        private func clearConnectionTask(serverName: String, generation: UInt64) {
            guard connectionTasks[serverName]?.generation == generation else { return }
            connectionTasks.removeValue(forKey: serverName)
        }

        private func clearReconnectTask(serverName: String, generation: UInt64) {
            guard reconnectTasks[serverName]?.generation == generation else { return }
            reconnectTasks.removeValue(forKey: serverName)
        }

        private func clearDiscoveryTask(
            serverName: String,
            generation: UInt64,
            operationID: UUID
        ) {
            guard discoveryTasks[serverName]?.generation == generation,
                  discoveryTasks[serverName]?.operationID == operationID
            else { return }
            discoveryTasks.removeValue(forKey: serverName)
        }

        private func removeArtifacts(for serverName: String) {
            committedDiscoveryGenerations.removeValue(forKey: serverName)
            availableTools.removeAll { $0.serverName == serverName }
            availableResources.removeAll { $0.serverName == serverName }
            invalidateToolCache()
            refreshStatusToolCount(for: serverName)
        }

        private func invalidateToolCache() {
            cachedEnabledTools = []
            cachedOpenAIFunctions = []
            toolLookup = [:]
        }

        fileprivate func handleServiceTermination(
            _ service: MCPServicing,
            serverName: String,
            generation: UInt64,
            error: String?
        ) {
            guard isCurrentService(service, serverName: serverName, generation: generation),
                  let managed = services[serverName]
            else {
                DiagnosticsLogger.log(
                    .mcpServerManager,
                    level: .info,
                    message: "Ignoring stale MCP service termination",
                    metadata: ["server": serverName, "generation": "\(generation)"]
                )
                return
            }

            services.removeValue(forKey: serverName)
            connectionTasks.removeValue(forKey: serverName)?.task.cancel()
            cancelDiscoveryTask(for: serverName, generation: generation)
            removeArtifacts(for: serverName)

            guard let config = serverConfigs.first(where: { $0.id == managed.configID && $0.name == serverName }),
                  config.enabled
            else {
                return
            }
            setStatus(for: config, state: .reconnecting, error: error)
            scheduleReconnect(for: config, generation: generation)
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

                guard let managed = services[tool.serverName], managed.service.isConnected else {
                throw MCPManagerError.toolNotFound(name)
            }

                return ToolExecutionContext(service: managed.service, arguments: sendableArguments)
        }

        do {
            return try await withTimeout(seconds: 30) {
                let bridgedArguments = context.arguments.mapValues { $0.value }
                return try await context.service.callTool(name: name, arguments: bridgedArguments)
            }
            } catch is CancellationError {
                throw CancellationError()
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
            return services[serverName]?.service.isConnected ?? false
    }

    func getServerError(_ serverName: String) -> String? {
            serverStatuses[serverName]?.lastError ?? services[serverName]?.service.lastError
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
        toolLookup = Dictionary(cachedEnabledTools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
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
// swiftlint:enable type_body_length
#endif
