import Foundation

struct ShellSandbox {
    let allowedCommands: Set<String>
    let blockedPatterns: [String]
    let projectRoot: URL?
    let allowUnlistedCommands: Bool
    let restrictToProjectDirectory: Bool

    private let blockedPatternRules: [BlockedPatternRule]

    private struct BlockedPatternRule {
        let pattern: String
        let lowercasedPattern: String
        let regex: NSRegularExpression?

        init(pattern: String) {
            self.pattern = pattern
            self.lowercasedPattern = pattern.lowercased()

            if pattern.contains(".*") || pattern.contains("[") {
                self.regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            } else {
                self.regex = nil
            }
        }
    }

    static let defaultAllowed: Set<String> = [
        "ls", "cat", "head", "tail", "less", "more", "file", "wc",
        "grep", "find", "rg", "fd", "ag",
        "git",
        "npm", "yarn", "pnpm", "swift", "swiftc", "xcodebuild",
        "echo", "pwd", "which", "whereis", "env", "printenv",
        "uname", "hostname", "date", "whoami",
        "ps", "top"
    ]

    static let defaultBlocked: [String] = [
        "sudo", "doas", "pkexec", "su ",

        "rm -rf /",
        "rm -rf ~",
        "rm -rf .",
        "rm -rf *",

        "chmod 777",
        "chmod -R 777",
        "chown root",

        "> /dev/",
        "dd if=",
        "mkfs",
        "fdisk",
        "parted",

        ":(){ :|:& };:",
        "fork()",

        "curl .* \\| *sh",
        "wget .* \\| *sh",
        "curl .* \\| *bash",
        "wget .* \\| *bash",
        "nc -e",
        "bash -i",

        "launchctl",
        "systemctl",
        "shutdown",
        "reboot",
        "halt",

        "brew install --cask",
        "pip install --user",
        "npm install -g"
    ]

    static let requiresApprovalCommands: Set<String> = [
        "python", "python3", "ruby", "node"
    ]

