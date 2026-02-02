//
//  BuiltinToolService.swift
//  Ayna
//
//  Central service for all native agentic tool operations.
//  Provides file operations and shell execution with security validation.
//

import Foundation
import os.log

// MARK: - Tool Result Types

/// Result of a file operation
struct FileEntry: Codable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedDate: Date?
}

/// Result of a file search
struct SearchResult: Codable, Sendable {
    let path: String
    let lineNumber: Int
    let content: String
    let matchStart: Int
    let matchEnd: Int
}

/// Result of a command execution
struct CommandResult: Codable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
}

// MARK: - Tool Execution Error

/// Errors that can occur during tool execution.
///
/// Models need to distinguish error types to recover gracefully.
enum ToolExecutionError: Error, LocalizedError, Sendable {
    // Permission errors (user declined or policy blocked)
    case permissionDenied(tool: String, reason: String)
    case sandboxBlocked(command: String, reason: String)

    // Execution errors (tool ran but failed)
    case fileNotFound(path: String)
    case fileNotReadable(path: String, underlying: String)
    case fileNotWritable(path: String, underlying: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case commandTimeout(command: String, timeoutSeconds: Int)

    // Validation errors (bad input)
    case invalidPath(path: String, reason: String)
    case editAmbiguous(path: String, matchCount: Int)
    case editNotFound(path: String, searchText: String)
    case binaryFileUnsupported(path: String)
    case emptySearchText

    // System errors
    case resourceLimitExceeded(resource: String, limit: String)
    case serviceDisabled

    var errorDescription: String? {
        switch self {
        case let .permissionDenied(tool, reason):
            return "Permission denied for \(tool): \(reason)"
        case let .sandboxBlocked(command, reason):
            return "Command blocked: \(reason) - '\(command)'"
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case let .fileNotReadable(path, underlying):
            return "Cannot read file '\(path)': \(underlying)"
        case let .fileNotWritable(path, underlying):
            return "Cannot write file '\(path)': \(underlying)"
        case let .commandFailed(command, exitCode, stderr):
            let stderrPreview = stderr.isEmpty ? "" : " - \(String(stderr.prefix(200)))"
            return "Command '\(command)' failed with exit code \(exitCode)\(stderrPreview)"
        case let .commandTimeout(command, timeoutSeconds):
            return "Command '\(command)' timed out after \(timeoutSeconds) seconds"
        case let .invalidPath(path, reason):
            return "Invalid path '\(path)': \(reason)"
        case let .editAmbiguous(path, matchCount):
            return "Edit ambiguous: found \(matchCount) matches in '\(path)'. Provide more context to make the match unique."
        case let .editNotFound(path, searchText):
            let preview = String(searchText.prefix(50))
            return "Text not found in '\(path)': '\(preview)...'"
        case let .binaryFileUnsupported(path):
            return "Binary file not supported: \(path)"
        case .emptySearchText:
            return "Search text cannot be empty"
        case let .resourceLimitExceeded(resource, limit):
            return "Resource limit exceeded: \(resource) (limit: \(limit))"
        case .serviceDisabled:
            return "Agentic tools are disabled in settings"
        }
    }

    /// Structured error message for model consumption
    var modelFacingDescription: String {
        switch self {
        case let .permissionDenied(tool, reason):
            "ERROR: Permission denied for '\(tool)'. Reason: \(reason). The user declined this operation."
        case let .sandboxBlocked(command, reason):
            "ERROR: Command blocked by security policy. Command: '\(command)'. Reason: \(reason). This command is not allowed."
        case let .fileNotFound(path):
            "ERROR: File not found at path '\(path)'. Check if the path is correct."
        case let .fileNotReadable(path, underlying):
            "ERROR: Cannot read file '\(path)'. \(underlying)"
        case let .fileNotWritable(path, underlying):
            "ERROR: Cannot write to file '\(path)'. \(underlying)"
        case let .commandFailed(command, exitCode, stderr):
            "ERROR: Command '\(command)' failed with exit code \(exitCode). stderr: \(stderr)"
        case let .commandTimeout(command, timeoutSeconds):
            "ERROR: Command '\(command)' timed out after \(timeoutSeconds) seconds. Consider breaking it into smaller operations."
        case let .invalidPath(path, reason):
            "ERROR: Invalid path '\(path)'. \(reason)"
        case let .editAmbiguous(path, matchCount):
            "ERROR: The text to replace was found \(matchCount) times in '\(path)'. Include more surrounding context in 'old_text' to make it unique."
        case let .editNotFound(path, searchText):
            "ERROR: Could not find the specified text in '\(path)'. The text must match exactly, including whitespace. Search text: '\(searchText)'"
        case let .binaryFileUnsupported(path):
            "ERROR: '\(path)' appears to be a binary file. Only UTF-8 text files are supported."
        case .emptySearchText:
            "ERROR: The 'old_text' parameter cannot be empty. Use write_file to create new content."
        case let .resourceLimitExceeded(resource, limit):
            "ERROR: Resource limit exceeded for \(resource). Limit: \(limit)"
        case .serviceDisabled:
            "ERROR: Agentic tools are currently disabled. Ask the user to enable them in Settings > Tools."
        }
    }
}

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
//
// Uses dependency injection via SwiftUI Environment.
#if os(macOS)
    @Observable @MainActor
    final class BuiltinToolService {
        // MARK: - Properties

