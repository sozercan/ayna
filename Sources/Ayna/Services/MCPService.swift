// swiftformat:options --ifdef no-indent

#if os(macOS)
import Combine
import Foundation
import os

#if compiler(>=6.0)
#warning("MCPService uses @unchecked Sendable - thread safety ensured manually via Task { @MainActor } and [weak self]")
#endif

protocol MCPServicing: AnyObject, Sendable {
    var serverConfig: MCPServerConfig { get }
    var isConnected: Bool { get }
    var lastError: String? { get set }
    var delegate: MCPServiceDelegate? { get set }

    func connect() async throws
    func disconnect()
    func listTools() async throws -> [MCPTool]
    func listResources() async throws -> [MCPResource]
    func callTool(name: String, arguments: [String: Any]) async throws -> String
}

@MainActor
protocol MCPServiceDelegate: AnyObject {
    func mcpService(_ service: MCPServicing, didTerminateWithError error: String?)
}

class MCPService: ObservableObject, MCPServicing, @unchecked Sendable {
    var activeLifecycle: MCPProcessLifecycle?
    var lifecycles: [UUID: MCPProcessLifecycle] = [:]
    var healthCheckTask: (transportID: UUID, task: Task<Void, Never>)?

    private var requestId = 0
    let pendingRequests: PendingMCPRequestStore
    private let requestWriteHook: (@Sendable (Int, String) -> Void)?
    private let outboundWriter: MCPOutboundWriter
    private let terminationGracePeriod: TimeInterval
    private let processRegistrationHandler: @Sendable (String, pid_t) -> Void
    private let processUnregistrationHandler: @Sendable (String) -> Void

    let serverConfig: MCPServerConfig
    @Published var isConnected = false
    @Published var lastError: String?
    weak var delegate: MCPServiceDelegate?

    var outputBuffer = ""
    private let stateLock = NSLock()

    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    var pendingRequestCount: Int {
        pendingRequests.count
    }

    init(
        serverConfig: MCPServerConfig,
        requestTimeoutSeconds: TimeInterval = 30,
        requestWriteHook: (@Sendable (Int, String) -> Void)? = nil,
        messageWriteHandler: @escaping @Sendable (FileHandle, Data) throws -> Void = { handle, data in
            try handle.write(contentsOf: data)
        },
        terminationGracePeriod: TimeInterval = 0.5,
        processRegistrationHandler: @escaping @Sendable (String, pid_t) -> Void = { trackingKey, pid in
            MCPProcessTracker.shared.register(serverName: trackingKey, pid: pid)
        },
        processUnregistrationHandler: @escaping @Sendable (String) -> Void = { trackingKey in
            MCPProcessTracker.shared.unregister(serverName: trackingKey)
        }
    ) {
        self.serverConfig = serverConfig
        pendingRequests = PendingMCPRequestStore(timeoutSeconds: requestTimeoutSeconds)
        self.requestWriteHook = requestWriteHook
        outboundWriter = MCPOutboundWriter(writeHandler: messageWriteHandler)
        self.terminationGracePeriod = max(0, terminationGracePeriod)
        self.processRegistrationHandler = processRegistrationHandler
        self.processUnregistrationHandler = processUnregistrationHandler
    }

    deinit {
        healthCheckTask?.task.cancel()
        let remainingLifecycles = Array(lifecycles.values)
        pendingRequests.failAll(error: MCPServiceError.notConnected)
        for lifecycle in remainingLifecycles {
            lifecycle.markManualDisconnect()
            lifecycle.stopReading()
            lifecycle.lease.invalidate()
            Self.terminateProcess(lifecycle, gracePeriod: terminationGracePeriod)
        }
    }

