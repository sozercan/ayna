@testable import Ayna
import XCTest

@MainActor
final class MCPServerManagerTests: XCTestCase {
    private nonisolated(unsafe) var suiteName: String = ""

    override func setUp() async throws {
        continueAfterFailure = false
        suiteName = "MCPServerManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        AppPreferences.use(defaults)
    }

    override func tearDown() async throws {
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
        }
        AppPreferences.reset()
    }

    func testConnectRetriesUntilSuccess() async {
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

        XCTAssertEqual(stub.connectCallCount, 2)
        XCTAssertTrue(manager.isServerConnected(config.name))
        XCTAssertTrue(manager.serverConfigs.first?.enabled ?? false)
        XCTAssertEqual(manager.getServerStatus(config.name)?.state, .connected)
        XCTAssertNil(manager.getServerStatus(config.name)?.lastError)
    }

    func testAutoDisableAfterRepeatedFailures() async {
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

        XCTAssertFalse(manager.isServerConnected(config.name))
        XCTAssertEqual(manager.serverConfigs.first?.enabled, false)
        XCTAssertEqual(manager.getServerStatus(config.name)?.state, .disabled)
        XCTAssertNotNil(manager.getServerStatus(config.name)?.lastError)
    }

    func testSchedulesReconnectAfterUnexpectedTermination() async throws {
        let config = MCPServerConfig(name: "reconnect", command: "cmd", enabled: true)
        let primaryService = StubMCPService(config: config, connectResults: [.success(())])
        let reconnectService = StubMCPService(config: config, connectResults: [.success(())])
        let reconnectExpectation = expectation(description: "Reconnect attempted")
        reconnectService.onConnect = {
            reconnectExpectation.fulfill()
        }

        var serviceQueue: [StubMCPService] = [primaryService, reconnectService]
        let manager = MCPServerManager(
            serviceFactory: { _ in
                guard !serviceQueue.isEmpty else {
                    XCTFail("Service queue exhausted")
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

        await fulfillment(of: [reconnectExpectation], timeout: 1.0)

        // Wait for state to update to connected since onConnect fires before state update
        for _ in 0 ..< 10 {
            if manager.getServerStatus(config.name)?.state == .connected {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(manager.isServerConnected(config.name))
        XCTAssertEqual(reconnectService.connectCallCount, 1)
        XCTAssertEqual(manager.getServerStatus(config.name)?.state, .connected)
    }

    func testUpdatingEnabledServerRestartsConnection() async {
        let originalConfig = MCPServerConfig(name: "filesystem", command: "cmd", args: ["--foo"], enabled: true)
        var updatedConfig = originalConfig
        updatedConfig.args = ["--bar"]
        updatedConfig.env = ["EXAMPLE": "1"]

        let initialService = StubMCPService(config: originalConfig)
        let restartedService = StubMCPService(config: updatedConfig)
        let restartExpectation = expectation(description: "Restarted service connected")
        restartedService.onConnect = {
            restartExpectation.fulfill()
        }

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
        XCTAssertEqual(initialService.connectCallCount, 1)
        XCTAssertTrue(manager.isServerConnected(originalConfig.name))

        manager.updateServerConfig(updatedConfig)

        await fulfillment(of: [restartExpectation], timeout: 1.0)

        // Wait for connection to complete since factory is called before connection finishes
        let timeout = Date().addingTimeInterval(2.0)
        while Date() < timeout {
            if manager.getServerStatus(updatedConfig.name)?.state == .connected {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(initialService.disconnectCallCount, 1)
        XCTAssertEqual(restartedService.connectCallCount, 1)
        XCTAssertEqual(manager.getServerStatus(updatedConfig.name)?.state, .connected)
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