    static let alwaysBlockedCommands: Set<String> = [
        "eval",
        "source",
        "exec",
        "sudo",
        "doas",
        "pkexec",
        "su"
    ]

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
        self.blockedPatternRules = blockedPatterns.map(BlockedPatternRule.init)
    }

    enum ValidationResult: Equatable {
        case allowed
        case requiresApproval
        case blocked(reason: String)
    }

    func validate(_ command: String) -> ValidationResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .blocked(reason: "Empty command")
        }

        if trimmed.contains("\n") || trimmed.contains("\r") {
            return .blocked(reason: "Embedded newlines not allowed in commands")
        }

        if let substitutionReason = checkCommandSubstitution(trimmed) {
            return .blocked(reason: substitutionReason)
        }

        if let blockedReason = checkBlockedPatterns(trimmed) {
            return .blocked(reason: blockedReason)
        }

        let components = splitCommand(trimmed)

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

    func isWorkingDirectoryAllowed(_ path: String) -> Bool {
        guard restrictToProjectDirectory, let projectRoot else {
            return true
        }

        let pathComponents = Self.canonicalPathComponents(forPath: path)
        let rootComponents = Self.canonicalPathComponents(for: projectRoot)

        return Self.pathComponents(pathComponents, startWith: rootComponents)
    }

    func extractCommandName(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        let firstCommandWord = trimmed.split(whereSeparator: { $0.isWhitespace }).first { word in
            !(word.contains("=") && !word.hasPrefix("-"))
        }

        guard let firstCommandWord else { return nil }
        let firstWord = String(firstCommandWord)

        if firstWord.contains("/") {
            return URL(fileURLWithPath: firstWord).lastPathComponent
        }

        return firstWord
    }

    private func checkBlockedPatterns(_ command: String) -> String? {
        let lowercased = command.lowercased()

        for rule in blockedPatternRules {
            if lowercased.contains(rule.lowercasedPattern) {
                return "Blocked pattern: \(rule.pattern)"
            }

            if let regex = rule.regex {
                let range = NSRange(command.startIndex..., in: command)
                if regex.firstMatch(in: command, options: [], range: range) != nil {
                    return "Blocked pattern: \(rule.pattern)"
                }
            }
        }

        return nil
    }

    private func checkCommandSubstitution(_ command: String) -> String? {
        var inSingleQuote = false
        var inDoubleQuote = false
        var index = command.startIndex

        while index < command.endIndex {
            let char = command[index]

            if char == "\\", !inSingleQuote {
                index = command.index(index, offsetBy: 2, limitedBy: command.endIndex) ?? command.endIndex
                continue
            }

            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                index = command.index(after: index)
                continue
            }

            if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                index = command.index(after: index)
                continue
            }

            if !inSingleQuote {
                if char == "`" {
                    return "Command substitution (backticks) not allowed"
                }

                if char == "$", command.index(after: index) < command.endIndex {
                    let nextChar = command[command.index(after: index)]
                    if nextChar == "(" {
                        return "Command substitution $() not allowed"
                    }
                }

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
        var components: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        var index = command.startIndex

        while index < command.endIndex {
            let char = command[index]

            if isEscaped {
                current.append(char)
                isEscaped = false
                index = command.index(after: index)
                continue
            }

            if char == "\\", !inSingleQuote {
                isEscaped = true
                current.append(char)
                index = command.index(after: index)
                continue
            }

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

            if !inSingleQuote, !inDoubleQuote {
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

        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            components.append(current.trimmingCharacters(in: .whitespaces))
        }

        return components
    }

    private func validateComponent(_ component: String) -> ValidationResult {
        if let blockedReason = checkBlockedPatterns(component) {
            return .blocked(reason: blockedReason)
        }

        guard let commandName = extractCommandName(component) else {
            return .blocked(reason: "Cannot determine command")
        }

        if Self.alwaysBlockedCommands.contains(commandName.lowercased()) {
            return .blocked(reason: "Command always blocked: \(commandName)")
        }

        if allowedCommands.contains(commandName) {
            if hasDangerousFlags(component, command: commandName) {
                return .requiresApproval
            }
            return .allowed
        }

        if Self.requiresApprovalCommands.contains(commandName.lowercased()) {
            return .requiresApproval
        }

        if allowUnlistedCommands {
            return .requiresApproval
        } else {
            return .blocked(reason: "Command not in allowed list: \(commandName)")
        }
    }

    private static let readOnlySubcommands: [String: Set<String>] = [
        "git": [
            "status", "log", "diff", "show", "blame", "rev-parse", "ls-files", "ls-tree",
            "describe", "shortlog", "grep", "cat-file", "--version", "version", "help"
        ],
        "npm": ["ls", "list", "view", "info", "outdated", "--version", "-v", "help"],
        "yarn": ["list", "info", "why", "--version", "-v", "help"],
        "pnpm": ["ls", "list", "why", "--version", "-v", "help"],
        "swift": ["--version", "-version", "--help", "-help"],
        "swiftc": ["--version", "-version", "--help", "-help"],
        "xcodebuild": ["-version", "-showsdks", "-list", "-help", "-usage"]
    ]

    private func runsOtherCode(_ component: String, command: String) -> Bool {
        if Self.hasOutputRedirection(component) {
            return true
        }
        guard let tokens = Self.shellWords(component) else {
            return true
        }
        guard let commandIndex = tokens.firstIndex(where: { $0 == command || $0.hasSuffix("/\(command)") }) else {
            return true
        }
        let arguments = Array(tokens[(commandIndex + 1)...])

        switch command {
        case "env":
            return arguments.contains { !$0.hasPrefix("-") && !$0.contains("=") }
        case "find":
            let executing: Set = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprintf", "-fls"]
            return arguments.contains { executing.contains($0) }
        case "rg":
            return arguments.contains { $0 == "--pre" || $0.hasPrefix("--pre=") }
        case "fd":
            return arguments.contains { ["-x", "--exec", "-X", "--exec-batch"].contains($0) }
        case "git":
            if arguments.contains(where: { $0.hasPrefix("-c") || $0.hasPrefix("--config-env") || $0.hasPrefix("--exec-path") }) {
                return true
            }
            let subcommand = arguments.first { !$0.hasPrefix("-") }
            return subcommand.map { !(Self.readOnlySubcommands["git"]?.contains($0) ?? false) } ?? false
        case "npm", "yarn", "pnpm", "swift", "swiftc":
            guard let first = arguments.first else { return false }
            return !(Self.readOnlySubcommands[command]?.contains(first) ?? false)
        case "xcodebuild":
            guard let first = arguments.first else { return true }
            return !(Self.readOnlySubcommands[command]?.contains(first) ?? false)
        default:
            return false
        }
    }

    static func shellWords(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                inWord = true
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if inWord {
            words.append(current)
        }
        return words
    }

    static func hasOutputRedirection(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == ">" {
                return true
            }
        }
        return false
    }

    private func hasDangerousFlags(_ fullCommand: String, command: String) -> Bool {
        if runsOtherCode(fullCommand, command: command) {
            return true
        }
        let lowercased = fullCommand.lowercased()

        switch command {
        case "git":
            return lowercased.contains("--force") ||
                lowercased.contains("-f ") ||
                lowercased.hasSuffix("-f") ||
                lowercased.contains("reset --hard") ||
                lowercased.contains("clean -fd") ||
                lowercased.contains("checkout .") ||
                lowercased.contains("push")

        case "rm":
            return lowercased.contains("-r") ||
                lowercased.contains("-f") ||
                lowercased.contains("--recursive") ||
                lowercased.contains("--force")

        case "chmod", "chown":
            return true

        case "mv", "cp":
            return lowercased.contains("-f") || lowercased.contains("--force")

        case "python", "python3", "ruby", "node":
            return lowercased.contains(" -c ") || lowercased.hasSuffix(" -c") ||
                lowercased.contains(" -e ") || lowercased.hasSuffix(" -e")

        default:
            return false
        }
    }

    private static func canonicalPathComponents(forPath path: String) -> [String] {
        canonicalPathComponents(for: URL(fileURLWithPath: path))
    }

    private static func canonicalPathComponents(for url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardized.pathComponents
    }

    private static func pathComponents(_ pathComponents: [String], startWith directoryComponents: [String]) -> Bool {
        guard pathComponents.count >= directoryComponents.count else {
            return false
        }

        return pathComponents.starts(with: directoryComponents)
    }
}

extension ShellSandbox {
    static func withAdditionalAllowed(_ commands: Set<String>) -> ShellSandbox {
        ShellSandbox(allowedCommands: defaultAllowed.union(commands))
    }

    static func withAdditionalBlocked(_ patterns: [String]) -> ShellSandbox {
        ShellSandbox(blockedPatterns: defaultBlocked + patterns)
    }
}