    func connect() async throws {
        guard withLock({ activeLifecycle == nil }) else { return }

        let commandPath = try await resolveExecutablePath()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = makeConfiguredProcess(
            executablePath: commandPath,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        )

        let lifecycle = MCPProcessLifecycle(
            id: UUID(),
            serverName: serverConfig.name,
            process: process,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            registerProcess: processRegistrationHandler,
            unregisterProcess: processUnregistrationHandler
        )
        let installed = withLock { () -> Bool in
            guard activeLifecycle == nil else { return false }
            activeLifecycle = lifecycle
            lifecycles[lifecycle.id] = lifecycle
            outputBuffer = ""
            return true
        }
        guard installed else { return }

        configureTransportHandlers(for: lifecycle)

        do {
            try process.run()
            lifecycle.registerAfterLaunch()
            try await initialize(on: lifecycle)
            guard isActiveTransport(lifecycle.id), !Task.isCancelled else {
                disconnect(transportID: lifecycle.id)
                throw CancellationError()
            }
        } catch is CancellationError {
            disconnect(transportID: lifecycle.id)
            throw CancellationError()
        } catch {
            disconnect(transportID: lifecycle.id)
            let errorMsg = "Failed to start process: \(error.localizedDescription)"
            DiagnosticsLogger.log(.mcpService, level: .error, message: errorMsg)
            await MainActor.run { [weak self] in
                guard let self, !self.hasActiveReplacement(for: lifecycle.id) else { return }
                self.lastError = errorMsg
            }
            throw MCPServiceError.initializationFailed(errorMsg)
        }

        await MainActor.run { [weak self] in
            guard let self, self.isActiveTransport(lifecycle.id) else { return }
            self.isConnected = true
            self.lastError = nil
        }
        startHealthCheckTimer(for: lifecycle)
    }

    func disconnect() {
        _ = disconnect(transportID: nil)
    }

    @discardableResult
    func disconnect(transportID: UUID?) -> Bool {
        let lifecycle: MCPProcessLifecycle? = withLock {
            guard let current = activeLifecycle,
                  transportID == nil || current.id == transportID
            else {
                return nil
            }

            current.markManualDisconnect()
            current.lease.invalidate()
            current.stopReading()
            activeLifecycle = nil
            outputBuffer = ""
            if healthCheckTask?.transportID == current.id {
                healthCheckTask?.task.cancel()
                healthCheckTask = nil
            }
            return current
        }
        guard let lifecycle else { return false }

        pendingRequests.failAll(for: lifecycle.id, error: MCPServiceError.notConnected)
        Task { @MainActor [weak self] in
            guard let self, !self.hasActiveReplacement(for: lifecycle.id) else { return }
            self.isConnected = false
        }

        Self.terminateProcess(lifecycle, gracePeriod: terminationGracePeriod) { [weak self, lifecycle] exitCode in
            if let self {
                self.processDidExit(lifecycle, exitCode: exitCode)
            } else {
                _ = lifecycle.finalize()
            }
        }
        return true
    }

