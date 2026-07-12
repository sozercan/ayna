@testable import Ayna
import Foundation
import Testing

@Suite("MCPServerManager Tests", .tags(.async, .slow), .serialized)
@MainActor
struct MCPServerManagerTests {
    private var suiteName: String
    private var defaults: UserDefaults

    init() {
        suiteName = "MCPServerManagerTests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: suiteName)
        AppPreferences.use(defaults)
    }

    @Test("Connect retries until success", .timeLimit(.minutes(1)))
    func connectRetriesUntilSuccess() async {
        let config = MCPServerConfig(name: "stub", command: "cmd", enabled: true)
        let stub = StubMCPService(
            config: config,
            connectResults: [
                .failure(MCPTestError.expected),
                .success(())
            ]
        )

        let manager = MCPServerManager(
            serviceFactory: { _ in stub },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        await manager.connectToServer(config)

        #expect(stub.connectCallCount == 2)
        #expect(manager.isServerConnected(config.name))
        #expect(manager.serverConfigs.first?.enabled ?? false)
        #expect(manager.getServerStatus(config.name)?.state == .connected)
        #expect(manager.getServerStatus(config.name)?.lastError == nil)
    }

    @Test("Auto-disable after repeated failures", .timeLimit(.minutes(1)))
    func autoDisableAfterRepeatedFailures() async {
        let config = MCPServerConfig(name: "failing", command: "cmd", enabled: true)
        let stub = StubMCPService(
            config: config,
            connectResults: [
                .failure(MCPTestError.expected),
                .failure(MCPTestError.expected),
                .failure(MCPTestError.expected)
            ]
        )

        let manager = MCPServerManager(
            serviceFactory: { _ in stub },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        await manager.connectToServer(config)

        #expect(!manager.isServerConnected(config.name))
        #expect(manager.serverConfigs.first?.enabled == false)
        #expect(manager.getServerStatus(config.name)?.state == .disabled)
        #expect(manager.getServerStatus(config.name)?.lastError != nil)
    }

    @Test("Schedules reconnect after unexpected termination", .timeLimit(.minutes(1)))
    func schedulesReconnectAfterUnexpectedTermination() async {
        let config = MCPServerConfig(name: "reconnect", command: "cmd", enabled: true)
        let primaryService = StubMCPService(config: config, connectResults: [.success(())])
        let reconnectService = StubMCPService(config: config, connectResults: [.success(())])

        var serviceQueue: [StubMCPService] = [primaryService, reconnectService]
        let manager = MCPServerManager(
            serviceFactory: { _ in
                guard !serviceQueue.isEmpty else {
                    Issue.record("Service queue exhausted")
                    return StubMCPService(config: config)
                }
                return serviceQueue.removeFirst()
            },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        await manager.connectToServer(config)
        primaryService.simulateUnexpectedTermination(error: "boom")

        // Wait for reconnect
        for _ in 0 ..< 20 {
            if reconnectService.connectCallCount > 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Wait for state to update to connected since onConnect fires before state update
        for _ in 0 ..< 10 {
            if manager.getServerStatus(config.name)?.state == .connected {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        #expect(manager.isServerConnected(config.name))
        #expect(reconnectService.connectCallCount == 1)
        #expect(manager.getServerStatus(config.name)?.state == .connected)
    }

    @Test("Updating enabled server restarts connection", .timeLimit(.minutes(1)))
    func updatingEnabledServerRestartsConnection() async {
        let originalConfig = MCPServerConfig(name: "filesystem", command: "cmd", args: ["--foo"], enabled: true)
        var updatedConfig = originalConfig
        updatedConfig.args = ["--bar"]
        updatedConfig.env = ["EXAMPLE": "1"]

        let initialService = StubMCPService(config: originalConfig)
        let restartedService = StubMCPService(config: updatedConfig)

        let manager = MCPServerManager(
            serviceFactory: { config in
                if config.args == updatedConfig.args {
                    return restartedService
                }
                return initialService
            },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [originalConfig]
        manager.updateServerConfig(originalConfig)

        await manager.connectToServer(originalConfig)
        #expect(initialService.connectCallCount == 1)
        #expect(manager.isServerConnected(originalConfig.name))

        manager.updateServerConfig(updatedConfig)

        // Wait for restart
        for _ in 0 ..< 20 {
            if restartedService.connectCallCount > 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Wait for connection to complete since factory is called before connection finishes
        let timeout = Date().addingTimeInterval(2.0)
        while Date() < timeout {
            if manager.getServerStatus(updatedConfig.name)?.state == .connected {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        #expect(initialService.disconnectCallCount == 1)
        #expect(restartedService.connectCallCount == 1)
        #expect(manager.getServerStatus(updatedConfig.name)?.state == .connected)
    }

    @Test("Cancelling retry backoff prevents another connection attempt", .timeLimit(.minutes(1)))
    func cancellingRetryBackoffPreventsAnotherAttempt() async {
        let config = MCPServerConfig(name: "backoff", command: "cmd", enabled: true)
        let service = StubMCPService(
            config: config,
            connectResults: [.failure(MCPTestError.expected), .success(())]
        )
        let manager = MCPServerManager(
            serviceFactory: { _ in service },
            retryDelayProvider: { _ in 60 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        let task = Task { @MainActor in
            await manager.connectToServer(config)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while service.connectCallCount == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.connectCallCount == 1)
        task.cancel()
        await task.value

        #expect(service.connectCallCount == 1)
        #expect(manager.serverConfigs.first?.enabled == true)
        #expect(manager.getServerStatus(config.name)?.state == .idle)
    }

    @Test("Cancellation after discovery commit removes stale tools", .timeLimit(.minutes(1)))
    func cancellationAfterDiscoveryCommitRemovesStaleTools() async {
        let config = MCPServerConfig(name: "stale-tools", command: "cmd", enabled: true)
        let service = StubMCPService(config: config)
        service.listToolsHandler = {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return [
                MCPTool(
                    name: "stale",
                    description: "stale",
                    inputSchema: JSONSchema(type: "object", properties: nil, required: nil, items: nil),
                    serverName: config.name
                )
            ]
        }
        let manager = MCPServerManager(
            serviceFactory: { _ in service },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        await manager.connectToServer(config)

        #expect(!manager.availableTools.contains { $0.serverName == config.name })
        #expect(!manager.getEnabledTools().contains { $0.serverName == config.name })
        #expect(manager.getServerStatus(config.name)?.state == .idle)
    }

    @Test("Cancelling tool discovery does not commit connected state", .timeLimit(.minutes(1)))
    func cancellingToolDiscoveryDoesNotCommitConnectedState() async {
        let config = MCPServerConfig(name: "discovery", command: "cmd", enabled: true)
        let discoveryStarted = FlightTestSignal()
        let service = StubMCPService(config: config)
        service.listToolsHandler = {
            discoveryStarted.signal()
            try await Task.sleep(for: .seconds(60))
            return []
        }
        let manager = MCPServerManager(
            serviceFactory: { _ in service },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        let task = Task { @MainActor in
            await manager.connectToServer(config)
        }
        #expect(await discoveryStarted.wait(timeout: .seconds(1)))
        task.cancel()
        await task.value

        #expect(service.connectCallCount == 1)
        #expect(service.disconnectCallCount >= 1)
        #expect(manager.getServerStatus(config.name)?.state == .idle)
        #expect(manager.getConnectedServerCount() == 0)
    }

    @Test("Replacement discovery batch starts fresh work without reusing its predecessor", .timeLimit(.minutes(1)))
    func replacementDiscoveryBatchStartsFreshWork() async {
        let config = MCPServerConfig(name: "replacement-discovery", command: "cmd", enabled: true)
        let service = StubMCPService(config: config)
        service.listToolsResult = .success([makeMCPTool(name: "initial", serverName: config.name)])
        let manager = MCPServerManager(
            serviceFactory: { _ in service },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)
        await manager.connectToServer(config)

        let firstDiscoveryStarted = FlightTestSignal()
        let releaseFirstDiscovery = FlightTestSignal()
        let invocationCount = FlightTestBox(0)
        service.listToolsHandler = {
            invocationCount.update { $0 += 1 }
            if invocationCount.value == 1 {
                firstDiscoveryStarted.signal()
                await releaseFirstDiscovery.wait()
            }
            return [makeMCPTool(name: "fresh", serverName: config.name)]
        }

        let firstBatch = Task { @MainActor in
            await manager.discoverAllTools()
        }
        #expect(await firstDiscoveryStarted.wait(timeout: .seconds(1)))

        let replacementBatch = Task { @MainActor in
            await manager.discoverAllTools()
        }
        await replacementBatch.value
        releaseFirstDiscovery.signal()
        await firstBatch.value

        #expect(invocationCount.value == 2)
        #expect(manager.availableTools.map(\.name) == ["fresh"])
    }

    @Test("Superseded resource discovery cannot overwrite a newer catalog", .timeLimit(.minutes(1)))
    func supersededResourceDiscoveryCannotOverwriteNewerCatalog() async {
        let config = MCPServerConfig(name: "resource-fence", command: "cmd", enabled: true)
        let service = StubMCPService(config: config)
        let manager = MCPServerManager(
            serviceFactory: { _ in service },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)
        await manager.connectToServer(config)

        let firstResourceStarted = FlightTestSignal()
        let releaseFirstResource = FlightTestSignal()
        let toolInvocationCount = FlightTestBox(0)
        let resourceInvocationCount = FlightTestBox(0)
        service.listToolsHandler = {
            toolInvocationCount.update { $0 += 1 }
            let name = toolInvocationCount.value == 1 ? "stale-tool" : "fresh-tool"
            return [makeMCPTool(name: name, serverName: config.name)]
        }
        service.listResourcesHandler = {
            resourceInvocationCount.update { $0 += 1 }
            if resourceInvocationCount.value == 1 {
                firstResourceStarted.signal()
                await releaseFirstResource.wait()
                return [makeMCPResource(name: "stale-resource", serverName: config.name)]
            }
            return [makeMCPResource(name: "fresh-resource", serverName: config.name)]
        }

        let staleDiscovery = Task { @MainActor in
            await manager.discoverTools(for: config.name)
        }
        #expect(await firstResourceStarted.wait(timeout: .seconds(1)))

        let freshDiscovery = Task { @MainActor in
            await manager.discoverTools(for: config.name)
        }
        await freshDiscovery.value
        releaseFirstResource.signal()
        await staleDiscovery.value

        #expect(manager.availableTools.map(\.name) == ["fresh-tool"])
        #expect(manager.availableResources.map(\.name) == ["fresh-resource"])
    }

    @Test("Repeated refreshes during initial discovery are adopted by the connection", .timeLimit(.minutes(1)))
    func repeatedRefreshesDuringInitialDiscoveryAreAdoptedByConnection() async {
        let config = MCPServerConfig(name: "connection-refresh", command: "cmd", enabled: true)
        let service = StubMCPService(config: config)
        let firstDiscoveryStarted = FlightTestSignal()
        let secondDiscoveryStarted = FlightTestSignal()
        let thirdDiscoveryStarted = FlightTestSignal()
        let releaseFirstDiscovery = FlightTestSignal()
        let releaseSecondDiscovery = FlightTestSignal()
        let releaseThirdDiscovery = FlightTestSignal()
        let invocationCount = FlightTestBox(0)
        service.listToolsHandler = {
            invocationCount.update { $0 += 1 }
            switch invocationCount.value {
            case 1:
                firstDiscoveryStarted.signal()
                await releaseFirstDiscovery.wait()
                return [makeMCPTool(name: "superseded", serverName: config.name)]
            case 2:
                secondDiscoveryStarted.signal()
                await releaseSecondDiscovery.wait()
                return [makeMCPTool(name: "superseded-again", serverName: config.name)]
            default:
                thirdDiscoveryStarted.signal()
                await releaseThirdDiscovery.wait()
                return [makeMCPTool(name: "fresh", serverName: config.name)]
            }
        }
        let manager = MCPServerManager(
            serviceFactory: { _ in service },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        let connection = Task { @MainActor in
            await manager.connectToServer(config)
        }
        #expect(await firstDiscoveryStarted.wait(timeout: .seconds(1)))

        let firstRefresh = Task { @MainActor in
            await manager.discoverAllTools()
        }
        #expect(await secondDiscoveryStarted.wait(timeout: .seconds(1)))

        let secondRefresh = Task { @MainActor in
            await manager.discoverAllTools()
        }
        #expect(await thirdDiscoveryStarted.wait(timeout: .seconds(1)))
        releaseFirstDiscovery.signal()
        releaseSecondDiscovery.signal()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(service.disconnectCallCount == 0)

        releaseThirdDiscovery.signal()
        await firstRefresh.value
        await secondRefresh.value
        await connection.value

        #expect(manager.isServerConnected(config.name))
        #expect(manager.availableTools.map(\.name) == ["fresh"])
    }

    @Test("Stale service termination cannot remove replacement", .timeLimit(.minutes(1)))
    func staleServiceTerminationCannotRemoveReplacement() async {
        let original = MCPServerConfig(name: "identity", command: "cmd", args: ["old"], enabled: true)
        var updated = original
        updated.args = ["new"]

        let initialService = StubMCPService(config: original)
        initialService.listToolsResult = .success([makeMCPTool(name: "old-tool", serverName: original.name)])
        let replacementService = StubMCPService(config: updated)
        replacementService.listToolsResult = .success([makeMCPTool(name: "new-tool", serverName: updated.name)])
        let manager = MCPServerManager(
            serviceFactory: { config in config.args == updated.args ? replacementService : initialService },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [original]
        manager.updateServerConfig(original)

        await manager.connectToServer(original)
        let staleDelegate = initialService.delegate
        manager.updateServerConfig(updated)
        #expect(await waitUntil { manager.getServerStatus(updated.name)?.state == .connected })
        #expect(manager.availableTools.contains { $0.name == "new-tool" })

        staleDelegate?.mcpService(initialService, didTerminateWithError: "stale")
        await Task.yield()

        #expect(manager.isServerConnected(updated.name))
        #expect(replacementService.disconnectCallCount == 0)
        #expect(manager.availableTools.contains { $0.name == "new-tool" })
        #expect(!manager.availableTools.contains { $0.name == "old-tool" })
    }

    @Test("Manual disconnect cancels retained scheduled reconnect", .timeLimit(.minutes(1)))
    func manualDisconnectCancelsRetainedScheduledReconnect() async {
        let config = MCPServerConfig(name: "cancel-reconnect", command: "cmd", enabled: true)
        let primaryService = StubMCPService(config: config)
        let reconnectService = StubMCPService(config: config)
        var services = [primaryService, reconnectService]
        let manager = MCPServerManager(
            serviceFactory: { _ in services.removeFirst() },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 60 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        await manager.connectToServer(config)
        primaryService.simulateUnexpectedTermination(error: "boom")
        #expect(manager.getServerStatus(config.name)?.state == .reconnecting)

        manager.disconnectServer(config.name)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(reconnectService.connectCallCount == 0)
        #expect(manager.getServerStatus(config.name)?.state == .idle)
        #expect(!manager.isServerConnected(config.name))
    }

    @Test("Stale connection completion cannot replace newer generation", .timeLimit(.minutes(1)))
    func staleConnectionCompletionCannotReplaceNewerGeneration() async {
        let original = MCPServerConfig(name: "connect-generation", command: "cmd", args: ["old"], enabled: true)
        var updated = original
        updated.args = ["new"]

        let oldConnectStarted = FlightTestSignal()
        let releaseOldConnect = FlightTestSignal()
        let oldService = StubMCPService(config: original)
        oldService.connectHandler = {
            oldConnectStarted.signal()
            await releaseOldConnect.wait()
        }
        let replacementService = StubMCPService(config: updated)
        replacementService.listToolsResult = .success([makeMCPTool(name: "replacement", serverName: updated.name)])
        let manager = MCPServerManager(
            serviceFactory: { config in config.args == updated.args ? replacementService : oldService },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [original]
        manager.updateServerConfig(original)

        let oldConnection = Task { @MainActor in
            await manager.connectToServer(original)
        }
        #expect(await oldConnectStarted.wait(timeout: .seconds(1)))

        manager.updateServerConfig(updated)
        #expect(await waitUntil { manager.getServerStatus(updated.name)?.state == .connected })
        releaseOldConnect.signal()
        await oldConnection.value

        #expect(manager.isServerConnected(updated.name))
        #expect(replacementService.disconnectCallCount == 0)
        #expect(manager.availableTools.map(\.name) == ["replacement"])
    }

    @Test("Stale discovery cannot overwrite replacement tools", .timeLimit(.minutes(1)))
    func staleDiscoveryCannotOverwriteReplacementTools() async {
        let original = MCPServerConfig(name: "discovery-generation", command: "cmd", args: ["old"], enabled: true)
        var updated = original
        updated.args = ["new"]

        let oldService = StubMCPService(config: original)
        oldService.listToolsResult = .success([makeMCPTool(name: "initial", serverName: original.name)])
        let replacementService = StubMCPService(config: updated)
        replacementService.listToolsResult = .success([makeMCPTool(name: "replacement", serverName: updated.name)])
        let manager = MCPServerManager(
            serviceFactory: { config in config.args == updated.args ? replacementService : oldService },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [original]
        manager.updateServerConfig(original)
        await manager.connectToServer(original)

        let staleDiscoveryStarted = FlightTestSignal()
        let releaseStaleDiscovery = FlightTestSignal()
        oldService.listToolsHandler = {
            staleDiscoveryStarted.signal()
            await releaseStaleDiscovery.wait()
            return [makeMCPTool(name: "stale", serverName: original.name)]
        }
        let staleDiscovery = Task { @MainActor in
            await manager.discoverTools(for: original.name)
        }
        #expect(await staleDiscoveryStarted.wait(timeout: .seconds(1)))

        manager.updateServerConfig(updated)
        #expect(await waitUntil { manager.getServerStatus(updated.name)?.state == .connected })
        releaseStaleDiscovery.signal()
        await staleDiscovery.value

        #expect(manager.availableTools.map(\.name) == ["replacement"])
        #expect(manager.getServerStatus(updated.name)?.state == .connected)
    }

    @Test("Cancelling a connection does not retry or disable the server", .timeLimit(.minutes(1)))
    func cancellingConnectionDoesNotRetryOrDisableServer() async {
        let config = MCPServerConfig(name: "cancelled", command: "cmd", enabled: true)
        let started = FlightTestSignal()
        let service = StubMCPService(config: config)
        service.connectHandler = {
            started.signal()
            try await Task.sleep(for: .seconds(60))
        }
        let manager = MCPServerManager(
            serviceFactory: { _ in service },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        let task = Task { @MainActor in
            await manager.connectToServer(config)
        }
        #expect(await started.wait(timeout: .seconds(1)))
        task.cancel()
        await task.value

        #expect(service.connectCallCount == 1)
        #expect(manager.serverConfigs.first?.enabled == true)
        #expect(manager.getServerStatus(config.name)?.state == .idle)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private func makeMCPTool(name: String, serverName: String) -> MCPTool {
    MCPTool(
        name: name,
        description: name,
        inputSchema: JSONSchema(type: "object", properties: nil, required: nil, items: nil),
        serverName: serverName
    )
}

private func makeMCPResource(name: String, serverName: String) -> MCPResource {
    MCPResource(
        uri: "resource://\(name)",
        name: name,
        serverName: serverName
    )
}

private enum MCPTestError: Error {
    case expected
}

private final class StubMCPService: MCPServicing, @unchecked Sendable {
    let serverConfig: MCPServerConfig
    private let connectResults: [Result<Void, Error>]

    var isConnected = false
    var lastError: String?
    weak var delegate: MCPServiceDelegate?

    var connectCallCount = 0
    var disconnectCallCount = 0
    var listToolsResult: Result<[MCPTool], Error> = .success([])
    var listResourcesResult: Result<[MCPResource], Error> = .success([])
    var listToolsHandler: (@Sendable () async throws -> [MCPTool])?
    var listResourcesHandler: (@Sendable () async throws -> [MCPResource])?
    var onConnect: (() -> Void)?
    var connectHandler: (@Sendable () async throws -> Void)?

    init(config: MCPServerConfig, connectResults: [Result<Void, Error>] = [.success(())]) {
        serverConfig = config
        self.connectResults = connectResults
    }

    func connect() async throws {
        connectCallCount += 1
        if let connectHandler {
            try await connectHandler()
            isConnected = true
            onConnect?()
            return
        }
        let index = min(connectCallCount - 1, connectResults.count - 1)
        let result = connectResults[index]
        switch result {
        case .success:
            isConnected = true
            onConnect?()
        case let .failure(error):
            throw error
        }
    }

    func disconnect() {
        disconnectCallCount += 1
        isConnected = false
    }

    func listTools() async throws -> [MCPTool] {
        if let listToolsHandler {
            return try await listToolsHandler()
        }
        return try listToolsResult.get()
    }

    func listResources() async throws -> [MCPResource] {
        if let listResourcesHandler {
            return try await listResourcesHandler()
        }
        return try listResourcesResult.get()
    }

    func callTool(name _: String, arguments _: [String: Any]) async throws -> String {
        ""
    }

    @MainActor
    func simulateUnexpectedTermination(error: String? = nil) {
        delegate?.mcpService(self, didTerminateWithError: error)
    }
}
