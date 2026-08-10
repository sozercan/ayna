//
//  MCPService.swift
//  ayna
//
//  Created on 11/3/25.
//

#if os(macOS)
import Combine
import Darwin
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

private struct MCPRequestCompletionAction: Sendable {
    enum Reason: Sendable {
        case cancelled
        case timedOut

        var notificationReason: String {
            switch self {
            case .cancelled:
                "Client cancelled request"
            case .timedOut:
                "Client request timed out"
            }
        }
    }

    let id: Int
    let method: String
    let transportID: UUID
    let reason: Reason
    let requiresTransportInvalidation: Bool
}

private final class PendingMCPRequestStore: @unchecked Sendable {
    private enum WriteState {
        case queued
        case writing
        case written
    }

    private struct Entry {
        let method: String
        let transportID: UUID
        let continuation: CheckedContinuation<MCPResponse, Error>
        var timeoutTask: Task<Void, Never>?
        var writeState: WriteState
    }

    private struct CompletionOutcome {
        let entry: Entry
        let action: MCPRequestCompletionAction?
    }

    private let timeoutSeconds: TimeInterval
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    init(timeoutSeconds: TimeInterval) {
        self.timeoutSeconds = max(0, timeoutSeconds)
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    func insert(
        id: Int,
        method: String,
        transportID: UUID,
        continuation: CheckedContinuation<MCPResponse, Error>,
        timeoutHandler: @escaping @Sendable (MCPRequestCompletionAction) -> Void
    ) {
        lock.withLock {
            entries[id] = Entry(
                method: method,
                transportID: transportID,
                continuation: continuation,
                timeoutTask: nil,
                writeState: .queued
            )
    }

        let timeoutSeconds = self.timeoutSeconds
        let timeoutTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
        }

            guard let action = self?.timeoutRequest(id: id) else { return }
            timeoutHandler(action)
        }

