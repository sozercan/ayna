//
//  PathValidator.swift
//  Ayna
//
//  Path security validation for agentic file operations.
//  Prevents traversal attacks and protects sensitive system paths.
//

import Foundation

/// Validates file paths for security before allowing file operations.
///
/// Security features:
/// - Expands `~` and environment variables
/// - Resolves symlinks to prevent symlink-to-sensitive-file attacks
/// - Canonicalizes paths (removes `.` and `..`)
/// - Validates against protected paths
/// - Restricts writes to project directory when configured
struct PathValidator {
    let projectRoot: URL?
    let protectedPaths: [String]
    let sensitiveFilenames: Set<String>

    private static let environmentVariableRegex = try! NSRegularExpression(
        pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#,
        options: []
    )

    // MARK: - Default Protected Paths

    /// Paths that always require approval for any operation
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

    /// Filenames that always require approval regardless of directory
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

    // MARK: - Initialization

    init(
        projectRoot: URL? = nil,
        protectedPaths: [String] = PathValidator.defaultProtectedPaths,
        sensitiveFilenames: Set<String> = PathValidator.defaultSensitiveFilenames
    ) {
        self.projectRoot = projectRoot
        self.protectedPaths = protectedPaths
        self.sensitiveFilenames = sensitiveFilenames
    }

    // MARK: - Validation

    /// File operation types with different security levels
    enum FileOperation {
        case read // Less restrictive
        case write // Must be in project or explicitly approved
        case execute // Same as write
    }

    /// Result of path validation
    enum ValidationResult: Equatable {
        case allowed // Path is safe
        case requiresApproval(reason: String) // Needs user confirmation
        case denied(reason: String) // Always blocked

        var isAllowed: Bool {
            if case .allowed = self {
                return true
            }
            return false
        }
    }

    /// Validates a path for a given operation.
    ///
    /// - Parameters:
    ///   - path: The path string to validate
    ///   - operation: The type of file operation
    ///   - requireApprovalOutsideProject: Whether to require approval for paths outside project
    /// - Returns: Validated URL if allowed, or throws an error
    func validate(
        _ path: String,
        operation: FileOperation,
        requireApprovalOutsideProject: Bool = true
    ) -> ValidationResult {
        // Step 1: Expand path (~ and environment variables)
        let expandedPath = expandPath(path)

        // Step 2: Create URL and resolve symlinks
        let url = URL(fileURLWithPath: expandedPath)
        let resolvedURL = url.resolvingSymlinksInPath()

        // Step 3: Standardize the path (removes . and ..)
        let canonicalURL = resolvedURL.standardized
        let pathComponents = canonicalURL.pathComponents

        // Step 4: Check for protected system paths
        if let protectedReason = checkProtectedPaths(pathComponents) {
            return .requiresApproval(reason: protectedReason)
        }

        // Step 5: Check for sensitive filenames
        let filename = canonicalURL.lastPathComponent
        if sensitiveFilenames.contains(filename.lowercased()) {
            return .requiresApproval(reason: "Sensitive file: \(filename)")
        }

        // Also check if any path component matches sensitive filenames
        for component in pathComponents where sensitiveFilenames.contains(component.lowercased()) {
            return .requiresApproval(reason: "Path contains sensitive component: \(component)")
        }

        // Check for sensitive multi-component paths (e.g., .git/config)
        if pathComponents.count >= 2 {
            for idx in 0 ..< (pathComponents.count - 1) {
                if pathComponents[idx] == ".git", pathComponents[idx + 1] == "config" {
                    return .requiresApproval(reason: "Sensitive file: .git/config")
                }
            }
        }

        // Step 6: For write/execute operations, check project boundary
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

    /// Returns the canonical URL for a path, resolving symlinks.
    ///
    /// - Parameter path: The path string to canonicalize
    /// - Returns: Canonical URL or nil if path cannot be resolved
    func canonicalize(_ path: String) -> URL? {
        let expandedPath = expandPath(path)
        let url = URL(fileURLWithPath: expandedPath)
        return url.resolvingSymlinksInPath().standardized
    }

    /// Checks if a path is within the project directory.
    ///
    /// - Parameter path: The path to check
    /// - Returns: true if path is within project root
    func isWithinProject(_ path: String) -> Bool {
        guard let projectRoot else { return false }
        guard let canonical = canonicalize(path) else { return false }

        let rootComponents = Self.canonicalPathComponents(for: projectRoot)
        return Self.pathComponents(canonical.pathComponents, startWith: rootComponents)
    }

    // MARK: - Private Helpers

    private func expandPath(_ path: String) -> String {
        Self.expandPath(path)
    }

    private func checkProtectedPaths(_ pathComponents: [String]) -> String? {
        for protectedPath in protectedPaths {
            // Re-resolve protected boundaries on each validation. Protected directories
            // may be created, removed, or retargeted as symlinks after service startup;
            // using stale resolved components could bypass required approval.
            let expandedProtectedPath = Self.expandPath(protectedPath)
            let lexicalProtectedComponents = URL(fileURLWithPath: expandedProtectedPath).standardized.pathComponents
            let resolvedProtectedComponents = Self.canonicalPathComponents(forPath: expandedProtectedPath)
            if Self.pathComponents(pathComponents, startWith: lexicalProtectedComponents)
                || Self.pathComponents(pathComponents, startWith: resolvedProtectedComponents)
            {
                return "Protected path: \(protectedPath)"
            }
        }
        return nil
    }

    private static func expandPath(_ path: String) -> String {
        var expanded = path

        // Expand ~
        if expanded.hasPrefix("~") {
            expanded = NSString(string: expanded).expandingTildeInPath
        }

        // Expand environment variables like $HOME, $USER, etc.
        // Uses a shared regex and replaces matches from the end to preserve indices.
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

    private static func pathComponents(_ pathComponents: [String], startWith directoryComponents: [String]) -> Bool {
        // Path must have at least as many components as directory
        guard pathComponents.count >= directoryComponents.count else {
            return false
        }

        // Check that all directory components match the start of path components
        return pathComponents.starts(with: directoryComponents)
    }
}

// MARK: - Path Validation Error

extension PathValidator {
    /// Errors that can occur during path validation
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
