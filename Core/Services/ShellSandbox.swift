//
//  ShellSandbox.swift
//  Ayna
//
//  Shell command validation and sandboxing for agentic execution.
//  Defense-in-depth protection against dangerous commands.
//

import Foundation

/// Validates and restricts shell command execution.
///
/// Security Model:
/// - The blocklist is a *defense-in-depth* measure, not the primary security boundary
/// - The actual security comes from user approval for any dangerous operation
/// - The blocklist helps models avoid obviously dangerous commands without user intervention
/// - Sophisticated bypass attempts are stopped at the approval layer
struct ShellSandbox {
    let allowedCommands: Set<String>
    let blockedPatterns: [String]
    let projectRoot: URL?
    let allowUnlistedCommands: Bool
    let restrictToProjectDirectory: Bool

    // MARK: - Default Configuration

    /// Commands that execute without approval (read-only, safe operations)
    static let defaultAllowed: Set<String> = [
        // File inspection
        "ls", "cat", "head", "tail", "less", "more", "file", "wc",
        // Search
        "grep", "find", "rg", "fd", "ag",
        // Git (read-only)
        "git",
        // Development tools (read-only)
        "npm", "yarn", "pnpm", "swift", "swiftc", "xcodebuild",
        "python", "python3", "ruby", "node",
        // System info
        "echo", "pwd", "which", "whereis", "env", "printenv",
        "uname", "hostname", "date", "whoami",
        // Process inspection
        "ps", "top"
    ]

    /// Patterns that are always blocked (denied even with approval attempt)
    static let defaultBlocked: [String] = [
        // Privilege escalation
        "sudo", "doas", "pkexec", "su ",

        // Destructive filesystem operations
        "rm -rf /",
        "rm -rf ~",
        "rm -rf .",
        "rm -rf *",

        // Unsafe permissions
        "chmod 777",
        "chmod -R 777",
        "chown root",

        // Device/filesystem danger
        "> /dev/",
        "dd if=",
        "mkfs",
        "fdisk",
        "parted",

        // Fork bombs and resource exhaustion
        ":(){ :|:& };:",
        "fork()",

        // Network exfiltration patterns
        "curl .* \\| *sh",
        "wget .* \\| *sh",
        "curl .* \\| *bash",
        "wget .* \\| *bash",
        "nc -e",
        "bash -i",

        // System modification
        "launchctl",
        "systemctl",
        "shutdown",
        "reboot",
        "halt",

        // Package managers with dangerous flags
        "brew install --cask",
        "pip install --user",
        "npm install -g",

        // Shell execution of arbitrary code
        "eval ",
        "source ",
        "exec "
    ]

    // MARK: - Initialization

    init(
        allowedCommands: Set<String> = ShellSandbox.defaultAllowed,
        blockedPatterns: [String] = ShellSandbox.defaultBlocked,
        projectRoot: URL? = nil,
        allowUnlistedCommands: Bool = true,
        restrictToProjectDirectory: Bool = true
    ) {
        self.allowedCommands = allowedCommands
        self.blockedPatterns = blockedPatterns
        self.projectRoot = projectRoot
        self.allowUnlistedCommands = allowUnlistedCommands
        self.restrictToProjectDirectory = restrictToProjectDirectory
    }

    // MARK: - Validation

    /// Result of command validation
    enum ValidationResult: Equatable {
        case allowed // In allowlist, can execute
        case requiresApproval // Not in allowlist, needs user approval
        case blocked(reason: String) // In blocklist, always denied
    }

