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
            guard repoRoot != nil else { return nil }
            let branch = currentBranch ?? "(detached HEAD)"

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

        /// How long a single git command may run before it is stopped.
        static let commandTimeout: Duration = .seconds(10)

        private func runGitCommand(_ arguments: [String], in directory: URL) async -> GitCommandResult {
            await Self.runGit(arguments, in: directory, timeout: Self.commandTimeout)
        }

        /// Runs git in its own process group (`CommandSubprocess`), with hooks, credential
        /// helpers and fsmonitor disabled so a repository's configuration cannot run code. On
        /// timeout the whole group is stopped (TERM, then KILL); completion waits for git itself,
        /// not for EOF, so a helper that keeps a pipe open cannot hold the call.
        nonisolated static func runGit(
            _ arguments: [String],
            in directory: URL,
            timeout: Duration
        ) async -> GitCommandResult {
            let words = [
                "/usr/bin/env",
                "GIT_CONFIG_NOSYSTEM=1",
                "GIT_TERMINAL_PROMPT=0",
                "GIT_OPTIONAL_LOCKS=0", // Read-only queries never take the index lock
                "/usr/bin/git",
                "-c", "core.hooksPath=/dev/null",
                "-c", "credential.helper=",
                "-c", "core.fsmonitor=false"
            ] + arguments
            let command = words.map(shellQuoted).joined(separator: " ")

            return await Task.detached { () -> GitCommandResult in
                let process: CommandSubprocess
                do {
                    process = try CommandSubprocess.start(command: command, workingDirectory: directory)
                } catch {
                    return GitCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
                }
                let stdout = GitOutputBuffer()
                let stderr = GitOutputBuffer()
                process.standardOutput.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil } else { stdout.append(data) }
                }
                process.standardError.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil } else { stderr.append(data) }
                }
                let timedOut = GitOutputBuffer()
                let timer = Task.detached {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    timedOut.append(Data([1]))
                    process.terminate()
                    try? await Task.sleep(for: .milliseconds(500))
                    process.forceKill()
                }

                let status = process.waitUntilExit()
                timer.cancel()
                process.standardOutput.readabilityHandler = nil
                process.standardError.readabilityHandler = nil
                let remaining = process.drainAvailableOutput()
                stdout.append(remaining.stdout)
                stderr.append(remaining.stderr)
                process.closeOutput()

                let didTimeOut = !timedOut.data.isEmpty
                return GitCommandResult(
                    exitCode: status,
                    stdout: String(data: stdout.data, encoding: .utf8) ?? "",
                    stderr: didTimeOut ? "git timed out" : String(data: stderr.data, encoding: .utf8) ?? ""
                )
            }.value
        }

        private nonisolated static func shellQuoted(_ word: String) -> String {
            "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
            DiagnosticsLogger.log(.builtinTools, level: level, message: "🔀 Git: \(message)", metadata: metadata)
        }
    }

    /// Output collected from a pipe's readability handler.
    private final class GitOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var data: Data {
            lock.withLock { storage }
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.withLock { storage.append(data) }
        }
    }
#endif
