@testable import Ayna
import Foundation
import Testing

@Suite("MCPServerManager Tests")
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

    @Test("Connect retries until success")
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

    @Test("Auto-disable after repeated failures")
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

    @Test("Schedules reconnect after unexpected termination")
    func schedulesReconnectAfterUnexpectedTermination() async throws {
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

    @Test("Updating enabled server restarts connection")
    func updatingEnabledServerRestartsConnection() async throws {
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
        try listToolsResult.get()
    }

    func listResources() async throws -> [MCPResource] {
        try listResourcesResult.get()
    }

    func callTool(name _: String, arguments _: [String: Any]) async throws -> String {
        ""
    }

    @MainActor
    func simulateUnexpectedTermination(error: String? = nil) {
        delegate?.mcpService(self, didTerminateWithError: error)
    }
}