    /// Validates a shell command for execution.
    ///
    /// Splits the command on `;`, `&&`, `||`, and `|` to validate each component.
    /// All components must pass validation for the command to be allowed.
    ///
    /// - Parameter command: The shell command to validate
    /// - Returns: Validation result indicating if execution is allowed
    func validate(_ command: String) -> ValidationResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .blocked(reason: "Empty command")
        }

        // Block command substitution syntax (security critical)
        // These are interpreted by shells and can execute arbitrary commands
        if let substitutionReason = checkCommandSubstitution(trimmed) {
            return .blocked(reason: substitutionReason)
        }

        // Check for blocked patterns first (entire command string)
        if let blockedReason = checkBlockedPatterns(trimmed) {
            return .blocked(reason: blockedReason)
        }

        // Split command into components
        let components = splitCommand(trimmed)

        // Validate each component
        var anyRequiresApproval = false

        for component in components {
            let componentResult = validateComponent(component)

            switch componentResult {
            case let .blocked(reason):
                return .blocked(reason: reason)
            case .requiresApproval:
                anyRequiresApproval = true
            case .allowed:
                continue
            }
        }

        return anyRequiresApproval ? .requiresApproval : .allowed
    }

    /// Validates a working directory for command execution.
    ///
    /// - Parameter path: The working directory path
    /// - Returns: true if the path is allowed for command execution
    func isWorkingDirectoryAllowed(_ path: String) -> Bool {
        guard restrictToProjectDirectory, let projectRoot else {
            return true
        }

        let pathComponents = URL(fileURLWithPath: path).standardized.pathComponents
        let projectComponents = projectRoot.standardized.pathComponents

        // Path must have at least as many components as project root
        guard pathComponents.count >= projectComponents.count else {
            return false
        }

        // Check that all project components match the start of path components
        return pathComponents.starts(with: projectComponents)
    }

    /// Extracts the base command name from a command string.
    ///
    /// - Parameter command: The full command string
    /// - Returns: The base command name (first word)
    func extractCommandName(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle commands that start with environment variable assignments
        var words = trimmed.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Skip environment variable assignments (KEY=value)
        while let first = words.first, first.contains("="), !first.hasPrefix("-") {
            words.removeFirst()
        }

        guard let firstWord = words.first else { return nil }

        // Handle path-qualified commands like /usr/bin/git
        if firstWord.contains("/") {
            return URL(fileURLWithPath: firstWord).lastPathComponent
        }

        return firstWord
    }

    // MARK: - Private Helpers

    private func checkBlockedPatterns(_ command: String) -> String? {
        let lowercased = command.lowercased()

        for pattern in blockedPatterns {
            // Check exact match or contains
            if lowercased.contains(pattern.lowercased()) {
                return "Blocked pattern: \(pattern)"
            }

            // Check regex patterns
            if pattern.contains(".*") || pattern.contains("[") {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(command.startIndex..., in: command)
                    if regex.firstMatch(in: command, options: [], range: range) != nil {
                        return "Blocked pattern: \(pattern)"
                    }
                }
            }
        }

        return nil
    }

    /// Checks for command substitution and process substitution syntax that could execute arbitrary commands.
    ///
    /// Since commands are executed via `/bin/zsh -c`, backticks, $(), <(), and >() are interpreted
    /// by the shell and can execute arbitrary nested commands, bypassing validation.
    ///
    /// - Parameter command: The command string to check
    /// - Returns: A reason string if dangerous substitution is detected, nil otherwise
    private func checkCommandSubstitution(_ command: String) -> String? {
        // Track quote state to avoid false positives in single-quoted strings
        // (single quotes prevent substitution in shells)
        var inSingleQuote = false
        var index = command.startIndex

        while index < command.endIndex {
            let char = command[index]

            // Toggle single quote state
            if char == "'" {
                inSingleQuote.toggle()
                index = command.index(after: index)
                continue
            }

            // Only check for substitution outside single quotes
            if !inSingleQuote {
                // Check for backtick command substitution
                if char == "`" {
                    return "Command substitution (backticks) not allowed"
                }

                // Check for $() command substitution
                if char == "$", command.index(after: index) < command.endIndex {
                    let nextChar = command[command.index(after: index)]
                    if nextChar == "(" {
                        return "Command substitution $() not allowed"
                    }
                }

                // Check for process substitution <() and >()
                if char == "<" || char == ">", command.index(after: index) < command.endIndex {
                    let nextChar = command[command.index(after: index)]
                    if nextChar == "(" {
                        return "Process substitution \(char)() not allowed"
                    }
                }
            }

            index = command.index(after: index)
        }

        return nil
    }

    private func splitCommand(_ command: String) -> [String] {
        // Split on command separators: ; && || |
        // Properly handles escape sequences within quoted strings

        var components: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        var index = command.startIndex

        while index < command.endIndex {
            let char = command[index]

            // Handle escape sequences (backslash)
            if isEscaped {
                current.append(char)
                isEscaped = false
                index = command.index(after: index)
                continue
            }

            // Check for backslash escape (only meaningful in double quotes or unquoted)
            if char == "\\", !inSingleQuote {
                isEscaped = true
                current.append(char)
                index = command.index(after: index)
                continue
            }

            // Track quote state
            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(char)
                index = command.index(after: index)
                continue
            }
            if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(char)
                index = command.index(after: index)
                continue
            }

            // Only split if not in quotes
            if !inSingleQuote, !inDoubleQuote {
                // Check for && or ||
                if index < command.index(before: command.endIndex) {
                    let nextChar = command[command.index(after: index)]
                    if (char == "&" && nextChar == "&") || (char == "|" && nextChar == "|") {
                        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                            components.append(current.trimmingCharacters(in: .whitespaces))
                        }
                        current = ""
                        index = command.index(index, offsetBy: 2)
                        continue
                    }
                }

                // Check for ; or |
                if char == ";" || char == "|" {
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        components.append(current.trimmingCharacters(in: .whitespaces))
                    }
                    current = ""
                    index = command.index(after: index)
                    continue
                }
            }

            current.append(char)
            index = command.index(after: index)
        }

        // Add remaining content
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            components.append(current.trimmingCharacters(in: .whitespaces))
        }

        return components
    }

    private func validateComponent(_ component: String) -> ValidationResult {
        // Check blocked patterns for this component
        if let blockedReason = checkBlockedPatterns(component) {
            return .blocked(reason: blockedReason)
        }

        // Extract command name
        guard let commandName = extractCommandName(component) else {
            return .blocked(reason: "Cannot determine command")
        }

        // Check if in allowed list
        if allowedCommands.contains(commandName) {
            // Even allowed commands need approval if they have dangerous flags
            if hasDangerousFlags(component, command: commandName) {
                return .requiresApproval
            }
            return .allowed
        }

        // Not in allowed list
        if allowUnlistedCommands {
            return .requiresApproval
        } else {
            return .blocked(reason: "Command not in allowed list: \(commandName)")
        }
    }

    private func hasDangerousFlags(_ fullCommand: String, command: String) -> Bool {
        let lowercased = fullCommand.lowercased()

        // Dangerous flags for specific commands
        switch command {
        case "git":
            // git push --force, git reset --hard, etc.
            return lowercased.contains("--force") ||
                lowercased.contains("-f ") ||
                lowercased.contains("reset --hard") ||
                lowercased.contains("clean -fd") ||
                lowercased.contains("checkout .") ||
                lowercased.contains("push") // Pushes require approval

        case "rm":
            // Any recursive or force flags
            return lowercased.contains("-r") ||
                lowercased.contains("-f") ||
                lowercased.contains("--recursive") ||
                lowercased.contains("--force")

        case "chmod", "chown":
            // Any permission changes require approval
            return true

        case "mv", "cp":
            // Moving/copying over existing files
            return lowercased.contains("-f") || lowercased.contains("--force")

        default:
            return false
        }
    }
}

// MARK: - Convenience Extensions

extension ShellSandbox {
    /// Creates a sandbox with custom allowed commands added to defaults.
    static func withAdditionalAllowed(_ commands: Set<String>) -> ShellSandbox {
        ShellSandbox(allowedCommands: defaultAllowed.union(commands))
    }

    /// Creates a sandbox with custom blocked patterns added to defaults.
    static func withAdditionalBlocked(_ patterns: [String]) -> ShellSandbox {
        ShellSandbox(blockedPatterns: defaultBlocked + patterns)
    }
}
