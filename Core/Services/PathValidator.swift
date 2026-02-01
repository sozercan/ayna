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
        "credentials.json",
        "secrets.yaml",
        "secrets.yml",
        ".git/config",
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
            if case .allowed = self { return true }
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
        let resolvedURL: URL
        do {
            resolvedURL = try url.resolvingSymlinksInPath()
        } catch {
            return .denied(reason: "Cannot resolve path: \(error.localizedDescription)")
        }

        // Step 3: Standardize the path (removes . and ..)
        let canonicalURL = resolvedURL.standardized
        let canonicalPath = canonicalURL.path

        // Step 4: Check for protected system paths
        if let protectedReason = checkProtectedPaths(canonicalPath) {
            return .requiresApproval(reason: protectedReason)
        }

        // Step 5: Check for sensitive filenames
        let filename = canonicalURL.lastPathComponent
        if sensitiveFilenames.contains(filename) {
            return .requiresApproval(reason: "Sensitive file: \(filename)")
        }

        // Also check if any path component matches sensitive filenames
        let pathComponents = canonicalURL.pathComponents
        for component in pathComponents where sensitiveFilenames.contains(component) {
            return .requiresApproval(reason: "Path contains sensitive component: \(component)")
        }

        // Step 6: For write/execute operations, check project boundary
        if operation == .write || operation == .execute {
            if requireApprovalOutsideProject, let projectRoot {
                let projectPath = projectRoot.standardized.path
                if !canonicalPath.hasPrefix(projectPath) {
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

        do {
            let resolved = try url.resolvingSymlinksInPath()
            return resolved.standardized
        } catch {
            return nil
        }
    }

    /// Checks if a path is within the project directory.
    ///
    /// - Parameter path: The path to check
    /// - Returns: true if path is within project root
    func isWithinProject(_ path: String) -> Bool {
        guard let projectRoot else { return false }
        guard let canonical = canonicalize(path) else { return false }

        let projectPath = projectRoot.standardized.path
        return canonical.path.hasPrefix(projectPath)
    }

    // MARK: - Private Helpers

    private func expandPath(_ path: String) -> String {
        var expanded = path

        // Expand ~
        if expanded.hasPrefix("~") {
            expanded = NSString(string: expanded).expandingTildeInPath
        }

        // Expand environment variables like $HOME
        expanded = expanded.replacingOccurrences(
            of: "\\$([A-Za-z_][A-Za-z0-9_]*)",
            with: "",
            options: .regularExpression
        )

        // Actually expand environment variables
        if expanded.contains("$") {
            let components = expanded.components(separatedBy: "/")
            let expandedComponents = components.map { component -> String in
                if component.hasPrefix("$") {
                    let varName = String(component.dropFirst())
                    return ProcessInfo.processInfo.environment[varName] ?? component
                }
                return component
            }
            expanded = expandedComponents.joined(separator: "/")
        }

        return expanded
    }

    private func checkProtectedPaths(_ canonicalPath: String) -> String? {
        for protectedPath in protectedPaths {
            let expandedProtected = expandPath(protectedPath)
            let protectedURL = URL(fileURLWithPath: expandedProtected).standardized
            let protectedCanonical = protectedURL.path

            if canonicalPath.hasPrefix(protectedCanonical) {
                return "Protected path: \(protectedPath)"
            }
        }
        return nil
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