        private let permissionService: PermissionService
        private let shellSandbox: ShellSandbox
        private let pathValidator: PathValidator
        private let projectRoot: URL?

        /// Whether the service is enabled
        var isEnabled: Bool = true

        /// Timeout for shell commands in seconds
        var commandTimeoutSeconds: Int = 30

        /// Maximum file size to read (10 MB)
        private let maxReadSize: Int = 10 * 1024 * 1024

        /// Maximum search results
        private let maxSearchResults: Int = 100

        // MARK: - Tool Names

        private enum ToolName {
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

            // Resolve path
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)

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

            // Write updated content
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)

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
                        let matchRange = Range(match.range, in: line)!
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

            let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
                Task.detached {
                    let process = Process()
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

        // MARK: - Web Fetch

        /// Fetches content from a URL and returns it as text.
        ///
        /// - Parameters:
        ///   - url: The URL to fetch
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: The page content as plain text
        func webFetch(url: String, conversationId _: UUID) async throws -> String {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "web_fetch requested", metadata: ["url": url])

            // Validate URL
            guard let parsedURL = URL(string: url),
                  let host = parsedURL.host,
                  parsedURL.scheme == "https" || parsedURL.scheme == "http"
            else {
                throw ToolExecutionError.invalidPath(path: url, reason: "Invalid URL format")
            }

            // SSRF protection: Block internal/private IPs
            if isPrivateHost(host) {
                throw ToolExecutionError.invalidPath(path: url, reason: "Access to internal addresses is not allowed")
            }

            // Fetch with timeout
            var request = URLRequest(url: parsedURL)
            request.httpMethod = "GET"
            request.timeoutInterval = TimeInterval(commandTimeoutSeconds)
            request.setValue("Ayna/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ToolExecutionError.commandFailed(command: "web_fetch", exitCode: -1, stderr: "Invalid response")
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw ToolExecutionError.commandFailed(
                    command: "web_fetch",
                    exitCode: Int32(httpResponse.statusCode),
                    stderr: "HTTP \(httpResponse.statusCode)"
                )
            }

            // Check content size (10 MB limit)
            guard data.count <= maxReadSize else {
                throw ToolExecutionError.resourceLimitExceeded(
                    resource: "response size",
                    limit: "\(maxReadSize / 1024 / 1024) MB"
                )
            }

            guard let content = String(data: data, encoding: .utf8) else {
                throw ToolExecutionError.binaryFileUnsupported(path: url)
            }

            // Convert HTML to plain text if content appears to be HTML
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            let result = if contentType.contains("text/html") || content.contains("<html") {
                htmlToPlainText(content)
            } else {
                content
            }

            log(.info, "web_fetch completed", metadata: ["url": url, "size": "\(result.count)"])
            return result
        }

        /// Checks if a host is a private/internal address (SSRF protection)
        func isPrivateHost(_ host: String) -> Bool {
            let lowercased = host.lowercased()

            // Localhost variants
            if lowercased == "localhost" || lowercased == "127.0.0.1" || lowercased == "::1" {
                return true
            }

            // Block 0.0.0.0 (binds to all interfaces)
            if lowercased == "0.0.0.0" {
                return true
            }

            // IPv6 private/local ranges
            // fd00::/8 - Unique local addresses
            if lowercased.hasPrefix("fd") {
                return true
            }
            // fe80::/10 - Link-local addresses
            if lowercased.hasPrefix("fe80:") {
                return true
            }
            // fc00::/7 - Unique local addresses (includes fd00::/8)
            if lowercased.hasPrefix("fc") {
                return true
            }

            // Check for IP addresses in private ranges
            let parts = lowercased.split(separator: ".")
            if parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) {
                // 10.x.x.x
                if first == 10 { return true }
                // 172.16.x.x - 172.31.x.x
                if first == 172, (16 ... 31).contains(second) { return true }
                // 192.168.x.x
                if first == 192, second == 168 { return true }
                // 169.254.x.x (link-local, includes cloud metadata 169.254.169.254)
                if first == 169, second == 254 { return true }
                // 0.x.x.x - "This" network
                if first == 0 { return true }
            }

