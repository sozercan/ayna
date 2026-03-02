//
//  BuiltinToolModels.swift
//  Ayna
//
//  Result types and errors for builtin tool operations.
//

import Foundation

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

// MARK: - String Extension for Range Finding

extension String {
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
