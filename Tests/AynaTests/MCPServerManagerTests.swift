@testable import Ayna
import Foundation
import Testing

@Suite("MCPServerManager Tests", .tags(.async, .slow))
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

    @Test("Discovery lists tools and resources concurrently", .timeLimit(.minutes(1)))
    func discoveryListsToolsAndResourcesConcurrently() async {
        let config = MCPServerConfig(name: "catalog", command: "cmd", enabled: true)
        let tool = makeTool(name: "search", serverName: config.name)
        let resource = MCPResource(uri: "file:///tmp/example.txt", name: "Example", serverName: config.name)
        let stub = StubMCPService(config: config)
        stub.listToolsResult = .success([tool])
        stub.listResourcesResult = .success([resource])
        stub.listToolsDelay = .milliseconds(300)
        stub.listResourcesDelay = .milliseconds(300)

        let manager = MCPServerManager(
            serviceFactory: { _ in stub },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = [config]
        manager.updateServerConfig(config)

        let start = Date()
        await manager.connectToServer(config)
        let elapsed = Date().timeIntervalSince(start)

        print("BENCH mcp.discovery.singleServerConcurrent seconds=\(elapsed) sequentialFloor=0.60")
        #expect(stub.listToolsCallCount == 1)
        #expect(stub.listResourcesCallCount == 1)
        #expect(manager.availableTools == [tool])
        #expect(manager.availableResources == [resource])
        #expect(manager.getServerStatus(config.name)?.toolsCount == 1)
    }

    @Test("Enabled tool cache refresh handles bulk configs", .timeLimit(.minutes(1)))
    func enabledToolCacheRefreshHandlesBulkConfigs() {
        let configCount = 1_000
        let toolsPerServer = 5
        let configs = (0 ..< configCount).map { index in
            MCPServerConfig(name: "server-\(index)", command: "cmd", enabled: index.isMultiple(of: 2))
        }
        let tools = configs.flatMap { config in
            (0 ..< toolsPerServer).map { toolIndex in
                makeTool(name: "\(config.name)-tool-\(toolIndex)", serverName: config.name)
            }
        }

        let manager = MCPServerManager(
            serviceFactory: { StubMCPService(config: $0) },
            retryDelayProvider: { _ in 0 },
            reconnectDelayProvider: { 0 }
        )
        manager.serverConfigs = configs
        manager.availableTools = tools

        let start = Date()
        let enabledTools = manager.getEnabledTools()
        let elapsed = Date().timeIntervalSince(start)

        print("BENCH mcp.cache.enabledTools tools=\(tools.count) configs=\(configs.count) seconds=\(elapsed)")
        #expect(enabledTools.count == (configCount / 2) * toolsPerServer)
    }
}

private func makeTool(name: String, serverName: String) -> MCPTool {
    MCPTool(
        name: name,
        description: "Test tool",
        inputSchema: JSONSchema(type: "object", properties: nil, required: nil, items: nil),
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
    var listToolsCallCount = 0
    var listResourcesCallCount = 0
    var listToolsResult: Result<[MCPTool], Error> = .success([])
    var listResourcesResult: Result<[MCPResource], Error> = .success([])
    var listToolsDelay: Duration = .zero
    var listResourcesDelay: Duration = .zero
    var onConnect: (() -> Void)?

    init(config: MCPServerConfig, connectResults: [Result<Void, Error>] = [.success(())]) {
        serverConfig = config
        self.connectResults = connectResults
    }

    func connect() async throws {
        connectCallCount += 1
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
        listToolsCallCount += 1
        try await Task.sleep(for: listToolsDelay)
        return try listToolsResult.get()
    }

    func listResources() async throws -> [MCPResource] {
        listResourcesCallCount += 1
        try await Task.sleep(for: listResourcesDelay)
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