            return false
        }

        /// Converts HTML to plain text by stripping tags
        func htmlToPlainText(_ html: String) -> String {
            var text = html

            // Remove script and style content
            text = text.replacingOccurrences(
                of: "<script[^>]*>.*?</script>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            text = text.replacingOccurrences(
                of: "<style[^>]*>.*?</style>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )

            // Replace block elements with newlines
            text = text.replacingOccurrences(
                of: "<(br|p|div|h[1-6]|li|tr)[^>]*>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )

            // Remove all remaining tags
            text = text.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )

            // Decode HTML entities
            text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            text = text.replacingOccurrences(of: "&amp;", with: "&")
            text = text.replacingOccurrences(of: "&lt;", with: "<")
            text = text.replacingOccurrences(of: "&gt;", with: ">")
            text = text.replacingOccurrences(of: "&quot;", with: "\"")
            text = text.replacingOccurrences(of: "&#39;", with: "'")

            // Collapse multiple newlines
            text = text.replacingOccurrences(
                of: "\n{3,}",
                with: "\n\n",
                options: .regularExpression
            )

            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: - Tool Definitions

        /// Returns all tool definitions in OpenAI function format.
        func allToolDefinitions() -> [[String: Any]] {
            guard isEnabled else { return [] }

            return [
                readFileDefinition(),
                writeFileDefinition(),
                editFileDefinition(),
                listDirectoryDefinition(),
                searchFilesDefinition(),
                runCommandDefinition(),
                webFetchDefinition()
            ]
        }

        /// Returns context to inject into the system prompt describing agentic capabilities.
        func systemPromptContext() -> String? {
            guard isEnabled else { return nil }

            var context = """
            # Agentic Capabilities

            You have access to tools that allow you to interact with the user's filesystem and execute commands. \
            Use these tools proactively when the user asks about files, directories, or system information.

            Available tools:
            - **read_file**: Read the contents of a file
            - **write_file**: Create or overwrite a file
            - **edit_file**: Modify existing files by replacing specific text
            - **list_directory**: List files and subdirectories in a directory
            - **search_files**: Search for text patterns in files (like grep)
            - **run_command**: Execute shell commands
            - **web_fetch**: Fetch content from a URL as plain text

            When to use these tools:
            - When the user asks what's in a file or directory, use list_directory or read_file
            - When the user asks to find something, use search_files
            - When the user asks to create or modify files, use write_file or edit_file
            - When the user asks to run commands or scripts, use run_command
            - When the user asks to fetch a web page or API response, use web_fetch

            """

            if let root = projectRoot {
                context += "\nProject root: \(root.path)"
            }

            return context
        }

        /// Tool name constant for use in tool call routing
        static let toolNames: Set<String> = [
            "read_file", "write_file", "edit_file",
            "list_directory", "search_files", "run_command",
            "web_fetch"
        ]

        /// Checks if a tool name is a builtin tool
        static func isBuiltinTool(_ name: String) -> Bool {
            toolNames.contains(name)
        }

        private func readFileDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.readFile,
                    "description": "Read the contents of a file. Returns the file content as text. Only works with text files (UTF-8).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The absolute or relative path to the file to read"
                            ]
                        ] as [String: Any],
                        "required": ["path"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        private func writeFileDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.writeFile,
                    "description": "Create or overwrite a file with the specified content. Creates parent directories if needed.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The path where the file should be created or overwritten"
                            ],
                            "content": [
                                "type": "string",
                                "description": "The content to write to the file"
                            ]
                        ] as [String: Any],
                        "required": ["path", "content"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        private func editFileDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.editFile,
                    "description": "Edit a file by replacing specific text. The old_text must match EXACTLY (byte-for-byte, including whitespace and indentation). Include enough context to make the match unique.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The path to the file to edit"
                            ],
                            "old_text": [
                                "type": "string",
                                "description": "The exact text to find and replace. Must appear exactly once in the file."
                            ],
                            "new_text": [
                                "type": "string",
                                "description": "The text to replace old_text with. Can be empty to delete the matched text."
                            ]
                        ] as [String: Any],
                        "required": ["path", "old_text", "new_text"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        private func listDirectoryDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.listDirectory,
                    "description": "List files and directories in a given path. Returns name, path, type (file/directory), size, and modification date.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The directory path to list"
                            ]
                        ] as [String: Any],
                        "required": ["path"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        private func searchFilesDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.searchFiles,
                    "description": "Search for a pattern in files recursively. Supports regular expressions. Returns matching lines with file path and line number.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "pattern": [
                                "type": "string",
                                "description": "The search pattern (regular expression)"
                            ],
                            "path": [
                                "type": "string",
                                "description": "The directory to search in"
                            ]
                        ] as [String: Any],
                        "required": ["pattern", "path"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        private func runCommandDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.runCommand,
                    "description": "Execute a shell command. Safe commands (git, ls, cat, etc.) may run without approval. Dangerous commands require user approval.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "The shell command to execute"
                            ],
                            "working_directory": [
                                "type": "string",
                                "description": "Optional working directory for the command"
                            ]
                        ] as [String: Any],
                        "required": ["command"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        private func webFetchDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.webFetch,
                    "description": "Fetch content from a URL and return it as plain text. Use for reading web pages, documentation, or API responses. Only HTTP/HTTPS URLs are supported.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "url": [
                                "type": "string",
                                "description": "The URL to fetch (must be http:// or https://)"
                            ]
                        ] as [String: Any],
                        "required": ["url"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
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

    private extension BuiltinToolService {
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

// MARK: - String Extension for Range Finding

private extension String {
    func ranges(of searchString: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStartIndex = startIndex

        while searchStartIndex < endIndex,
              let range = range(of: searchString, range: searchStartIndex ..< endIndex)
        {
            ranges.append(range)
            searchStartIndex = range.upperBound
        }

        return ranges
    }
}