        let shouldCancelTimeout = lock.withLock { () -> Bool in
            guard var entry = entries[id] else { return true }
            entry.timeoutTask = timeoutTask
            entries[id] = entry
            return false
        }
        if shouldCancelTimeout {
            timeoutTask.cancel()
        }
    }

    func beginWrite(id: Int) -> Bool {
        lock.withLock {
            guard var entry = entries[id], entry.writeState == .queued else { return false }
            entry.writeState = .writing
            entries[id] = entry
            return true
        }
    }

    func finishWrite(id: Int) -> MCPRequestCompletionAction? {
        lock.withLock {
            if var entry = entries[id], entry.writeState == .writing {
                entry.writeState = .written
                entries[id] = entry
            }
            return nil
        }
    }

    func failWrite(id: Int, error: Error) {
        let continuation: CheckedContinuation<MCPResponse, Error>? = lock.withLock {
            guard let entry = entries.removeValue(forKey: id) else { return nil }
            entry.timeoutTask?.cancel()
            return entry.continuation
        }
        continuation?.resume(throwing: error)
    }

    func cancel(id: Int) -> MCPRequestCompletionAction? {
        guard let outcome = complete(id: id, reason: .cancelled) else { return nil }
        outcome.entry.continuation.resume(throwing: CancellationError())
        return outcome.action
    }

    @discardableResult
    func resume(id: Int, with response: MCPResponse) -> Bool {
        guard let entry = take(id: id) else { return false }
        entry.continuation.resume(returning: response)
        return true
    }

    @discardableResult
    func fail(id: Int, error: Error) -> Bool {
        guard let entry = take(id: id) else { return false }
        entry.continuation.resume(throwing: error)
        return true
    }

    func failAll(for transportID: UUID, error: Error) {
        let continuations: [CheckedContinuation<MCPResponse, Error>] = lock.withLock {
            let matchingIDs = entries.compactMap { id, entry in
                entry.transportID == transportID ? id : nil
            }
            let matchingEntries = matchingIDs.compactMap { entries.removeValue(forKey: $0) }
            matchingEntries.forEach { $0.timeoutTask?.cancel() }
            return matchingEntries.map(\.continuation)
        }
        continuations.forEach { $0.resume(throwing: error) }
    }

    func failAll(error: Error) {
        let continuations: [CheckedContinuation<MCPResponse, Error>] = lock.withLock {
            let allEntries = Array(entries.values)
            entries.removeAll()
            allEntries.forEach { $0.timeoutTask?.cancel() }
            return allEntries.map(\.continuation)
        }
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func timeoutRequest(id: Int) -> MCPRequestCompletionAction? {
        guard let outcome = complete(id: id, reason: .timedOut) else { return nil }

        DiagnosticsLogger.log(
            .mcpService,
            level: .error,
            message: "MCP request timed out",
            metadata: ["id": "\(id)", "method": outcome.entry.method]
        )
        outcome.entry.continuation.resume(throwing: MCPServiceError.timeout)
        return outcome.action
    }

    private func complete(id: Int, reason: MCPRequestCompletionAction.Reason) -> CompletionOutcome? {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: id) else { return nil }
            entry.timeoutTask?.cancel()

            switch entry.writeState {
            case .queued:
                return CompletionOutcome(entry: entry, action: nil)
            case .writing:
                return CompletionOutcome(
                    entry: entry,
                    action: MCPRequestCompletionAction(
                        id: id,
                        method: entry.method,
                        transportID: entry.transportID,
                        reason: reason,
                        requiresTransportInvalidation: true
                    )
                )
            case .written:
                return CompletionOutcome(
                    entry: entry,
                    action: MCPRequestCompletionAction(
                        id: id,
                        method: entry.method,
                        transportID: entry.transportID,
                        reason: reason,
                        requiresTransportInvalidation: false
                    )
                )
            }
        }
    }

    private func take(id: Int) -> Entry? {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: id) else { return nil }
            entry.timeoutTask?.cancel()
            return entry
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class MCPTransportLease: @unchecked Sendable {
    let id: UUID

    private let inputHandle: FileHandle
    private let lock = NSLock()
    private var isActive = true

    init(id: UUID, inputHandle: FileHandle) {
        self.id = id
        self.inputHandle = inputHandle
        // Closing a wedged transport from another task must make blocked writes fail with
        // EPIPE rather than terminating the entire app with SIGPIPE.
        _ = fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func invalidate() {
        lock.withLock { isActive = false }
    }

    func activeInputHandle() throws -> FileHandle {
        try lock.withLock {
            guard isActive else { throw MCPServiceError.notConnected }
            return inputHandle
        }
    }
}

private final class MCPProcessLifecycle: @unchecked Sendable {
    private struct State {
        var isManualDisconnect = false
        var isRegistered = false
        var isFinalized = false
    }

    let id: UUID
    let process: Process
    let inputPipe: Pipe
    let outputPipe: Pipe
    let errorPipe: Pipe
    let lease: MCPTransportLease
    let trackingKey: String

    private let registerProcess: @Sendable (String, pid_t) -> Void
    private let unregisterProcess: @Sendable (String) -> Void
    private let lock = NSLock()
    private var state = State()

    init(
        id: UUID,
        serverName: String,
        process: Process,
        inputPipe: Pipe,
        outputPipe: Pipe,
        errorPipe: Pipe,
        registerProcess: @escaping @Sendable (String, pid_t) -> Void,
        unregisterProcess: @escaping @Sendable (String) -> Void
    ) {
        self.id = id
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        lease = MCPTransportLease(id: id, inputHandle: inputPipe.fileHandleForWriting)
        trackingKey = "\(serverName)#\(id.uuidString)"
        self.registerProcess = registerProcess
        self.unregisterProcess = unregisterProcess
    }

    func registerAfterLaunch() {
        lock.lock()
        guard !state.isFinalized, !state.isRegistered else {
            lock.unlock()
            return
        }
        registerProcess(trackingKey, process.processIdentifier)
        state.isRegistered = true
        lock.unlock()
    }

    func markManualDisconnect() {
        lock.withLock { state.isManualDisconnect = true }
    }

    func stopReading() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Returns whether this was a manual disconnect. Nil means another exit observer finalized it.
    func finalize() -> Bool? {
        let finalization: (manual: Bool, shouldUnregister: Bool)? = lock.withLock {
            guard !state.isFinalized else { return nil }
            state.isFinalized = true
            return (state.isManualDisconnect, state.isRegistered)
        }
        guard let finalization else { return nil }

        stopReading()
        lease.invalidate()
        if finalization.shouldUnregister {
            unregisterProcess(trackingKey)
        }
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
        return finalization.manual
    }
}

private actor MCPOutboundWriter {
    typealias MessageWriteHandler = @Sendable (FileHandle, Data) throws -> Void

    private let writeHandler: MessageWriteHandler

    init(writeHandler: @escaping MessageWriteHandler) {
        self.writeHandler = writeHandler
    }

    func writeRequest(
        id: Int,
        method: String,
        data: Data,
        lifecycle: MCPProcessLifecycle,
        store: PendingMCPRequestStore,
        beforeWrite: (@Sendable (Int, String) -> Void)?,
        completionHandler: @escaping @Sendable (MCPRequestCompletionAction) -> Void
    ) {
        beforeWrite?(id, method)
        guard store.beginWrite(id: id) else { return }

        do {
            try write(data, lifecycle: lifecycle)
            if let action = store.finishWrite(id: id) {
                completionHandler(action)
            }
        } catch {
            store.failWrite(id: id, error: error)
        }
    }

    func writeNotification(_ data: Data, lifecycle: MCPProcessLifecycle) throws {
        try write(data, lifecycle: lifecycle)
    }

    private func write(_ data: Data, lifecycle: MCPProcessLifecycle) throws {
        let inputHandle = try lifecycle.lease.activeInputHandle()
        try writeHandler(inputHandle, data)
    }
}

/// Service for communicating with MCP servers via stdio
class MCPService: ObservableObject, MCPServicing, @unchecked Sendable {
    private var activeLifecycle: MCPProcessLifecycle?
    private var lifecycles: [UUID: MCPProcessLifecycle] = [:]
    private var healthCheckTask: (transportID: UUID, task: Task<Void, Never>)?

    private var requestId = 0
    private let pendingRequests: PendingMCPRequestStore
    private let requestWriteHook: (@Sendable (Int, String) -> Void)?
    private let outboundWriter: MCPOutboundWriter
    private let terminationGracePeriod: TimeInterval
    private let processRegistrationHandler: @Sendable (String, pid_t) -> Void
    private let processUnregistrationHandler: @Sendable (String) -> Void

    let serverConfig: MCPServerConfig
    @Published var isConnected = false
    @Published var lastError: String?
    weak var delegate: MCPServiceDelegate?

    private var outputBuffer = ""
    private let stateLock = NSLock()

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
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

    // MARK: - Connection Management

    /// This routine wires up the MCP subprocess, pipes, and async stream handlers in one place so we
    /// can share the same cleanup/error propagation. Splitting it today would duplicate fragile state
    /// management, so we temporarily allow the longer body until the connection pipeline is refactored.
    func connect() async throws {
        guard withLock({ activeLifecycle == nil }) else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        DiagnosticsLogger.log(
            .mcpService,
            level: .info,
            message: "Looking for executable",
            metadata: ["command": serverConfig.command]
        )
        let commandPath: String
        do {
            commandPath = try findExecutable(serverConfig.command)
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "Using executable path",
                metadata: ["path": commandPath]
            )
        } catch {
            let errorMsg = "Executable not found: \(serverConfig.command) - \(error.localizedDescription)"
            DiagnosticsLogger.log(.mcpService, level: .error, message: errorMsg)
            await MainActor.run { [weak self] in
                self?.lastError = errorMsg
            }
            throw MCPServiceError.initializationFailed(errorMsg)
        }

        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = serverConfig.args

        var environment = ProcessInfo.processInfo.environment
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/opt/homebrew/opt/node/bin",
            NSHomeDirectory() + "/.nvm/versions/node/*/bin"
        ]
        environment["PATH"] = (commonPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
            for (key, value) in serverConfig.env {
                environment[key] = value
            }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

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

        process.terminationHandler = { [weak self, lifecycle] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            terminatedProcess.terminationHandler = nil
            if let self {
                self.processDidExit(lifecycle, exitCode: exitCode)
            } else {
                _ = lifecycle.finalize()
        }
        }

        let serverName = serverConfig.name
        outputPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
                let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.handleOutput(output, transportID: lifecycle.id)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
                let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                    DiagnosticsLogger.log(
                        .mcpService,
                        level: .info,
                        message: "MCP server stderr",
                        metadata: ["server": serverName, "output": output]
                    )
                    if output.lowercased().contains("error") || output.lowercased().contains("failed") {
                Task { @MainActor [weak self] in
                    guard let self, self.isActiveTransport(lifecycle.id) else { return }
                    self.lastError = output
                }
            }
        }

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
    private func disconnect(transportID: UUID?) -> Bool {
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

    // MARK: - MCP Protocol Methods

    private func initialize(on lifecycle: MCPProcessLifecycle) async throws {
        let response = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": AnyCodable("2024-11-05"),
                "capabilities": AnyCodable([
                    "roots": ["list_changed": true],
                    "sampling": [:]
                ] as [String: Any]),
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

        // Send initialized notification on the same transport generation.
        try await sendNotification(method: "notifications/initialized", lifecycle: lifecycle)
    }

    func listTools() async throws -> [MCPTool] {
        let response = try await sendRequest(method: "tools/list", params: nil)

        guard let result = response.result?.value as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]]
        else {
            throw MCPServiceError.invalidResponse("Failed to parse tools list")
        }

        // Parse tools individually, skipping invalid ones instead of crashing
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

        // Handle different content types
        if let content = result["content"] as? [[String: Any]] {
            // Multiple content items
            let texts = content.compactMap { item -> String? in
                if item["type"] as? String == "text",
                   let text = item["text"] as? String
                {
                    return text
                }
                return nil
            }
            return texts.joined(separator: "\n")
        } else if let text = result["content"] as? String {
            // Single text content
            return text
        } else {
            throw MCPServiceError.invalidResponse("Unexpected content format in tool result")
        }
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

    // MARK: - Low-level JSON-RPC

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

    /// MCP 2024-11-05 cancellation schema:
    /// `notifications/cancelled` with params `{ "requestId": RequestId, "reason"?: string }`.
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

    private func handleOutput(_ output: String, transportID: UUID) {
        let completedLines: [String] = withLock {
            guard activeLifecycle?.id == transportID else { return [] }
            if outputBuffer.count + output.count > 1_048_576 {
                DiagnosticsLogger.log(.mcpService, level: .error, message: "MCP output buffer exceeded 1MB limit, clearing")
                outputBuffer = ""
                return []
            }
            outputBuffer += output

            // Process complete JSON-RPC messages (newline-delimited)
            let lines = outputBuffer.components(separatedBy: "\n")

            // Keep the last incomplete line in the buffer
            if let last = lines.last, !output.hasSuffix("\n") {
                outputBuffer = last
            } else {
                outputBuffer = ""
            }

            return Array(lines.dropLast())
        }

        // Process complete lines
        for line in completedLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            processJSONRPCMessage(trimmed)
        }
    }

    private func processJSONRPCMessage(_ json: String) {
        guard let data = json.data(using: .utf8) else {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to convert JSON string to data",
                metadata: ["server": serverConfig.name]
            )
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

    // MARK: - Parsing Helpers

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

    // MARK: - Helper Methods

    private func findExecutable(_ command: String) throws -> String {
        // If command is already an absolute path, validate it exists
        if command.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw MCPServiceError.initializationFailed("Executable not found at path: \(command)")
            }
            return command
        }

        // Common locations to search for executables
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]

        // Search in common paths
        for path in searchPaths {
            let fullPath = "\(path)/\(command)"
            DiagnosticsLogger.log(
                .mcpService,
                level: .debug,
                message: "Checking executable path",
                metadata: ["path": fullPath]
            )
            let exists = FileManager.default.fileExists(atPath: fullPath)
            let isExecutable = FileManager.default.isExecutableFile(atPath: fullPath)
            DiagnosticsLogger.log(
                .mcpService,
                level: .debug,
                message: "Executable candidate",
                metadata: ["exists": "\(exists)", "executable": "\(isExecutable)", "path": fullPath]
            )

            if isExecutable {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .info,
                    message: "Found executable",
                    metadata: ["command": command, "path": fullPath]
                )
                return fullPath
            }
        }

        // Fallback: Try to use 'which' command with a proper shell environment
        // This is important because the sandboxed app may not have access to the same PATH
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        shellProcess.arguments = ["-l", "-c", "which '\(command.replacingOccurrences(of: "'", with: "'\\''"))'"]

        // Set up environment to use the user's actual PATH
        var environment = ProcessInfo.processInfo.environment
        // Add common paths to ensure we find executables
        let commonPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = commonPaths
        shellProcess.environment = environment

        let pipe = Pipe()
        shellProcess.standardOutput = pipe
        shellProcess.standardError = Pipe()

        do {
            try shellProcess.run()
            shellProcess.waitUntilExit()

            if shellProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty,
                   FileManager.default.isExecutableFile(atPath: path)
                {
                    DiagnosticsLogger.log(
                        .mcpService,
                        level: .info,
                        message: "Found executable via shell",
                        metadata: ["command": command, "path": path]
                    )
                    return path
                }
            }
        } catch {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to find executable via shell",
                metadata: ["command": command, "error": "\(error)"]
            )
        }

        // Could not find executable
        let errorMsg = """
        Could not find executable '\(command)'.

        Please ensure Node.js and npm are installed:
        - Install via Homebrew: brew install node
        - Or download from: https://nodejs.org/

        Searched in:
        \(searchPaths.joined(separator: "\n"))
        """
        throw MCPServiceError.initializationFailed(errorMsg)
    }

    // MARK: - Connection Monitoring

    private func isActiveTransport(_ transportID: UUID) -> Bool {
        withLock { activeLifecycle?.id == transportID }
    }

    private func hasActiveReplacement(for transportID: UUID) -> Bool {
        withLock {
            guard let activeLifecycle else { return false }
            return activeLifecycle.id != transportID
        }
    }

    private func startHealthCheckTimer(for lifecycle: MCPProcessLifecycle) {
        let task = Task { [weak self, lifecycle] in
            do {
                try await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                    guard let self, self.isActiveTransport(lifecycle.id) else { return }
                    if !lifecycle.process.isRunning {
                        let exitCode = lifecycle.process.processIdentifier > 0
                            ? lifecycle.process.terminationStatus
                            : nil
                        self.processDidExit(lifecycle, exitCode: exitCode)
                    return
                }
                    try await Task.sleep(for: .seconds(5))
            }
            } catch {
                // Cancellation is the expected shutdown path.
        }
    }

        withLock {
            healthCheckTask?.task.cancel()
            healthCheckTask = (lifecycle.id, task)
        }
    }

    private func processDidExit(_ lifecycle: MCPProcessLifecycle, exitCode: Int32?) {
        guard let wasManualDisconnect = lifecycle.finalize() else { return }

        let wasActive = withLock { () -> Bool in
            lifecycles.removeValue(forKey: lifecycle.id)
            guard activeLifecycle?.id == lifecycle.id else { return false }
            activeLifecycle = nil
            outputBuffer = ""
            if healthCheckTask?.transportID == lifecycle.id {
                healthCheckTask?.task.cancel()
                healthCheckTask = nil
            }
            return true
    }
        pendingRequests.failAll(for: lifecycle.id, error: MCPServiceError.notConnected)
        guard wasActive else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.hasActiveReplacement(for: lifecycle.id) else { return }
            self.isConnected = false
            guard !wasManualDisconnect else { return }

            let message = if let exitCode, exitCode != 0 {
                "Exited with code \(exitCode)"
            } else {
                "MCP server process ended unexpectedly"
            }
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Lost MCP connection",
                metadata: [
                    "server": self.serverConfig.name,
                    "reason": message,
                    "transport": lifecycle.id.uuidString
                ]
            )
            self.lastError = message
            self.delegate?.mcpService(self, didTerminateWithError: message)
        }
    }

    private static func terminateProcess(_ lifecycle: MCPProcessLifecycle, gracePeriod: TimeInterval) {
        terminateProcess(lifecycle, gracePeriod: gracePeriod) { _ in
            _ = lifecycle.finalize()
        }
        }

    private static func terminateProcess(
        _ lifecycle: MCPProcessLifecycle,
        gracePeriod: TimeInterval,
        completion: @escaping @Sendable (Int32?) -> Void
    ) {
        Task.detached {
            let process = lifecycle.process
            if process.isRunning {
                process.terminate()
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(gracePeriod))
                while process.isRunning, clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }

                if process.isRunning {
                    DiagnosticsLogger.log(
                        .mcpService,
                        level: .info,
                        message: "MCP process ignored SIGTERM; escalating to SIGKILL",
                        metadata: [
                            "pid": "\(process.processIdentifier)",
                            "transport": lifecycle.id.uuidString
                        ]
                    )
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }

                if process.isRunning {
                    process.waitUntilExit()
                }
            }

            let exitCode = process.processIdentifier > 0 && !process.isRunning
                ? process.terminationStatus
                : nil
            completion(exitCode)
        }
    }
}

// MARK: - Errors

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

// MARK: - Timeout Helper

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