    private func initialize(on lifecycle: MCPProcessLifecycle) async throws {
        let response = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": AnyCodable("2024-11-05"),
                "capabilities": AnyCodable([String: Any]()),
                "clientInfo": AnyCodable([
                    "name": "ayna",
                    "version": "1.0.0"
                ] as [String: String])
            ],
            lifecycle: lifecycle
        )

        guard response.error == nil else {
            throw MCPServiceError.initializationFailed(response.error?.message ?? "Unknown error")
        }

        try await sendNotification(method: "notifications/initialized", lifecycle: lifecycle)
    }

    func listTools() async throws -> [MCPTool] {
        let response = try await sendRequest(method: "tools/list", params: nil)

        guard let result = response.result?.value as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]]
        else {
            throw MCPServiceError.invalidResponse("Failed to parse tools list")
        }

        var validTools: [MCPTool] = []
        for (index, toolDict) in toolsArray.enumerated() {
            do {
                let tool = try parseTool(from: toolDict)
                validTools.append(tool)
            } catch {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .error,
                    message: "Skipping invalid tool",
                    metadata: [
                        "server": serverConfig.name,
                        "index": "\(index)",
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        return validTools
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

        let text: String
        if let content = result["content"] as? [[String: Any]] {
            text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else if let single = result["content"] as? String {
            text = single
        } else {
            throw MCPServiceError.invalidResponse("Unexpected content format in tool result")
        }
        if result["isError"] as? Bool == true {
            throw MCPServiceError.toolExecutionFailed(text.isEmpty ? "The tool reported an error" : text)
        }
        return text
    }

    func listResources() async throws -> [MCPResource] {
        let response = try await sendRequest(method: "resources/list", params: nil)

        guard let result = response.result?.value as? [String: Any],
              let resourcesArray = result["resources"] as? [[String: Any]]
        else {
            throw MCPServiceError.invalidResponse("Failed to parse resources list")
        }

        return resourcesArray.compactMap { resourceDict in
            parseResource(from: resourceDict)
        }
    }

    @MainActor
    private func sendRequest(
        method: String,
        params: [String: AnyCodable]?,
        lifecycle suppliedLifecycle: MCPProcessLifecycle? = nil
    ) async throws -> MCPResponse {
        try Task.checkCancellation()
        guard let lifecycle = suppliedLifecycle ?? withLock({ activeLifecycle }),
              isActiveTransport(lifecycle.id)
        else {
            throw MCPServiceError.notConnected
        }

        let id = withLock {
            requestId += 1
            return requestId
        }
        let request = MCPRequest(id: id, method: method, params: params)
        let requestData: Data
        do {
            var data = try JSONEncoder().encode(request)
            data.append(0x0A)
            requestData = data
        } catch {
            throw MCPServiceError.encodingFailed
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests.insert(
                    id: id,
                    method: method,
                    transportID: lifecycle.id,
                    continuation: continuation,
                    timeoutHandler: { [weak self] action in
                        self?.handleRequestCompletion(action)
                    }
                )

                guard !Task.isCancelled else {
                    cancelRequest(id: id)
                    return
                }

                let writer = outboundWriter
                let store = pendingRequests
                let beforeWrite = requestWriteHook
                Task.detached { [weak self, lifecycle] in
                    await writer.writeRequest(
                        id: id,
                        method: method,
                        data: requestData,
                        lifecycle: lifecycle,
                        store: store,
                        beforeWrite: beforeWrite,
                        completionHandler: { [weak self] action in
                            self?.handleRequestCompletion(action)
                        }
                    )
                }
            }
        } onCancel: {
            cancelRequest(id: id)
        }
    }

    private func cancelRequest(id: Int) {
        if let action = pendingRequests.cancel(id: id) {
            handleRequestCompletion(action)
        }
    }

    private func handleRequestCompletion(_ action: MCPRequestCompletionAction) {
        if action.requiresTransportInvalidation {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "MCP request ended while its pipe write was blocked; disconnecting transport",
                metadata: [
                    "id": "\(action.id)",
                    "method": action.method,
                    "reason": action.reason.notificationReason,
                    "server": serverConfig.name
                ]
            )
            invalidateTransport(
                action.transportID,
                reason: "MCP transport write was interrupted: \(action.reason.notificationReason)"
            )
            return
        }

        if action.method == "initialize" {
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "Initialize request completed without a response; disconnecting transport",
                metadata: [
                    "id": "\(action.id)",
                    "reason": action.reason.notificationReason,
                    "server": serverConfig.name
                ]
            )
            disconnect(transportID: action.transportID)
            return
        }

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.sendCancellationNotification(action)
            } catch {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .error,
                    message: "Failed to send MCP cancellation notification; disconnecting",
                    metadata: [
                        "error": error.localizedDescription,
                        "id": "\(action.id)",
                        "server": self.serverConfig.name
                    ]
                )
                self.disconnect(transportID: action.transportID)
            }
        }
    }

    private func invalidateTransport(_ transportID: UUID, reason: String) {
        guard disconnect(transportID: transportID) else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.hasActiveReplacement(for: transportID) else { return }
            self.lastError = reason
            self.delegate?.mcpService(self, didTerminateWithError: reason)
        }
    }

    private func sendCancellationNotification(_ action: MCPRequestCompletionAction) async throws {
        guard let lifecycle = withLock({ lifecycles[action.transportID] }) else {
            throw MCPServiceError.notConnected
        }
        try await sendNotification(
            method: "notifications/cancelled",
            params: [
                "requestId": AnyCodable(action.id),
                "reason": AnyCodable(action.reason.notificationReason)
            ],
            lifecycle: lifecycle
        )
    }

    private func sendNotification(
        method: String,
        params: [String: AnyCodable]? = nil,
        lifecycle: MCPProcessLifecycle
    ) async throws {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params?.mapValues { $0.value } ?? [:]
        ]

        var data = try JSONSerialization.data(withJSONObject: notification)
        data.append(0x0A)
        try await outboundWriter.writeNotification(data, lifecycle: lifecycle)
    }

    func handleOutput(_ output: String, transportID: UUID) {
        let completedLines: [String] = withLock {
            guard activeLifecycle?.id == transportID else { return [] }
            if outputBuffer.count + output.count > 1_048_576 {
                DiagnosticsLogger.log(.mcpService, level: .error, message: "MCP output buffer exceeded 1MB limit, clearing")
                outputBuffer = ""
                return []
            }
            outputBuffer += output

            let lines = outputBuffer.components(separatedBy: "\n")

            if let last = lines.last, !output.hasSuffix("\n") {
                outputBuffer = last
            } else {
                outputBuffer = ""
            }

            return Array(lines.dropLast())
        }

        for line in completedLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            processJSONRPCMessage(trimmed, transportID: transportID)
        }
    }

    private func handleServerMessage(_ object: [String: Any], method: String, transportID: UUID) {
        guard let id = object["id"], let lifecycle = withLock({ lifecycles[transportID] }) else { return }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if method == "ping" {
            reply["result"] = [String: Any]()
        } else {
            reply["error"] = ["code": -32601, "message": "Method not found: \(method)"] as [String: Any]
        }
        guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        data.append(0x0A)
        let writer = outboundWriter
        Task { try? await writer.writeNotification(data, lifecycle: lifecycle) }
    }

    private func processJSONRPCMessage(_ json: String, transportID: UUID) {
        guard let data = json.data(using: .utf8) else {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to convert JSON string to data",
                metadata: ["server": serverConfig.name]
            )
            return
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let method = object["method"] as? String
        {
            handleServerMessage(object, method: method, transportID: transportID)
            return
        }

        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(MCPResponse.self, from: data)

            if let id = response.id {
                Task { @MainActor in
                    if !self.pendingRequests.resume(id: id, with: response) {
                        DiagnosticsLogger.log(
                            .mcpService,
                            level: .info,
                            message: "Ignoring response for completed MCP request",
                            metadata: ["id": "\(id)"]
                        )
                    }
                }
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to decode MCP response",
                metadata: ["server": serverConfig.name, "error": error.localizedDescription, "payload": json]
            )
        }
    }

    private func parseTool(from dict: [String: Any]) throws -> MCPTool {
        guard let name = dict["name"] as? String else {
            throw MCPServiceError.invalidResponse("Tool missing 'name' field")
        }

        guard let description = dict["description"] as? String else {
            throw MCPServiceError.invalidResponse("Tool '\(name)' missing 'description' field")
        }

        guard let inputSchema = dict["inputSchema"] as? [String: Any] else {
            throw MCPServiceError.invalidResponse("Tool '\(name)' missing 'inputSchema' field")
        }

        do {
            let schema = try parseJSONSchema(from: inputSchema)

            return MCPTool(
                name: name,
                description: description,
                inputSchema: schema,
                serverName: serverConfig.name
            )
        } catch {
            throw MCPServiceError.invalidResponse("Failed to parse schema for tool '\(name)': \(error.localizedDescription)")
        }
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

    private func parseResource(from dict: [String: Any]) -> MCPResource? {
        guard let uri = dict["uri"] as? String,
              let name = dict["name"] as? String
        else {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Skipping invalid resource",
                metadata: ["server": serverConfig.name]
            )
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

    func isActiveTransport(_ transportID: UUID) -> Bool {
        withLock { activeLifecycle?.id == transportID }
    }

    func hasActiveReplacement(for transportID: UUID) -> Bool {
        withLock {
            guard let activeLifecycle else { return false }
            return activeLifecycle.id != transportID
        }
    }
}

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
            "Not connected to MCP server"
        case .encodingFailed:
            "Failed to encode request"
        case let .initializationFailed(message):
            "Failed to initialize MCP server: \(message)"
        case let .invalidResponse(message):
            "Invalid response from MCP server: \(message)"
        case let .toolExecutionFailed(message):
            "Tool execution failed: \(message)"
        case .timeout:
            "Operation timed out"
        }
    }
}

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MCPServiceError.timeout
        }

        guard let result = try await group.next() else {
            throw MCPServiceError.timeout
        }
        group.cancelAll()
        return result
    }
}
#endif
