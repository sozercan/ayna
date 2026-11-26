import Foundation
import os.log

#if os(macOS)
    @Observable @MainActor
    final class GitContextService {
        private(set) var status: GitStatus?

        private(set) var currentBranch: String?

        private(set) var recentCommits: [GitCommit] = []

        private(set) var mainBranch: String?

        var isClean: Bool {
            status?.isClean ?? true
        }

        private var repoRoot: URL?

        private var filterOverrides: [String] = []

        private(set) var loadFailure: String?

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
            let id: String
            let shortSha: String
            let message: String
            let author: String
            let date: Date

            var summary: String {
                "\(shortSha) \(message)"
            }
        }

        struct GitCommandResult {
            let exitCode: Int32
            let stdout: String
            let stderr: String
        }

        func loadContext(from directory: URL) async {
            filterOverrides = []
            loadFailure = nil
            repoRoot = await findGitRoot(from: directory)

            guard let root = repoRoot, !Task.isCancelled else {
                reset()
                return
            }

            guard let overrides = await Self.filterDriverOverrides(in: root), !Task.isCancelled else {
                reset()
                loadFailure = "Couldn't read the repository's filter configuration, so git status was not run."
                return
            }
            filterOverrides = overrides

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

        func reset() {
            repoRoot = nil
            filterOverrides = []
            currentBranch = nil
            status = nil
            recentCommits = []
            mainBranch = nil
        }

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

        func briefSummary() -> String? {
            guard let branch = currentBranch else { return nil }
            return "Branch: \(branch) (\(status?.summary ?? "unknown"))"
        }

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

        func listCheckpoints() async -> [(index: Int, message: String)] {
            guard let root = repoRoot else { return [] }

            let result = await runGitCommand(["stash", "list"], in: root)
            guard result.exitCode == 0 else { return [] }

            var checkpoints: [(Int, String)] = []
            let lines = result.stdout.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() where !line.isEmpty {
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
            let result = await runGitCommand(["status", "--porcelain", "--ignore-submodules=all"], in: root)
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
            for branch in ["main", "master", "develop", "development"] {
                guard !Task.isCancelled else { return nil }
                let result = await runGitCommand(
                    ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
                    in: root
                )
                if result.exitCode == 0 {
                    return branch
                }
            }

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

        static let commandTimeout: Duration = .seconds(10)

        nonisolated static let maximumOutputBytes = 1024 * 1024

        private func runGitCommand(_ arguments: [String], in directory: URL) async -> GitCommandResult {
            await Self.runGit(arguments, in: directory, timeout: Self.commandTimeout, environment: filterOverrides)
        }

        struct RepositoryLayout: Equatable, Sendable {
            let topLevel: URL
            let gitDirectory: URL
            let commonDirectory: URL
        }

        nonisolated static func repositoryLayout(at directory: URL) async -> RepositoryLayout? {
            let result = await runGit(
                ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
                in: directory,
                timeout: commandTimeout
            )
            let lines = result.stdout.split(separator: "\n").map(String.init)
            guard result.exitCode == 0, lines.count == 3 else { return nil }
            let urls = lines.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardized }
            return RepositoryLayout(topLevel: urls[0], gitDirectory: urls[1], commonDirectory: urls[2])
        }

        nonisolated static func filterDriverOverrides(in root: URL) async -> [String]? {
            let result = await runGit(
                ["config", "--null", "--name-only", "--get-regexp", "^filter\\..+\\.(clean|smudge|process|required)$"],
                in: root,
                timeout: commandTimeout
            )
            if result.exitCode == 1, result.stdout.isEmpty, result.stderr.isEmpty {
                return []
            }
            guard result.exitCode == 0 else { return nil }
            var drivers: [String] = []
            for key in result.stdout.split(separator: "\0") {
                let name = key.dropFirst("filter.".count)
                guard let dot = name.lastIndex(of: ".") else { continue }
                let driver = String(name[..<dot])
                if !driver.isEmpty, !drivers.contains(driver) {
                    drivers.append(driver)
                }
            }
            let entries = drivers.flatMap { driver in
                [("clean", ""), ("smudge", ""), ("process", ""), ("required", "false")].map { ("filter.\(driver).\($0.0)", $0.1) }
            }
            return ["GIT_CONFIG_COUNT=\(entries.count)"] + entries.enumerated().flatMap { index, entry in
                ["GIT_CONFIG_KEY_\(index)=\(entry.0)", "GIT_CONFIG_VALUE_\(index)=\(entry.1)"]
            }
        }

        nonisolated static func runGit(
            _ arguments: [String],
            in directory: URL,
            timeout: Duration,
            environment: [String] = []
        ) async -> GitCommandResult {
            let words = [
                "/usr/bin/env",
                "GIT_CONFIG_NOSYSTEM=1",
                "GIT_TERMINAL_PROMPT=0",
                "GIT_OPTIONAL_LOCKS=0"
            ] + environment + [
                "/usr/bin/git",
                "-c", "core.hooksPath=/dev/null",
                "-c", "credential.helper=",
                "-c", "core.fsmonitor=false",
                "-c", "log.showSignature=false"
            ] + arguments
            let command = words.map(shellQuoted).joined(separator: " ")
            let run = GitRun()

            return await withTaskCancellationHandler {
                await Task.detached { () -> GitCommandResult in
                    await execute(command, in: directory, timeout: timeout, run: run)
                }.value
            } onCancel: {
                run.cancel()
            }
        }

        private nonisolated static func execute(
            _ command: String,
            in directory: URL,
            timeout: Duration,
            run: GitRun
        ) async -> GitCommandResult {
            let process: CommandSubprocess
            do {
                guard !run.isCancelled else { throw CancellationError() }
                process = try CommandSubprocess.start(command: command, workingDirectory: directory)
            } catch {
                return GitCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
            }
            run.attach(process)
            let stdout = GitOutputBuffer(limit: maximumOutputBytes)
            let stderr = GitOutputBuffer(limit: maximumOutputBytes)
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

            let failure: String? = if !timedOut.data.isEmpty {
                "git timed out"
            } else if run.isCancelled {
                "git was cancelled"
            } else if stdout.isTruncated || stderr.isTruncated {
                "git output exceeded \(maximumOutputBytes / 1024) KB"
            } else {
                nil
            }
            if let failure {
                return GitCommandResult(exitCode: -1, stdout: "", stderr: failure)
            }
            return GitCommandResult(
                exitCode: status,
                stdout: String(data: stdout.data, encoding: .utf8) ?? "",
                stderr: String(data: stderr.data, encoding: .utf8) ?? ""
            )
        }

        private nonisolated static func shellQuoted(_ word: String) -> String {
            "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
            DiagnosticsLogger.log(.builtinTools, level: level, message: "🔀 Git: \(message)", metadata: metadata)
        }
    }

    private final class GitOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var storage = Data()
        private var truncated = false

        init(limit: Int = .max) {
            self.limit = limit
        }

        var data: Data {
            lock.withLock { storage }
        }

        var isTruncated: Bool {
            lock.withLock { truncated }
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.withLock {
                let room = limit - storage.count
                if data.count > room {
                    truncated = true
                    storage.append(data.prefix(max(room, 0)))
                } else {
                    storage.append(data)
                }
            }
        }
    }

    private final class GitRun: @unchecked Sendable {
        private let lock = NSLock()
        private var process: CommandSubprocess?
        private var cancelled = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func attach(_ process: CommandSubprocess) {
            let stopNow = lock.withLock {
                self.process = process
                return cancelled
            }
            if stopNow {
                Self.stop(process)
            }
        }

        func cancel() {
            let process = lock.withLock {
                cancelled = true
                return self.process
            }
            if let process {
                Self.stop(process)
            }
        }

        private static func stop(_ process: CommandSubprocess) {
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: .milliseconds(500))
                process.forceKill()
            }
        }
    }
#endif
