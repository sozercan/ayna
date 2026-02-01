//
//  GitContextService.swift
//  Ayna
//
//  Provides git repository context for agentic operations.
//  Injects branch, status, and recent commit info into system prompts.
//

import Foundation
import os.log

#if os(macOS)
    /// Service for providing git repository context
    @Observable @MainActor
    final class GitContextService {
        /// Current git status
        private(set) var status: GitStatus?

        /// Current branch name
        private(set) var currentBranch: String?

        /// Recent commits
        private(set) var recentCommits: [GitCommit] = []

        /// Main/default branch name
        private(set) var mainBranch: String?

        /// Whether the repository is clean
        var isClean: Bool {
            status?.isClean ?? true
        }

        /// Repository root path
        private var repoRoot: URL?

        // MARK: - Types

        struct GitStatus: Sendable {
            let staged: [String]
            let unstaged: [String]
            let untracked: [String]

            var isClean: Bool {
                staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
            }

            var summary: String {
                var parts: [String] = []
                if !staged.isEmpty { parts.append("\(staged.count) staged") }
                if !unstaged.isEmpty { parts.append("\(unstaged.count) modified") }
                if !untracked.isEmpty { parts.append("\(untracked.count) untracked") }
                return parts.isEmpty ? "clean" : parts.joined(separator: ", ")
            }
        }

        struct GitCommit: Identifiable, Sendable {
            let id: String // SHA
            let shortSha: String
            let message: String
            let author: String
            let date: Date

            var summary: String {
                "\(shortSha) \(message)"
            }
        }

        /// Result of a git command execution
        struct GitCommandResult {
            let exitCode: Int32
            let stdout: String
            let stderr: String
        }

        // MARK: - Context Loading

        /// Loads git context from a directory
        func loadContext(from directory: URL) async {
            // Find git root
            repoRoot = await findGitRoot(from: directory)

            guard let root = repoRoot else {
                reset()
                return
            }

            // Load all git info in parallel
            async let branchTask = loadCurrentBranch(in: root)
            async let statusTask = loadStatus(in: root)
            async let commitsTask = loadRecentCommits(in: root, limit: 5)
            async let mainBranchTask = detectMainBranch(in: root)

            currentBranch = await branchTask
            status = await statusTask
            recentCommits = await commitsTask
            mainBranch = await mainBranchTask

            log(.info, "Git context loaded", metadata: [
                "branch": currentBranch ?? "unknown",
                "status": status?.summary ?? "unknown",
                "commits": "\(recentCommits.count)"
            ])
        }

        /// Resets all git context
        func reset() {
            repoRoot = nil
            currentBranch = nil
            status = nil
            recentCommits = []
            mainBranch = nil
        }

        /// Returns context to inject into system prompts
        func systemPromptContext() -> String? {
            guard let branch = currentBranch else { return nil }

            var context = """
            # Git Context

            Current branch: \(branch)
            """

            if let main = mainBranch, main != branch {
                context += "\nMain branch: \(main)"
            }

            if let status {
                context += "\nStatus: \(status.summary)"
            }

            if !recentCommits.isEmpty {
                context += "\n\nRecent commits:"
                for commit in recentCommits.prefix(3) {
                    context += "\n- \(commit.summary)"
                }
            }

            return context
        }

        /// Returns a brief summary for display
        func briefSummary() -> String? {
            guard let branch = currentBranch else { return nil }
            return "Branch: \(branch) (\(status?.summary ?? "unknown"))"
        }

        // MARK: - Git Operations

        /// Creates a checkpoint (stash) of current changes
        func createCheckpoint(message: String? = nil) async -> String? {
            guard let root = repoRoot else { return nil }

            let stashMessage = message ?? "Ayna checkpoint \(Date().formatted())"
            let result = await runGitCommand(["stash", "push", "-m", stashMessage], in: root)

            if result.exitCode == 0 {
                log(.info, "Checkpoint created", metadata: ["message": stashMessage])
                return stashMessage
            }

            log(.error, "Failed to create checkpoint", metadata: ["error": result.stderr])
            return nil
        }

        /// Restores from a checkpoint
        func restoreCheckpoint(index: Int = 0) async -> Bool {
            guard let root = repoRoot else { return false }

            let result = await runGitCommand(["stash", "pop", "--index", "\(index)"], in: root)

            if result.exitCode == 0 {
                log(.info, "Checkpoint restored", metadata: ["index": "\(index)"])
                return true
            }

            log(.error, "Failed to restore checkpoint", metadata: ["error": result.stderr])
            return false
        }

        /// Lists available checkpoints (stashes)
        func listCheckpoints() async -> [(index: Int, message: String)] {
            guard let root = repoRoot else { return [] }

            let result = await runGitCommand(["stash", "list"], in: root)
            guard result.exitCode == 0 else { return [] }

            var checkpoints: [(Int, String)] = []
            let lines = result.stdout.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() where !line.isEmpty {
                // Format: stash@{0}: On branch: message
                if let colonIndex = line.firstIndex(of: ":"),
                   let secondColonIndex = line[line.index(after: colonIndex)...].firstIndex(of: ":")
                {
                    let message = String(line[line.index(after: secondColonIndex)...]).trimmingCharacters(in: .whitespaces)
                    checkpoints.append((index, message))
                } else {
                    checkpoints.append((index, line))
                }
            }

            return checkpoints
        }

        // MARK: - Private Methods

        private func findGitRoot(from directory: URL) async -> URL? {
            let result = await runGitCommand(["rev-parse", "--show-toplevel"], in: directory)

            if result.exitCode == 0 {
                let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return URL(fileURLWithPath: path)
            }

            return nil
        }

        private func loadCurrentBranch(in root: URL) async -> String? {
            let result = await runGitCommand(["branch", "--show-current"], in: root)

            if result.exitCode == 0 {
                let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return branch.isEmpty ? nil : branch
            }

            return nil
        }

        private func loadStatus(in root: URL) async -> GitStatus? {
            let result = await runGitCommand(["status", "--porcelain"], in: root)
            guard result.exitCode == 0 else { return nil }

            var staged: [String] = []
            var unstaged: [String] = []
            var untracked: [String] = []

            for line in result.stdout.components(separatedBy: .newlines) where line.count >= 3 {
                let statusCode = String(line.prefix(2))
                let file = String(line.dropFirst(3))

                if statusCode.hasPrefix("?") {
                    untracked.append(file)
                } else if statusCode.first != " " {
                    staged.append(file)
                } else if statusCode.last != " " {
                    unstaged.append(file)
                }
            }

            return GitStatus(staged: staged, unstaged: unstaged, untracked: untracked)
        }

        private func loadRecentCommits(in root: URL, limit: Int) async -> [GitCommit] {
            let result = await runGitCommand(
                ["log", "--oneline", "-n", "\(limit)", "--format=%H|%h|%s|%an|%aI"],
                in: root
            )

            guard result.exitCode == 0 else { return [] }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime]

            return result.stdout.components(separatedBy: .newlines).compactMap { line -> GitCommit? in
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 5 else { return nil }

                let date = dateFormatter.date(from: parts[4]) ?? Date()

                return GitCommit(
                    id: parts[0],
                    shortSha: parts[1],
                    message: parts[2],
                    author: parts[3],
                    date: date
                )
            }
        }

        private func detectMainBranch(in root: URL) async -> String? {
            // Check for common main branch names
            for branch in ["main", "master", "develop", "development"] {
                let result = await runGitCommand(
                    ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
                    in: root
                )
                if result.exitCode == 0 {
                    return branch
                }
            }

            // Try to get from remote
            let result = await runGitCommand(
                ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"],
                in: root
            )

            if result.exitCode == 0 {
                let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return ref.replacingOccurrences(of: "origin/", with: "")
            }

            return nil
        }

        private func runGitCommand(_ arguments: [String], in directory: URL) async -> GitCommandResult {
            // Run blocking Process operations off the main thread to prevent UI freezes
            await withCheckedContinuation { continuation in
                Task.detached {
                    let process = Process()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()

                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = arguments
                    process.currentDirectoryURL = directory
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    do {
                        try process.run()
                        process.waitUntilExit()

                        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
                        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

                        continuation.resume(returning: GitCommandResult(
                            exitCode: process.terminationStatus,
                            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                            stderr: String(data: stderrData, encoding: .utf8) ?? ""
                        ))
                    } catch {
                        continuation.resume(returning: GitCommandResult(
                            exitCode: -1,
                            stdout: "",
                            stderr: error.localizedDescription
                        ))
                    }
                }
            }
        }

        private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
            DiagnosticsLogger.log(.builtinTools, level: level, message: "🔀 Git: \(message)", metadata: metadata)
        }
    }
#endif
