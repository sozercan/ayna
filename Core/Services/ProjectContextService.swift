//
//  ProjectContextService.swift
//  Ayna
//
//  Detects and manages project context for agentic operations.
//  Provides project-aware file paths and context injection.
//

import Foundation
import os.log

#if os(macOS)
    /// Detects project type and provides project-specific context
    @Observable @MainActor
    final class ProjectContextService {
        /// The detected project root
        private(set) var projectRoot: URL?

        /// The detected project type
        private(set) var projectType: ProjectType = .unknown

        /// Files to include in context (e.g., CLAUDE.md, AGENTS.md)
        private(set) var contextFiles: [URL] = []

        /// Cached context content
        private(set) var contextContent: String?

        // MARK: - Project Types

        enum ProjectType: String, Sendable {
            case swift
            case swiftPackage
            case xcode
            case node
            case python
            case rust
            case go
            case unknown

            var displayName: String {
                switch self {
                case .swift, .swiftPackage: "Swift"
                case .xcode: "Xcode"
                case .node: "Node.js"
                case .python: "Python"
                case .rust: "Rust"
                case .go: "Go"
                case .unknown: "Unknown"
                }
            }

            var contextFilenames: [String] {
                // Common AI assistant context files
                [
                    "CLAUDE.md",
                    "AGENTS.md",
                    ".claude",
                    "COPILOT.md",
                    "AI_CONTEXT.md",
                    "CURSOR.md"
                ]
            }

            var projectMarkers: [String] {
                switch self {
                case .swift:
                    ["Package.swift"]
                case .swiftPackage:
                    ["Package.swift", "Sources/"]
                case .xcode:
                    ["*.xcodeproj", "*.xcworkspace"]
                case .node:
                    ["package.json"]
                case .python:
                    ["pyproject.toml", "setup.py", "requirements.txt"]
                case .rust:
                    ["Cargo.toml"]
                case .go:
                    ["go.mod"]
                case .unknown:
                    []
                }
            }
        }

        // MARK: - Context Detection

        /// Detects project from a given path
        func detectProject(from path: URL) async {
            // Find project root by walking up from path
            projectRoot = await findProjectRoot(from: path)

            guard let root = projectRoot else {
                projectType = .unknown
                contextFiles = []
                contextContent = nil
                return
            }

            // Detect project type
            projectType = await detectProjectType(at: root)

            // Find context files
            contextFiles = await findContextFiles(in: root)

            // Load context content
            contextContent = await loadContextContent()

            log(.info, "Project detected", metadata: [
                "root": root.path,
                "type": projectType.rawValue,
                "contextFiles": "\(contextFiles.count)"
            ])
        }

        /// Returns the context to inject into system prompts
        func systemPromptContext() -> String? {
            guard let content = contextContent, !content.isEmpty else {
                return nil
            }

            return """
            # Project Context

            The following context files were found in the project:

            \(content)
            """
        }

        /// Returns a brief project summary for quick context
        func briefSummary() -> String? {
            guard let root = projectRoot else { return nil }

            var summary = "Project: \(root.lastPathComponent) (\(projectType.displayName))"

            if !contextFiles.isEmpty {
                summary += "\nContext: \(contextFiles.map(\.lastPathComponent).joined(separator: ", "))"
            }

            return summary
        }

        // MARK: - Private Methods

        private func findProjectRoot(from path: URL) async -> URL? {
            var current = path.standardized

            // If path is a file, start from its directory
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                current = current.deletingLastPathComponent()
            }

            // Walk up looking for project markers
            while current.path != "/" {
                // Check for .git directory (strong project indicator)
                let gitPath = current.appendingPathComponent(".git")
                if FileManager.default.fileExists(atPath: gitPath.path) {
                    return current
                }

                // Check for common project files
                let commonMarkers = [
                    "Package.swift",
                    "package.json",
                    "Cargo.toml",
                    "go.mod",
                    "pyproject.toml"
                ]

                for marker in commonMarkers {
                    let markerPath = current.appendingPathComponent(marker)
                    if FileManager.default.fileExists(atPath: markerPath.path) {
                        return current
                    }
                }

                // Check for xcodeproj/xcworkspace
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: nil
                ) {
                    if contents.contains(where: {
                        $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace"
                    }) {
                        return current
                    }
                }

                current = current.deletingLastPathComponent()
            }

            return nil
        }

        private func detectProjectType(at root: URL) async -> ProjectType {
            let fm = FileManager.default

            // Check in order of specificity
            if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                // Check if it has Sources/ for Swift Package
                if fm.fileExists(atPath: root.appendingPathComponent("Sources").path) {
                    return .swiftPackage
                }
                return .swift
            }

            if let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if contents.contains(where: {
                    $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace"
                }) {
                    return .xcode
                }
            }

            if fm.fileExists(atPath: root.appendingPathComponent("package.json").path) {
                return .node
            }

            if fm.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path) {
                return .rust
            }

            if fm.fileExists(atPath: root.appendingPathComponent("go.mod").path) {
                return .go
            }

            if fm.fileExists(atPath: root.appendingPathComponent("pyproject.toml").path) ||
                fm.fileExists(atPath: root.appendingPathComponent("setup.py").path) ||
                fm.fileExists(atPath: root.appendingPathComponent("requirements.txt").path)
            {
                return .python
            }

            return .unknown
        }

        private func findContextFiles(in root: URL) async -> [URL] {
            var found: [URL] = []
            let fm = FileManager.default

            // Check for common AI context files
            let contextFilenames = [
                "CLAUDE.md",
                "AGENTS.md",
                ".claude",
                "COPILOT.md",
                "AI_CONTEXT.md",
                "CURSOR.md",
                ".cursorrules"
            ]

            for filename in contextFilenames {
                let url = root.appendingPathComponent(filename)
                if fm.fileExists(atPath: url.path) {
                    found.append(url)
                }
            }

            // Also check docs/ directory
            let docsDir = root.appendingPathComponent("docs")
            if fm.fileExists(atPath: docsDir.path) {
                for filename in contextFilenames {
                    let url = docsDir.appendingPathComponent(filename)
                    if fm.fileExists(atPath: url.path) {
                        found.append(url)
                    }
                }
            }

            return found
        }

        private func loadContextContent() async -> String? {
            guard !contextFiles.isEmpty else { return nil }

            var content = ""

            for url in contextFiles {
                do {
                    let fileContent = try String(contentsOf: url, encoding: .utf8)
                    content += """

                    ## \(url.lastPathComponent)

                    \(fileContent)

                    """
                } catch {
                    log(.error, "Failed to load context file", metadata: [
                        "file": url.path,
                        "error": error.localizedDescription
                    ])
                }
            }

            return content.isEmpty ? nil : content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
            DiagnosticsLogger.log(.builtinTools, level: level, message: "📁 Project: \(message)", metadata: metadata)
        }
    }
#endif
