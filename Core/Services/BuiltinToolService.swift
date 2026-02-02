//
//  BuiltinToolService.swift
//  Ayna
//
//  Central service for all native agentic tool operations.
//  Provides file operations and shell execution with security validation.
//

import Foundation
import os.log

// MARK: - Builtin Tool Service

// Central service for all native tool operations.
//
// Available tools:
// - `read_file`: Read file contents
// - `write_file`: Create/overwrite file
// - `edit_file`: Search/replace edit
// - `list_directory`: List files in directory
// - `search_files`: Grep-like search
// - `run_command`: Execute shell command
// - `web_fetch`: Fetch content from URL
//
// Uses dependency injection via SwiftUI Environment.
#if os(macOS)
    @Observable @MainActor
    final class BuiltinToolService {
        // MARK: - Properties

        private let permissionService: PermissionService
        private let shellSandbox: ShellSandbox
        private let pathValidator: PathValidator
        let projectRoot: URL?

        /// Whether the service is enabled
        var isEnabled: Bool = true

        /// Timeout for shell commands in seconds
        var commandTimeoutSeconds: Int = 30

        /// Maximum file size to read (10 MB)
        let maxReadSize: Int = 10 * 1024 * 1024

        /// Maximum search results
        private let maxSearchResults: Int = 100

        // MARK: - Tool Names

        enum ToolName {
            static let readFile = "read_file"
            static let writeFile = "write_file"
            static let editFile = "edit_file"
            static let listDirectory = "list_directory"
            static let searchFiles = "search_files"
            static let runCommand = "run_command"
            static let webFetch = "web_fetch"
        }

        // MARK: - Initialization

        init(
            permissionService: PermissionService,
            shellSandbox: ShellSandbox? = nil,
            projectRoot: URL? = nil
        ) {
            self.permissionService = permissionService
            self.projectRoot = projectRoot
            self.pathValidator = PathValidator(projectRoot: projectRoot)
            self.shellSandbox = shellSandbox ?? ShellSandbox(projectRoot: projectRoot)
        }

        // MARK: - File Operations

        /// Reads a file and returns its contents.
        ///
        /// - Parameters:
        ///   - path: The file path to read
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: The file contents as a string
        func readFile(path: String, conversationId: UUID) async throws -> String {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "read_file requested", metadata: ["path": path])

            // Validate path
            let validation = pathValidator.validate(path, operation: .read)
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                let approved = await permissionService.requestApproval(
                    toolName: ToolName.readFile,
                    description: "Read file: \(reason)",
                    details: path,
                    conversationId: conversationId
                )
                if !approved {
                    throw ToolExecutionError.permissionDenied(tool: ToolName.readFile, reason: "User denied")
                }
            case .allowed:
                break
            }

            // Read file
            guard let resolvedURL = pathValidator.canonicalize(path) else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path")
            }

            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                throw ToolExecutionError.fileNotFound(path: path)
            }

            // Check file size
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

            // Read contents
            do {
                let data = try Data(contentsOf: resolvedURL)

                // Check if binary
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

        /// Writes content to a file.
        ///
        /// - Parameters:
        ///   - path: The file path to write
        ///   - content: The content to write
        ///   - conversationId: The conversation requesting this operation
        func writeFile(path: String, content: String, conversationId: UUID) async throws {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "write_file requested", metadata: ["path": path])

            // Validate path
            let validation = pathValidator.validate(path, operation: .write)
            let requiresApprovalReason: String?
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                requiresApprovalReason = reason
            case .allowed:
                requiresApprovalReason = nil
            }

            // Write operations always require approval unless already approved
            let permissionLevel = permissionService.checkPermission(
                tool: ToolName.writeFile,
                details: path,
                defaultLevel: .askOnce
            )

            if permissionLevel != .automatic {
                let description = requiresApprovalReason.map { "Write file: \($0)" } ?? "Create/overwrite file"
                print("🔧 BuiltinToolService.writeFile: Requesting approval")
                print("   Path: \(path)")
                print("   ConversationId: \(conversationId)")
                let approved = await permissionService.requestApproval(
                    toolName: ToolName.writeFile,
                    description: description,
                    details: path,
                    conversationId: conversationId
                )
                if !approved {
                    throw ToolExecutionError.permissionDenied(tool: ToolName.writeFile, reason: "User denied")
                }
                permissionService.recordSessionApproval(tool: ToolName.writeFile, details: path)
            }

            // Resolve path with symlink resolution to prevent TOCTOU attacks
            // Re-resolve at operation time to ensure symlink hasn't changed since validation
            let expandedPath = (path as NSString).expandingTildeInPath
            let expandedURL = URL(fileURLWithPath: expandedPath)
            let url: URL
            do {
                // For new files, resolve the parent directory's symlinks
                if FileManager.default.fileExists(atPath: expandedURL.path) {
                    url = try expandedURL.resolvingSymlinksInPath()
                } else {
                    // File doesn't exist yet - resolve parent and append filename
                    let parent = try expandedURL.deletingLastPathComponent().resolvingSymlinksInPath()
                    url = parent.appendingPathComponent(expandedURL.lastPathComponent)
                }
            } catch {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path: \(error.localizedDescription)")
            }

            // Re-validate the resolved path to catch symlink changes
            let revalidation = pathValidator.validate(url.path, operation: .write)
            if case let .denied(reason) = revalidation {
                throw ToolExecutionError.invalidPath(path: path, reason: "Path changed during operation: \(reason)")
            }

            // Create parent directories if needed
            let parentDir = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                throw ToolExecutionError.fileNotWritable(path: path, underlying: "Cannot create directory: \(error.localizedDescription)")
            }

            // Write file
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                log(.info, "write_file completed", metadata: ["path": path, "size": "\(content.count)"])
            } catch {
                throw ToolExecutionError.fileNotWritable(path: path, underlying: error.localizedDescription)
            }
        }

        /// Performs a search-and-replace edit on a file.
        ///
        /// - Parameters:
        ///   - path: File path
        ///   - oldText: Text to find (must match EXACTLY, including whitespace)
        ///   - newText: Replacement text
        ///   - conversationId: The conversation requesting this operation
        func editFile(path: String, oldText: String, newText: String, conversationId: UUID) async throws {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "edit_file requested", metadata: ["path": path])

            // Validate inputs
            guard !oldText.isEmpty else {
                throw ToolExecutionError.emptySearchText
            }

            // No-op if oldText == newText
            if oldText == newText {
                log(.info, "edit_file no-op: oldText == newText", metadata: ["path": path])
                return
            }

            // Read current content
            let currentContent = try await readFile(path: path, conversationId: conversationId)

            // Find occurrences
            let occurrences = currentContent.ranges(of: oldText)

            if occurrences.isEmpty {
                throw ToolExecutionError.editNotFound(path: path, searchText: oldText)
            }

            if occurrences.count > 1 {
                throw ToolExecutionError.editAmbiguous(path: path, matchCount: occurrences.count)
            }

            // Create new content
            let newContent = currentContent.replacingOccurrences(of: oldText, with: newText)

            // Generate diff preview
            let diffPreview = generateDiffPreview(oldText: oldText, newText: newText)

            // Validate path for write
            let validation = pathValidator.validate(path, operation: .write)
            let editApprovalReason: String?
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                editApprovalReason = reason
            case .allowed:
                editApprovalReason = nil
            }

            let permissionLevel = permissionService.checkPermission(
                tool: ToolName.editFile,
                details: path,
                defaultLevel: .askOnce
            )

            if permissionLevel != .automatic {
                let description = editApprovalReason.map { "Edit file: \($0)" } ?? "Edit file"
                let approved = await permissionService.requestApproval(
                    toolName: ToolName.editFile,
                    description: description,
                    details: path,
                    diffPreview: diffPreview,
                    conversationId: conversationId
                )
                if !approved {
                    throw ToolExecutionError.permissionDenied(tool: ToolName.editFile, reason: "User denied")
                }
                permissionService.recordSessionApproval(tool: ToolName.editFile, details: path)
            }

            // Resolve path with symlink resolution to prevent TOCTOU attacks
            let expandedPath = (path as NSString).expandingTildeInPath
            let expandedURL = URL(fileURLWithPath: expandedPath)
            let url: URL
            do {
                url = try expandedURL.resolvingSymlinksInPath()
            } catch {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path: \(error.localizedDescription)")
            }

            // Re-validate the resolved path to catch symlink changes
            let revalidation = pathValidator.validate(url.path, operation: .write)
            if case let .denied(reason) = revalidation {
                throw ToolExecutionError.invalidPath(path: path, reason: "Path changed during operation: \(reason)")
            }

            // Write updated content
            do {
                try newContent.write(to: url, atomically: true, encoding: .utf8)
                log(.info, "edit_file completed", metadata: ["path": path])
            } catch {
                throw ToolExecutionError.fileNotWritable(path: path, underlying: error.localizedDescription)
            }
        }

        /// Lists files in a directory.
        ///
        /// - Parameters:
        ///   - path: The directory path
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: Array of file entries
        func listDirectory(path: String, conversationId: UUID) async throws -> [FileEntry] {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "list_directory requested", metadata: ["path": path])

            // Validate path
            let validation = pathValidator.validate(path, operation: .read)
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                let approved = await permissionService.requestApproval(
                    toolName: ToolName.listDirectory,
                    description: "List directory: \(reason)",
                    details: path,
                    conversationId: conversationId
                )
                if !approved {
                    throw ToolExecutionError.permissionDenied(tool: ToolName.listDirectory, reason: "User denied")
                }
            case .allowed:
                break
            }

            // Resolve path
            guard let resolvedURL = pathValidator.canonicalize(path) else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path")
            }

            // List contents
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

        /// Searches for a pattern in files.
        ///
        /// - Parameters:
        ///   - pattern: The search pattern (regex supported)
        ///   - path: The directory to search in
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: Array of search results
        func searchFiles(pattern: String, path: String, conversationId: UUID) async throws -> [SearchResult] {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "search_files requested", metadata: ["pattern": pattern, "path": path])

            // Validate path
            let validation = pathValidator.validate(path, operation: .read)
            switch validation {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                let approved = await permissionService.requestApproval(
                    toolName: ToolName.searchFiles,
                    description: "Search files: \(reason)",
                    details: "Pattern: \(pattern) in \(path)",
                    conversationId: conversationId
                )
                if !approved {
                    throw ToolExecutionError.permissionDenied(tool: ToolName.searchFiles, reason: "User denied")
                }
            case .allowed:
                break
            }

            // Resolve path
            guard let resolvedURL = pathValidator.canonicalize(path) else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path")
            }

            // Create regex
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw ToolExecutionError.invalidPath(path: pattern, reason: "Invalid regex pattern: \(error.localizedDescription)")
            }

            var results: [SearchResult] = []

            // Search recursively
            let enumerator = FileManager.default.enumerator(
                at: resolvedURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard results.count < maxSearchResults else { break }

                let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues?.isRegularFile == true else { continue }

                // Read file
                guard let data = try? Data(contentsOf: fileURL),
                      !isBinaryData(data),
                      let content = String(data: data, encoding: .utf8)
                else { continue }

                // Search for matches
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

                        if results.count >= maxSearchResults { break }
                    }
                }
            }

            log(.info, "search_files completed", metadata: ["pattern": pattern, "results": "\(results.count)"])
            return results
        }

        /// Executes a shell command.
        ///
        /// - Parameters:
        ///   - command: The command to execute
        ///   - workingDirectory: Optional working directory
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: Command execution result
        func runCommand(command: String, workingDirectory: String?, conversationId: UUID) async throws -> CommandResult {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "run_command requested", metadata: ["command": command])

            // Validate command with sandbox
            let validation = shellSandbox.validate(command)
            switch validation {
            case let .blocked(reason):
                throw ToolExecutionError.sandboxBlocked(command: command, reason: reason)
            case .requiresApproval, .allowed:
                break
            }

            // Validate working directory if provided
            if let workingDirectory {
                if !shellSandbox.isWorkingDirectoryAllowed(workingDirectory) {
                    throw ToolExecutionError.invalidPath(
                        path: workingDirectory,
                        reason: "Working directory outside allowed area"
                    )
                }
            }

            // Check permission
            let permissionLevel = permissionService.checkPermission(
                tool: ToolName.runCommand,
                details: command,
                defaultLevel: validation == .allowed ? .askOnce : .askAlways
            )

            if permissionLevel != .automatic {
                let approved = await permissionService.requestApproval(
                    toolName: ToolName.runCommand,
                    description: "Execute shell command",
                    details: command,
                    conversationId: conversationId
                )
                if !approved {
                    throw ToolExecutionError.permissionDenied(tool: ToolName.runCommand, reason: "User denied")
                }
                // Only remember allowed commands
                if validation == .allowed {
                    permissionService.recordSessionApproval(tool: ToolName.runCommand, details: command)
                }
            }

            // Execute command off the main thread to prevent UI freezes
            let startTime = Date()
            let timeoutSeconds = commandTimeoutSeconds
            let workingDir = workingDirectory.map { URL(fileURLWithPath: $0) } ?? projectRoot

            // Use a class to share process reference with cancellation handler
            final class ProcessHolder: @unchecked Sendable {
                var process: Process?
            }
            let processHolder = ProcessHolder()

            let result: CommandResult = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    Task.detached {
                        let process = Process()
                        processHolder.process = process

                        let stdoutPipe = Pipe()
                        let stderrPipe = Pipe()

                        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                        process.arguments = ["-c", command]
                        process.standardOutput = stdoutPipe
                        process.standardError = stderrPipe

                        if let workingDir {
                            process.currentDirectoryURL = workingDir
                        }

                        // Set up timeout task
                        let timeoutTask = Task {
                            do {
                                try await Task.sleep(for: .seconds(timeoutSeconds))
                                if process.isRunning {
                                    process.terminate()
                                }
                            } catch {
                                // Cancelled - expected when process completes normally
                            }
                        }

                        do {
                            try process.run()
                            process.waitUntilExit()
                            timeoutTask.cancel()

                            let duration = Date().timeIntervalSince(startTime)

                            let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
                            let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

                            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                            let commandResult = CommandResult(
                                exitCode: process.terminationStatus,
                                stdout: stdout,
                                stderr: stderr,
                                duration: duration
                            )

                            continuation.resume(returning: commandResult)
                        } catch {
                            continuation.resume(throwing: ToolExecutionError.commandFailed(
                                command: command,
                                exitCode: -1,
                                stderr: error.localizedDescription
                            ))
                        }
                    }
                }
            } onCancel: {
                // Terminate the process if the task is cancelled (e.g., user cancels stream)
                if let process = processHolder.process, process.isRunning {
                    process.terminate()
                }
            }

            log(.info, "run_command completed", metadata: [
                "command": command,
                "exitCode": "\(result.exitCode)",
                "duration": String(format: "%.2fs", result.duration)
            ])

            if result.exitCode != 0 {
                throw ToolExecutionError.commandFailed(
                    command: command,
                    exitCode: result.exitCode,
                    stderr: result.stderr
                )
            }

            return result
        }

        // MARK: - Tool Call Execution

        /// Executes a tool call and returns the result as a string.
        ///
        /// - Parameters:
        ///   - toolName: The name of the tool to execute
        ///   - arguments: The arguments dictionary
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: The result string to return to the model
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

                case ToolName.webFetch:
                    guard let url = arguments["url"] as? String else {
                        return "ERROR: Missing required parameter 'url'"
                    }
                    return try await webFetch(url: url, conversationId: conversationId)

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

    // MARK: - Private Helpers (Extension)

    extension BuiltinToolService {
        func isBinaryData(_ data: Data) -> Bool {
            // Check for null bytes in first 8KB (common binary indicator)
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
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }

        func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
            DiagnosticsLogger.log(.aiService, level: level, message: "🔧 Tool: \(message)", metadata: metadata)
        }
    }
#endif
