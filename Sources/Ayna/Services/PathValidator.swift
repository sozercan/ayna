import Foundation

struct PathValidator {
    let projectRoot: URL?
    let protectedPaths: [String]
    let sensitiveFilenames: Set<String>

    private static let environmentVariableRegex: NSRegularExpression = {
        let pattern = #"\$([A-Za-z_][A-Za-z0-9_]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid static environment-variable regular expression: \(pattern)")
        }
        return expression
    }()

    static let defaultProtectedPaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.gpg",
        "~/.config",
        "~/.kube",
        "~/.docker",
        "~/Library/Keychains",
        "/etc",
        "/var",
        "/System",
        "/Library"
    ]

    static let defaultSensitiveFilenames: Set<String> = [
        ".env",
        ".env.local",
        ".env.production",
        ".env.development",
        ".git",
        "credentials.json",
        "secrets.yaml",
        "secrets.yml",
        ".gitconfig",
        "id_rsa",
        "id_ed25519",
        "id_ecdsa",
        ".npmrc",
        ".pypirc"
    ]

    init(
        projectRoot: URL? = nil,
        protectedPaths: [String] = PathValidator.defaultProtectedPaths,
        sensitiveFilenames: Set<String> = PathValidator.defaultSensitiveFilenames
    ) {
        self.projectRoot = projectRoot
        self.protectedPaths = protectedPaths
        self.sensitiveFilenames = sensitiveFilenames
    }

    enum FileOperation {
        case read
        case write
        case execute
    }

    enum ValidationResult: Equatable {
        case allowed
        case requiresApproval(reason: String)
        case denied(reason: String)

        var isAllowed: Bool {
            if case .allowed = self {
                return true
            }
            return false
        }
    }

    func validate(
        _ path: String,
        operation: FileOperation,
        requireApprovalOutsideProject: Bool = true
    ) -> ValidationResult {
        validate(
            url: URL(fileURLWithPath: expandPath(path)),
            operation: operation,
            requireApprovalOutsideProject: requireApprovalOutsideProject
        )
    }

    func validate(
        url: URL,
        operation: FileOperation,
        requireApprovalOutsideProject: Bool = true
    ) -> ValidationResult {
        let resolvedURL = url.resolvingSymlinksInPath()

        let canonicalURL = resolvedURL.standardized
        let pathComponents = canonicalURL.pathComponents

        if let protectedReason = checkProtectedPaths(pathComponents) {
            return .requiresApproval(reason: protectedReason)
        }

        let filename = canonicalURL.lastPathComponent
        if sensitiveFilenames.contains(filename.lowercased()) {
            return .requiresApproval(reason: "Sensitive file: \(filename)")
        }

        for component in pathComponents where sensitiveFilenames.contains(component.lowercased()) {
            return .requiresApproval(reason: "Path contains sensitive component: \(component)")
        }

        if pathComponents.count >= 2 {
            for idx in 0 ..< (pathComponents.count - 1) {
                if pathComponents[idx].lowercased() == ".git", pathComponents[idx + 1].lowercased() == "config" {
                    return .requiresApproval(reason: "Sensitive file: .git/config")
                }
            }
        }

        if operation == .write || operation == .execute {
            if requireApprovalOutsideProject, let projectRoot {
                let rootComponents = Self.canonicalPathComponents(for: projectRoot)
                if !Self.pathComponents(pathComponents, startWith: rootComponents) {
                    return .requiresApproval(reason: "Path outside project directory")
                }
            }
        }

        return .allowed
    }

    func canonicalize(_ path: String) -> URL? {
        let expandedPath = expandPath(path)
        let url = URL(fileURLWithPath: expandedPath)
        return url.resolvingSymlinksInPath().standardized
    }

    func isWithinProject(_ path: String) -> Bool {
        guard let projectRoot else { return false }
        guard let canonical = canonicalize(path) else { return false }

        let rootComponents = Self.canonicalPathComponents(for: projectRoot)
        return Self.pathComponents(canonical.pathComponents, startWith: rootComponents)
    }

    private func expandPath(_ path: String) -> String {
        Self.expandPath(path)
    }

    private func checkProtectedPaths(_ pathComponents: [String]) -> String? {
        for protectedPath in protectedPaths {
            let expandedProtectedPath = Self.expandPath(protectedPath)
            let lexicalProtectedComponents = URL(fileURLWithPath: expandedProtectedPath).standardized.pathComponents
            let resolvedProtectedComponents = Self.canonicalPathComponents(forPath: expandedProtectedPath)
            if Self.pathComponents(pathComponents, startWith: lexicalProtectedComponents, caseInsensitive: true)
                || Self.pathComponents(pathComponents, startWith: resolvedProtectedComponents, caseInsensitive: true)
            {
                return "Protected path: \(protectedPath)"
            }
        }
        return nil
    }

    static func expandPath(_ path: String) -> String {
        var expanded = path

        if expanded.hasPrefix("~") {
            expanded = NSString(string: expanded).expandingTildeInPath
        }

        let range = NSRange(expanded.startIndex..., in: expanded)
        let matches = environmentVariableRegex.matches(in: expanded, options: [], range: range)

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: expanded),
                  let varNameRange = Range(match.range(at: 1), in: expanded)
            else {
                continue
            }

            let varName = String(expanded[varNameRange])
            let replacement = ProcessInfo.processInfo.environment[varName] ?? ""
            expanded.replaceSubrange(fullRange, with: replacement)
        }

        return expanded
    }

    private static func canonicalPathComponents(forPath path: String) -> [String] {
        canonicalPathComponents(for: URL(fileURLWithPath: path))
    }

    private static func canonicalPathComponents(for url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardized.pathComponents
    }

    private static func pathComponents(
        _ pathComponents: [String],
        startWith directoryComponents: [String],
        caseInsensitive: Bool = false
    ) -> Bool {
        guard pathComponents.count >= directoryComponents.count else {
            return false
        }

        if caseInsensitive {
            return pathComponents.starts(with: directoryComponents) {
                $0.caseInsensitiveCompare($1) == .orderedSame
            }
        }
        return pathComponents.starts(with: directoryComponents)
    }
}

extension PathValidator {
    enum ValidationError: LocalizedError {
        case pathNotAllowed(path: String, reason: String)
        case pathResolutionFailed(path: String, underlying: Error)
        case invalidPath(path: String)

        var errorDescription: String? {
            switch self {
            case let .pathNotAllowed(path, reason):
                "Path not allowed '\(path)': \(reason)"
            case let .pathResolutionFailed(path, underlying):
                "Cannot resolve path '\(path)': \(underlying.localizedDescription)"
            case let .invalidPath(path):
                "Invalid path: \(path)"
            }
        }
    }
}
