// swiftformat:options --ifdef no-indent

#if os(macOS)
import Darwin
import Foundation

struct MCPRequestCompletionAction: Sendable {
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

final class PendingMCPRequestStore: @unchecked Sendable {
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

final class MCPTransportLease: @unchecked Sendable {
    let id: UUID

    private let inputHandle: FileHandle
    private let lock = NSLock()
    private var isActive = true

    init(id: UUID, inputHandle: FileHandle) {
        self.id = id
        self.inputHandle = inputHandle
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

final class MCPProcessLifecycle: @unchecked Sendable {
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

actor MCPOutboundWriter {
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

extension MCPService {
    func resolveExecutablePath() async throws -> String {
        DiagnosticsLogger.log(
            .mcpService,
            level: .info,
            message: "Looking for executable",
            metadata: ["command": serverConfig.command]
        )
        do {
            let commandPath = try findExecutable(serverConfig.command)
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "Using executable path",
                metadata: ["path": commandPath]
            )
            return commandPath
        } catch {
            let errorMsg = "Executable not found: \(serverConfig.command) - \(error.localizedDescription)"
            DiagnosticsLogger.log(.mcpService, level: .error, message: errorMsg)
            await MainActor.run { [weak self] in
                self?.lastError = errorMsg
            }
            throw MCPServiceError.initializationFailed(errorMsg)
        }
    }

    func makeConfiguredProcess(
        executablePath: String,
        inputPipe: Pipe,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
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
        return process
    }

    func configureTransportHandlers(for lifecycle: MCPProcessLifecycle) {
        lifecycle.process.terminationHandler = { [weak self, lifecycle] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            terminatedProcess.terminationHandler = nil
            if let self {
                self.processDidExit(lifecycle, exitCode: exitCode)
            } else {
                _ = lifecycle.finalize()
            }
        }

        let serverName = serverConfig.name
        lifecycle.outputPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.handleOutput(output, transportID: lifecycle.id)
        }

        lifecycle.errorPipe.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
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
    }

    func findExecutable(_ command: String) throws -> String {
        if command.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw MCPServiceError.initializationFailed("Executable not found at path: \(command)")
            }
            return command
        }

        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]

        if let found = findExecutableInSearchPaths(command, searchPaths: searchPaths) {
            return found
        }

        if let found = findExecutableViaShell(command) {
            return found
        }

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

    private func findExecutableInSearchPaths(_ command: String, searchPaths: [String]) -> String? {
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
        return nil
    }

    private func findExecutableViaShell(_ command: String) -> String? {
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        shellProcess.arguments = ["-l", "-c", "which '\(command.replacingOccurrences(of: "'", with: "'\\''"))'"]

        var environment = ProcessInfo.processInfo.environment
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
        return nil
    }

    func startHealthCheckTimer(for lifecycle: MCPProcessLifecycle) {
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
            } catch {}
        }

        withLock {
            healthCheckTask?.task.cancel()
            healthCheckTask = (lifecycle.id, task)
        }
    }

    func processDidExit(_ lifecycle: MCPProcessLifecycle, exitCode: Int32?) {
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

    static func terminateProcess(_ lifecycle: MCPProcessLifecycle, gracePeriod: TimeInterval) {
        terminateProcess(lifecycle, gracePeriod: gracePeriod) { _ in
            _ = lifecycle.finalize()
        }
    }

    static func terminateProcess(
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
