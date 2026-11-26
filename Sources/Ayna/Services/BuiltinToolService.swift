import Foundation
import os.log

#if os(macOS)
    import Darwin

    private final class PipeAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let maxSize: Int
        private var _data = Data()
        private var _truncated = false

        init(maxSize: Int) {
            self.maxSize = maxSize
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }

        var truncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _truncated
        }

        func append(_ newData: Data) {
            lock.lock()
            defer { lock.unlock() }
            if _data.count >= maxSize {
                _truncated = true
                return
            }

            let remaining = maxSize - _data.count
            if newData.count > remaining {
                _data.append(newData.prefix(remaining))
                _truncated = true
            } else {
                _data.append(newData)
            }
        }
    }

    private final class ProcessExecutionController: @unchecked Sendable {
        private struct State {
            var process: CommandSubprocess?
            var isCancelled = false
            var completionCommitted = false
            var terminationRequested = false
            var timedOut = false
        }

        private let lock = NSLock()
        private let processEscalationGate: @Sendable () async -> Void
        private let subprocessSignal: CommandSubprocess.SignalProcess
        private var state = State()

        init(
            processEscalationGate: @escaping @Sendable () async -> Void,
            subprocessSignal: @escaping CommandSubprocess.SignalProcess
        ) {
            self.processEscalationGate = processEscalationGate
            self.subprocessSignal = subprocessSignal
        }

        func start(command: String, workingDirectory: URL?) throws -> CommandSubprocess? {
            lock.lock()
            guard !state.isCancelled else {
                lock.unlock()
                return nil
            }
            do {
                let process = try CommandSubprocess.start(
                    command: command,
                    workingDirectory: workingDirectory,
                    signalProcess: subprocessSignal
                )
                state.process = process
                lock.unlock()
                return process
            } catch {
                state.process = nil
                lock.unlock()
                throw error
            }
        }

        func cancel() {
            requestTermination(markCancelled: true)
        }

        func timeout() {
            lock.lock()
            if !state.completionCommitted {
                state.timedOut = true
            }
            lock.unlock()
            requestTermination(markCancelled: false)
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.timedOut
        }

        func commitCompletion() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !state.completionCommitted else { return false }
            state.completionCommitted = true
            state.process = nil
            return !state.isCancelled
        }

        func didReap(_ process: CommandSubprocess) {
            lock.lock()
            defer { lock.unlock() }
            if state.process === process {
                state.process = nil
            }
        }

        private func requestTermination(markCancelled: Bool) {
            lock.lock()
            guard !state.completionCommitted else {
                lock.unlock()
                return
            }
            if markCancelled {
                state.isCancelled = true
            }
            guard !state.terminationRequested else {
                lock.unlock()
                return
            }
            state.terminationRequested = true
            let process = state.process
            lock.unlock()

            guard let process, process.isRunning else { return }
            process.terminate()

            let processEscalationGate = processEscalationGate
            Task.detached { [weak self] in
                await processEscalationGate()
                guard let self, self.shouldForceKill(process) else { return }
                process.forceKill()
            }
        }

        private func shouldForceKill(_ process: CommandSubprocess) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !state.completionCommitted,
                  state.process === process
            else {
                return false
            }
            return process.isRunning
        }
    }

    @Observable @MainActor
    final class BuiltinToolService {
        private let permissionService: PermissionService
        private var shellSandbox: ShellSandbox
        private(set) var pathValidator: PathValidator
        private let processStartGate: @Sendable () async -> Void
        private let processCompletionGate: @Sendable () async -> Void
        private let processEscalationGate: @Sendable () async -> Void
        private let subprocessSignal: CommandSubprocess.SignalProcess
        private(set) var projectRoot: URL?

        var isEnabled: Bool = true

        var commandTimeoutSeconds: Int = 30

        var toolPermissions: [String: PermissionLevel] = AgentSettings.default.defaultPermissions

        var requireApprovalOutsideProject = true

        let maxReadSize: Int = 10 * 1024 * 1024

        let maxOutputSize: Int = 10_485_760

        private let maxSearchResults: Int = 100

        private let fileSizeFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter
        }()

        enum ToolName {
            static let readFile = "read_file"
            static let writeFile = "write_file"
            static let editFile = "edit_file"
            static let listDirectory = "list_directory"
            static let searchFiles = "search_files"
            static let runCommand = "run_command"
            static let gitContext = "git_context"
            static let projectContext = "project_context"
            static let updateTasks = "update_tasks"
        }

        init(
            permissionService: PermissionService,
            shellSandbox: ShellSandbox? = nil,
            projectRoot: URL? = nil,
            processStartGate: @escaping @Sendable () async -> Void = {},
            processCompletionGate: @escaping @Sendable () async -> Void = {},
            processEscalationGate: @escaping @Sendable () async -> Void = {
                try? await Task.sleep(for: .milliseconds(250))
            },
            subprocessSignal: @escaping CommandSubprocess.SignalProcess = { Darwin.kill($0, $1) }
        ) {
            self.permissionService = permissionService
            self.projectRoot = projectRoot
            self.pathValidator = PathValidator(projectRoot: projectRoot)
            self.shellSandbox = shellSandbox ?? ShellSandbox(projectRoot: projectRoot)
            self.processStartGate = processStartGate
            self.processCompletionGate = processCompletionGate
            self.processEscalationGate = processEscalationGate
            self.subprocessSignal = subprocessSignal
        }

        func apply(_ settings: AgentSettings) {
            isEnabled = settings.isEnabled
            commandTimeoutSeconds = settings.commandTimeoutSeconds
            toolPermissions = settings.defaultPermissions
            requireApprovalOutsideProject = settings.requireApprovalOutsideProject
            let root = settings.projectRootPath.flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: PathValidator.expandPath(path), isDirectory: true)
            }
            projectRoot = root
            pathValidator = PathValidator(projectRoot: root)
            shellSandbox = ShellSandbox(
                allowedCommands: ShellSandbox.defaultAllowed.union(
                    settings.additionalAllowedCommands.map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                ),
                blockedPatterns: ShellSandbox.defaultBlocked + settings.additionalBlockedPatterns
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                projectRoot: root
            )
        }

        var baseDirectory: URL {
            projectRoot ?? FileManager.default.homeDirectoryForCurrentUser
        }

        func anchoredPath(_ path: String) -> String {
            guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.hasPrefix("$") else { return path }
            let base = baseDirectory.path
            guard !path.isEmpty, path != "." else { return base }
            return (base as NSString).appendingPathComponent(path)
        }

        func authorize(
            tool: String,
            description: String,
            details: String,
            riskReason: String?,
            diffPreview: String? = nil,
            remembersApproval: Bool = true,
            conversationId: UUID
        ) async throws {
            let level = toolPermissions[tool] ?? .askAlways
            guard level != .denied else {
                throw ToolExecutionError.permissionDenied(tool: tool, reason: "Set to Denied in Agent settings")
            }
            let rememberedForSession = permissionService.checkPermission(
                tool: tool,
                details: details,
                defaultLevel: .askAlways
            ) == .automatic
            guard !rememberedForSession, level != .automatic || riskReason != nil else { return }

            let approved = await permissionService.requestApproval(
                toolName: tool,
                description: riskReason.map { "\(description): \($0)" } ?? description,
                details: details,
                diffPreview: diffPreview,
                conversationId: conversationId
            )
            try Task.checkCancellation()
            guard approved else {
                throw ToolExecutionError.permissionDenied(tool: tool, reason: "User denied")
            }
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }
            guard (toolPermissions[tool] ?? .askAlways) != .denied else {
                throw ToolExecutionError.permissionDenied(tool: tool, reason: "Set to Denied in Agent settings")
            }
            if level == .askOnce, remembersApproval {
                permissionService.recordSessionApproval(tool: tool, details: details)
            }
        }

        func readFile(path: String, conversationId: UUID) async throws -> String {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "read_file requested", metadata: ["path": path])

            guard let resolvedURL = pathValidator.canonicalize(anchoredPath(path)) else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path")
            }
            return try await readFile(at: resolvedURL, displayPath: path, conversationId: conversationId)
        }

        private func readFile(
            at resolvedURL: URL,
            displayPath path: String,
            tool: String = ToolName.readFile,
            conversationId: UUID
        ) async throws -> String {
            let riskReason: String?
            switch pathValidator.validate(url: resolvedURL, operation: .read) {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                riskReason = reason
            case .allowed:
                riskReason = nil
            }
            if tool == ToolName.readFile || riskReason != nil {
                try await authorize(
                    tool: tool,
                    description: tool == ToolName.readFile ? "Read file" : "Read file before editing",
                    details: tool == ToolName.readFile ? resolvedURL.path : "\(resolvedURL.path) (read before editing)",
                    riskReason: riskReason,
                    remembersApproval: tool == ToolName.readFile,
                    conversationId: conversationId
                )
            }

            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                throw ToolExecutionError.fileNotFound(path: path)
            }

            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
                if let size = attributes[.size] as? Int, size > maxReadSize {
                    throw ToolExecutionError.resourceLimitExceeded(
                        resource: "file size",
                        limit: "\(maxReadSize / 1024 / 1024) MB"
                    )
                }
            } catch let error as ToolExecutionError {
                throw error
            } catch {
                throw ToolExecutionError.fileNotReadable(path: path, underlying: error.localizedDescription)
            }

            do {
                let data = try Data(contentsOf: resolvedURL)

                if isBinaryData(data) {
                    throw ToolExecutionError.binaryFileUnsupported(path: path)
                }

                guard let content = String(data: data, encoding: .utf8) else {
                    throw ToolExecutionError.binaryFileUnsupported(path: path)
                }

                log(.info, "read_file completed", metadata: ["path": path, "size": "\(content.count)"])
                return content
            } catch let error as ToolExecutionError {
                throw error
            } catch {
                throw ToolExecutionError.fileNotReadable(path: path, underlying: error.localizedDescription)
            }
        }

        func writeFile(path: String, content: String, conversationId: UUID) async throws {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "write_file requested", metadata: ["path": path])
            let path = anchoredPath(path)

            let validation = pathValidator.validate(
                path,
                operation: .write,
                requireApprovalOutsideProject: requireApprovalOutsideProject
            )
            let requiresApprovalReason: String?
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                requiresApprovalReason = reason
            case .allowed:
                requiresApprovalReason = nil
            }

            let approvedTarget = resolvedTargetURL(for: path)

            try await authorize(
                tool: ToolName.writeFile,
                description: requiresApprovalReason == nil ? "Create/overwrite file" : "Write file",
                details: approvedTarget.path,
                riskReason: requiresApprovalReason,
                conversationId: conversationId
            )

            let url = try requireUnchangedTarget(approvedTarget, for: path)

            let revalidation = pathValidator.validate(
                url: url,
                operation: .write,
                requireApprovalOutsideProject: requireApprovalOutsideProject
            )
            switch revalidation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: "Path denied after re-resolution: \(reason)")
            case let .requiresApproval(reason) where requiresApprovalReason == nil:
                throw ToolExecutionError.invalidPath(path: path, reason: "Path changed after approval (re-resolution requires new approval): \(reason)")
            case .requiresApproval, .allowed:
                break
            }

            let parentDir = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                throw ToolExecutionError.fileNotWritable(path: path, underlying: "Cannot create directory: \(error.localizedDescription)")
            }

            try Task.checkCancellation()

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                log(.info, "write_file completed", metadata: ["path": path, "size": "\(content.count)"])
            } catch {
                throw ToolExecutionError.fileNotWritable(path: path, underlying: error.localizedDescription)
            }
        }

        private func resolvedTargetURL(for path: String) -> URL {
            let expandedURL = URL(fileURLWithPath: PathValidator.expandPath(path))
            if FileManager.default.fileExists(atPath: expandedURL.path) {
                return expandedURL.resolvingSymlinksInPath().standardized
            }
            return expandedURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(expandedURL.lastPathComponent).standardized
        }

        private func requireUnchangedTarget(_ approvedTarget: URL, for path: String) throws -> URL {
            let currentTarget = resolvedTargetURL(for: path)
            guard currentTarget.path == approvedTarget.path else {
                throw ToolExecutionError.invalidPath(
                    path: path,
                    reason: "Path target changed while awaiting approval (\(approvedTarget.path) → \(currentTarget.path))"
                )
            }
            return currentTarget
        }

        func editFile(path: String, oldText: String, newText: String, conversationId: UUID) async throws {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "edit_file requested", metadata: ["path": path])
            let path = anchoredPath(path)

            guard !oldText.isEmpty else {
                throw ToolExecutionError.emptySearchText
            }

            if oldText == newText {
                log(.info, "edit_file no-op: oldText == newText", metadata: ["path": path])
                return
            }

            let approvedTarget = resolvedTargetURL(for: path)

            let currentContent = try await readFile(
                at: approvedTarget,
                displayPath: path,
                tool: ToolName.editFile,
                conversationId: conversationId
            )
            _ = try requireUnchangedTarget(approvedTarget, for: path)

            let occurrences = currentContent.ranges(of: oldText)

            if occurrences.isEmpty {
                throw ToolExecutionError.editNotFound(path: path, searchText: oldText)
            }

            if occurrences.count > 1 {
                throw ToolExecutionError.editAmbiguous(path: path, matchCount: occurrences.count)
            }

            let newContent = currentContent.replacingOccurrences(of: oldText, with: newText)

            let diffPreview = generateDiffPreview(oldText: oldText, newText: newText)

            let validation = pathValidator.validate(
                path,
                operation: .write,
                requireApprovalOutsideProject: requireApprovalOutsideProject
            )
            let editApprovalReason: String?
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                editApprovalReason = reason
            case .allowed:
                editApprovalReason = nil
            }

            try await authorize(
                tool: ToolName.editFile,
                description: "Edit file",
                details: approvedTarget.path,
                riskReason: editApprovalReason,
                diffPreview: diffPreview,
                conversationId: conversationId
            )

            let url = try requireUnchangedTarget(approvedTarget, for: path)

            let revalidation = pathValidator.validate(
                url: url,
                operation: .write,
                requireApprovalOutsideProject: requireApprovalOutsideProject
            )
            switch revalidation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: "Path denied after re-resolution: \(reason)")
            case let .requiresApproval(reason) where editApprovalReason == nil:
                throw ToolExecutionError.invalidPath(path: path, reason: "Path changed after approval (re-resolution requires new approval): \(reason)")
            case .requiresApproval, .allowed:
                break
            }

            try Task.checkCancellation()

            do {
                try newContent.write(to: url, atomically: true, encoding: .utf8)
                log(.info, "edit_file completed", metadata: ["path": path])
            } catch {
                throw ToolExecutionError.fileNotWritable(path: path, underlying: error.localizedDescription)
            }
        }

        func listDirectory(path: String, conversationId: UUID) async throws -> [FileEntry] {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "list_directory requested", metadata: ["path": path])
            let path = anchoredPath(path)

            guard let resolvedURL = pathValidator.canonicalize(path) else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path")
            }
            let riskReason: String?
            switch pathValidator.validate(url: resolvedURL, operation: .read) {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                riskReason = reason
            case .allowed:
                riskReason = nil
            }
            try await authorize(
                tool: ToolName.listDirectory,
                description: "List directory",
                details: resolvedURL.path,
                riskReason: riskReason,
                conversationId: conversationId
            )

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: resolvedURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                let entries: [FileEntry] = contents.compactMap { url in
                    let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])

                    return FileEntry(
                        name: url.lastPathComponent,
                        path: url.path,
                        isDirectory: resourceValues?.isDirectory ?? false,
                        size: resourceValues?.fileSize.map { Int64($0) },
                        modifiedDate: resourceValues?.contentModificationDate
                    )
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                log(.info, "list_directory completed", metadata: ["path": path, "count": "\(entries.count)"])
                return entries
            } catch {
                throw ToolExecutionError.fileNotReadable(path: path, underlying: error.localizedDescription)
            }
        }

        func searchFiles(pattern: String, path: String, conversationId: UUID) async throws -> [SearchResult] {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "search_files requested", metadata: ["pattern": pattern, "path": path])
            let path = anchoredPath(path)

            guard let resolvedURL = pathValidator.canonicalize(path) else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path")
            }
            let validation = pathValidator.validate(url: resolvedURL, operation: .read)
            let riskReason: String?
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                riskReason = reason
            case .allowed:
                riskReason = nil
            }
            try await authorize(
                tool: ToolName.searchFiles,
                description: "Search files",
                details: "Pattern: \(pattern) in \(resolvedURL.path)",
                riskReason: riskReason,
                conversationId: conversationId
            )

            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw ToolExecutionError.invalidPath(path: pattern, reason: "Invalid regex pattern: \(error.localizedDescription)")
            }

            var results: [SearchResult] = []
            results.reserveCapacity(maxSearchResults)

            let enumerator = FileManager.default.enumerator(
                at: resolvedURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard results.count < maxSearchResults else { break }

                let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resourceValues?.isRegularFile == true else { continue }

                if let size = resourceValues?.fileSize, size > maxReadSize {
                    continue
                }

                if validation.isAllowed, !pathValidator.validate(url: fileURL, operation: .read).isAllowed {
                    continue
                }

                guard let data = try? Data(contentsOf: fileURL),
                      !isBinaryData(data),
                      let content = String(data: data, encoding: .utf8)
                else { continue }

                let lines = content.components(separatedBy: .newlines)
                for (lineNumber, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if let match = regex.firstMatch(in: line, options: [], range: range) {
                        results.append(SearchResult(
                            path: fileURL.path,
                            lineNumber: lineNumber + 1,
                            content: line,
                            matchStart: match.range.location,
                            matchEnd: match.range.location + match.range.length
                        ))

                        if results.count >= maxSearchResults {
                            break
                        }
                    }
                }
            }

            log(.info, "search_files completed", metadata: ["pattern": pattern, "results": "\(results.count)"])
            return results
        }

        func runCommand(command: String, workingDirectory: String?, conversationId: UUID) async throws -> CommandResult {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "run_command requested", metadata: ["command": command])

            let validation = shellSandbox.validate(command)
            switch validation {
            case let .blocked(reason):
                throw ToolExecutionError.sandboxBlocked(command: command, reason: reason)
            case .requiresApproval, .allowed:
                break
            }

            let workingDirectory = workingDirectory.map(anchoredPath)
            if let workingDirectory {
                if !shellSandbox.isWorkingDirectoryAllowed(workingDirectory) {
                    throw ToolExecutionError.invalidPath(
                        path: workingDirectory,
                        reason: "Working directory outside allowed area"
                    )
                }
            }

            let workingDir = Self.canonicalDirectory(
                workingDirectory.map { URL(fileURLWithPath: PathValidator.expandPath($0)) } ?? baseDirectory
            )

            try await authorize(
                tool: ToolName.runCommand,
                description: "Execute shell command",
                details: Self.commandApprovalDetails(command, in: workingDir),
                riskReason: validation == .allowed ? nil : "Command is not on the allowed list",
                conversationId: conversationId
            )

            try Task.checkCancellation()

            if case let .blocked(reason) = shellSandbox.validate(command) {
                throw ToolExecutionError.sandboxBlocked(command: command, reason: reason)
            }

            let startTime = Date()
            let timeoutSeconds = commandTimeoutSeconds

            let result = try await executeProcess(
                command: command,
                workingDir: workingDir,
                timeoutSeconds: timeoutSeconds,
                startTime: startTime
            )

            log(.info, "run_command completed", metadata: [
                "command": command,
                "exitCode": "\(result.exitCode)",
                "duration": String(format: "%.2fs", result.duration)
            ])

            if result.timedOut {
                throw ToolExecutionError.commandTimeout(
                    command: command,
                    timeoutSeconds: timeoutSeconds,
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            }
            if result.exitCode != 0 {
                throw ToolExecutionError.commandFailed(
                    command: command,
                    exitCode: result.exitCode,
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            }

            return result
        }

        static func commandApprovalDetails(_ command: String, in directory: URL) -> String {
            "\(command)\n(in \(canonicalDirectory(directory).path))"
        }

        private static func canonicalDirectory(_ url: URL) -> URL {
            url.resolvingSymlinksInPath().standardized
        }

        private func executeProcess(
            command: String,
            workingDir: URL?,
            timeoutSeconds: Int,
            startTime: Date
        ) async throws -> CommandResult {
            let processHolder = ProcessExecutionController(
                processEscalationGate: processEscalationGate,
                subprocessSignal: subprocessSignal
            )
            let processStartGate = processStartGate
            let processCompletionGate = processCompletionGate

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    Task.detached {
                        await processStartGate()

                        do {
                            guard let process = try processHolder.start(
                                command: command,
                                workingDirectory: workingDir
                            ) else {
                                continuation.resume(throwing: CancellationError())
                                return
                            }

                            let timeoutTask = Task {
                                do {
                                    try await Task.sleep(for: .seconds(timeoutSeconds))
                                    processHolder.timeout()
                                } catch {}
                            }

                            let stdoutAccumulator = PipeAccumulator(maxSize: self.maxOutputSize)
                            let stderrAccumulator = PipeAccumulator(maxSize: self.maxOutputSize)

                            process.standardOutput.readabilityHandler = { handle in
                                let data = handle.availableData
                                if data.isEmpty {
                                    process.standardOutput.readabilityHandler = nil
                                } else {
                                    stdoutAccumulator.append(data)
                                }
                            }
                            process.standardError.readabilityHandler = { handle in
                                let data = handle.availableData
                                if data.isEmpty {
                                    process.standardError.readabilityHandler = nil
                                } else {
                                    stderrAccumulator.append(data)
                                }
                            }

                            let terminationStatus = process.waitUntilExit()
                            processHolder.didReap(process)
                            timeoutTask.cancel()

                            process.standardOutput.readabilityHandler = nil
                            process.standardError.readabilityHandler = nil
                            let remaining = process.drainAvailableOutput()
                            if !remaining.stdout.isEmpty {
                                stdoutAccumulator.append(remaining.stdout)
                            }
                            if !remaining.stderr.isEmpty {
                                stderrAccumulator.append(remaining.stderr)
                            }
                            process.closeOutput()

                            let duration = Date().timeIntervalSince(startTime)

                            var stdout = String(data: stdoutAccumulator.data, encoding: .utf8) ?? ""
                            var stderr = String(data: stderrAccumulator.data, encoding: .utf8) ?? ""
                            let truncationNote = "\n[Output truncated at \(self.maxOutputSize / 1024 / 1024)MB]"
                            if stdoutAccumulator.truncated {
                                stdout += truncationNote
                            }
                            if stderrAccumulator.truncated {
                                stderr += truncationNote
                            }

                            await processCompletionGate()
                            guard processHolder.commitCompletion() else {
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                            let commandResult = CommandResult(
                                exitCode: terminationStatus,
                                stdout: stdout,
                                stderr: stderr,
                                duration: duration,
                                timedOut: processHolder.didTimeOut
                            )

                            continuation.resume(returning: commandResult)
                        } catch {
                            if processHolder.commitCompletion() {
                                continuation.resume(throwing: ToolExecutionError.commandFailed(
                                    command: command,
                                    exitCode: -1,
                                    stdout: "",
                                    stderr: error.localizedDescription
                                ))
                            } else {
                                continuation.resume(throwing: CancellationError())
                            }
                        }
                    }
                }
            } onCancel: {
                processHolder.cancel()
            }
        }

        func executeToolCall(
            toolName: String,
            arguments: [String: Any],
            conversationId: UUID
        ) async -> String {
            do {
                switch toolName {
                case ToolName.readFile:
                    guard let path = arguments["path"] as? String else {
                        return "ERROR: Missing required parameter 'path'"
                    }
                    return try await readFile(path: path, conversationId: conversationId)

                case ToolName.writeFile:
                    guard let path = arguments["path"] as? String else {
                        return "ERROR: Missing required parameter 'path'"
                    }
                    guard let content = arguments["content"] as? String else {
                        return "ERROR: Missing required parameter 'content'"
                    }
                    try await writeFile(path: path, content: content, conversationId: conversationId)
                    return "File written successfully: \(path)"

                case ToolName.editFile:
                    guard let path = arguments["path"] as? String else {
                        return "ERROR: Missing required parameter 'path'"
                    }
                    guard let oldText = arguments["old_text"] as? String else {
                        return "ERROR: Missing required parameter 'old_text'"
                    }
                    guard let newText = arguments["new_text"] as? String else {
                        return "ERROR: Missing required parameter 'new_text'"
                    }
                    try await editFile(path: path, oldText: oldText, newText: newText, conversationId: conversationId)
                    return "File edited successfully: \(path)"

                case ToolName.listDirectory:
                    guard let path = arguments["path"] as? String else {
                        return "ERROR: Missing required parameter 'path'"
                    }
                    let entries = try await listDirectory(path: path, conversationId: conversationId)
                    return formatDirectoryListing(entries)

                case ToolName.searchFiles:
                    guard let pattern = arguments["pattern"] as? String else {
                        return "ERROR: Missing required parameter 'pattern'"
                    }
                    guard let path = arguments["path"] as? String else {
                        return "ERROR: Missing required parameter 'path'"
                    }
                    let results = try await searchFiles(pattern: pattern, path: path, conversationId: conversationId)
                    return formatSearchResults(results)

                case ToolName.gitContext:
                    return try await gitContext(path: arguments["path"] as? String, conversationId: conversationId)

                case ToolName.projectContext:
                    return try await projectContext(path: arguments["path"] as? String, conversationId: conversationId)

                case ToolName.updateTasks:
                    guard let tasks = arguments["tasks"] as? [[String: Any]] else {
                        return "ERROR: Missing required parameter 'tasks'"
                    }
                    return try await updateTasks(tasks, conversationId: conversationId)

                case ToolName.runCommand:
                    guard let command = arguments["command"] as? String else {
                        return "ERROR: Missing required parameter 'command'"
                    }
                    let workingDirectory = arguments["working_directory"] as? String
                    let result = try await runCommand(
                        command: command,
                        workingDirectory: workingDirectory,
                        conversationId: conversationId
                    )
                    return formatCommandResult(result)

                default:
                    return "ERROR: Unknown tool '\(toolName)'"
                }
            } catch let error as ToolExecutionError {
                return error.modelFacingDescription
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
    }

    extension BuiltinToolService {
        func isBinaryData(_ data: Data) -> Bool {
            let checkLength = min(data.count, 8192)
            return data.prefix(checkLength).contains(0)
        }

        func generateDiffPreview(oldText: String, newText: String) -> String {
            var diff = ""
            diff += "--- old\n"
            diff += "+++ new\n"

            let oldLines = oldText.components(separatedBy: .newlines)
            let newLines = newText.components(separatedBy: .newlines)

            for line in oldLines {
                diff += "- \(line)\n"
            }
            for line in newLines {
                diff += "+ \(line)\n"
            }

            return diff
        }

        func formatDirectoryListing(_ entries: [FileEntry]) -> String {
            var output = "Directory listing (\(entries.count) items):\n\n"

            for entry in entries {
                let typeIndicator = entry.isDirectory ? "📁" : "📄"
                let sizeStr = entry.size.map { formatFileSize($0) } ?? ""
                output += "\(typeIndicator) \(entry.name)"
                if !sizeStr.isEmpty {
                    output += " (\(sizeStr))"
                }
                output += "\n"
            }

            return output
        }

        func formatSearchResults(_ results: [SearchResult]) -> String {
            if results.isEmpty {
                return "No matches found."
            }

            var output = "Found \(results.count) matches:\n\n"

            for result in results {
                output += "\(result.path):\(result.lineNumber): \(result.content)\n"
            }

            return output
        }

        func formatCommandResult(_ result: CommandResult) -> String {
            var output = ""

            if !result.stdout.isEmpty {
                output += result.stdout
                if !output.hasSuffix("\n") {
                    output += "\n"
                }
            }

            if !result.stderr.isEmpty {
                output += "\nstderr:\n\(result.stderr)"
            }

            output += "\n[Exit code: \(result.exitCode), Duration: \(String(format: "%.2fs", result.duration))]"

            return output
        }

        func formatFileSize(_ bytes: Int64) -> String {
            fileSizeFormatter.string(fromByteCount: bytes)
        }

        func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
            DiagnosticsLogger.log(.aiService, level: level, message: "🔧 Tool: \(message)", metadata: metadata)
        }
    }
#endif
