//
//  BuiltinToolService+Context.swift
//  Ayna
//
//  Read-only project and git context tools, and the conversation task list tool.
//

import Foundation

#if os(macOS)
    extension BuiltinToolService {
        /// Longest context a single call returns, so one large file cannot fill the window.
        static let maximumContextCharacters = 40000

        /// Resolves, validates, and approves a directory for a read-only tool.
        private func authorizedDirectory(
            _ path: String?,
            tool: String,
            description: String,
            conversationId: UUID
        ) async throws -> URL {
            let path = anchoredPath(path ?? ".")
            guard let directory = pathValidator.canonicalize(path) else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Cannot resolve path")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ToolExecutionError.invalidPath(path: path, reason: "Not a directory")
            }
            let riskReason: String?
            switch pathValidator.validate(url: directory, operation: .read) {
            case let .denied(reason):
                throw ToolExecutionError.invalidPath(path: path, reason: reason)
            case let .requiresApproval(reason):
                riskReason = reason
            case .allowed:
                riskReason = nil
            }
            let identity = Self.fileIdentity(of: directory)
            try await authorize(
                tool: tool,
                description: description,
                details: directory.path,
                riskReason: riskReason,
                conversationId: conversationId
            )
            // The path could have been swapped (for example for a symlink) while the approval
            // card was open; only the directory that was checked may be read.
            guard identity != nil,
                  pathValidator.canonicalize(path) == directory,
                  Self.fileIdentity(of: directory) == identity
            else {
                throw ToolExecutionError.invalidPath(path: path, reason: "The directory changed while waiting for approval")
            }
            return directory
        }

        /// Device and inode of a file, which stay the same only while it is the same file.
        private static func fileIdentity(of url: URL) -> [UInt64]? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return [UInt64(info.st_dev), UInt64(info.st_ino)]
        }

        /// Approves git metadata that lives outside the repository's work tree. A `.git` file
        /// can point anywhere, such as a protected `~/.config` repository, and only the work
        /// tree directory was checked so far.
        private func authorizeGitMetadata(
            _ layout: GitContextService.RepositoryLayout,
            conversationId: UUID
        ) async throws {
            let rootComponents = layout.topLevel.pathComponents
            // A separate git dir is usually also the common dir; ask once per location.
            let locations = layout.commonDirectory == layout.gitDirectory
                ? [layout.gitDirectory]
                : [layout.gitDirectory, layout.commonDirectory]
            for metadata in locations where !metadata.pathComponents.starts(with: rootComponents) {
                let riskReason = switch pathValidator.validate(url: metadata, operation: .read) {
                case let .denied(reason):
                    throw ToolExecutionError.invalidPath(path: metadata.path, reason: reason)
                case let .requiresApproval(reason):
                    "Git metadata outside the repository. \(reason)"
                case .allowed:
                    "Git metadata outside the repository"
                }
                try await authorize(
                    tool: ToolName.gitContext,
                    description: "Read git metadata",
                    details: metadata.path,
                    riskReason: riskReason,
                    conversationId: conversationId
                )
            }
        }

        /// Branch, status, changed files, and recent commits for the repository containing `path`.
        func gitContext(path: String?, conversationId: UUID) async throws -> String {
            guard isEnabled else { throw ToolExecutionError.serviceDisabled }
            let directory = try await authorizedDirectory(
                path,
                tool: ToolName.gitContext,
                description: "Read git status",
                conversationId: conversationId
            )
            guard let layout = await GitContextService.repositoryLayout(at: directory) else {
                try Task.checkCancellation()
                return "Not a git repository: \(directory.path)"
            }
            try await authorizeGitMetadata(layout, conversationId: conversationId)
            let git = GitContextService()
            await git.loadContext(from: directory)
            try Task.checkCancellation()
            if let failure = git.loadFailure {
                throw ToolExecutionError.invalidPath(path: directory.path, reason: failure)
            }
            guard var output = git.systemPromptContext() else {
                return "Not a git repository: \(directory.path)"
            }
            if let status = git.status, !status.isClean {
                output += "\n\nChanged files:"
                for (label, files) in [("staged", status.staged), ("modified", status.unstaged), ("untracked", status.untracked)] {
                    for file in files.prefix(50) {
                        output += "\n- \(label): \(file)"
                    }
                    if files.count > 50 {
                        output += "\n- \(label): … \(files.count - 50) more"
                    }
                }
            }
            return output
        }

        /// Project type and the AI context files (AGENTS.md, CLAUDE.md, ...) of the project containing `path`.
        func projectContext(path: String?, conversationId: UUID) async throws -> String {
            guard isEnabled else { throw ToolExecutionError.serviceDisabled }
            let directory = try await authorizedDirectory(
                path,
                tool: ToolName.projectContext,
                description: "Read project context",
                conversationId: conversationId
            )
            let project = ProjectContextService()
            await project.detectProject(from: directory, loadingContent: false)
            guard let summary = project.briefSummary() else {
                return "No project found at or above \(directory.path)"
            }
            var output = summary
            // Each context file is resolved and checked like a read_file target: a symlinked
            // AGENTS.md pointing at a key or credentials file asks before it is read.
            for file in project.contextFiles {
                guard output.count < Self.maximumContextCharacters,
                      let content = try await readContextFile(file, conversationId: conversationId)
                else {
                    continue
                }
                output += "\n\n## \(file.lastPathComponent)\n\n\(content)"
            }
            if output.count > Self.maximumContextCharacters {
                output = String(output.prefix(Self.maximumContextCharacters)) + "\n[Truncated]"
            }
            return output
        }

        private func readContextFile(_ file: URL, conversationId: UUID) async throws -> String? {
            guard let (handle, path) = ProjectContextService.openContextFile(file) else {
                return nil
            }
            let riskReason: String?
            switch pathValidator.validate(url: path, operation: .read) {
            case .denied:
                return nil
            case let .requiresApproval(reason):
                riskReason = reason
            case .allowed:
                riskReason = nil
            }
            if let riskReason {
                try await authorize(
                    tool: ToolName.projectContext,
                    description: "Read project context file",
                    details: path.path,
                    riskReason: riskReason,
                    conversationId: conversationId
                )
            }
            return ProjectContextService.readContextFile(handle)
        }

        /// Replaces the conversation's task list. Tasks keep their identity when their text is unchanged.
        func updateTasks(_ entries: [[String: Any]], conversationId: UUID) async throws -> String {
            guard isEnabled else { throw ToolExecutionError.serviceDisabled }
            // The conversation is the approval target, so approving one list doesn't approve
            // other conversations' lists of the same length.
            try await authorize(
                tool: ToolName.updateTasks,
                description: "Update task list (\(entries.count) tasks)",
                details: "Conversation \(conversationId.uuidString)",
                riskReason: nil,
                conversationId: conversationId
            )
            let manager = ConversationTaskManager.shared
            let existing = manager.tasksByConversation[conversationId] ?? []
            var unmatched = existing
            var tasks: [ConversationTask] = []
            for entry in entries.prefix(50) {
                guard let content = (entry["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty
                else {
                    continue
                }
                let status = (entry["status"] as? String).flatMap(TaskStatus.init(rawValue:)) ?? .pending
                let notes = (entry["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let index = unmatched.firstIndex(where: { $0.content == content }) {
                    var task = unmatched.remove(at: index)
                    if task.status != status {
                        task.updateStatus(status)
                    }
                    task.setNotes(notes)
                    tasks.append(task)
                } else {
                    tasks.append(ConversationTask(content: content, status: status, notes: notes))
                }
            }
            manager.replaceTasks(tasks, forConversation: conversationId)
            let statistics = manager.statistics(forConversation: conversationId)
            return "Task list updated: \(statistics.total) tasks, \(statistics.completed) completed, "
                + "\(statistics.inProgress) in progress."
        }

        func gitContextDefinition() -> [String: Any] {
            Self.pathOnlyDefinition(
                name: ToolName.gitContext,
                description: "Get the current git branch, working-tree status with changed files, and recent commits. Read-only.",
                pathDescription: "A directory inside the repository (defaults to the project root)"
            )
        }

        func projectContextDefinition() -> [String: Any] {
            Self.pathOnlyDefinition(
                name: ToolName.projectContext,
                description: "Get the project type and the contents of AI context files such as AGENTS.md and CLAUDE.md. Read-only.",
                pathDescription: "A directory inside the project (defaults to the project root)"
            )
        }

        func updateTasksDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.updateTasks,
                    "description": "Replace the task list shown to the user for this conversation. Use it to plan multi-step work and keep each task's status current. Send the full list every time.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "tasks": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "content": ["type": "string", "description": "What the task is"],
                                        "status": [
                                            "type": "string",
                                            "enum": TaskStatus.allCases.map(\.rawValue)
                                        ],
                                        "notes": ["type": "string", "description": "Optional blocker or note"]
                                    ] as [String: Any],
                                    "required": ["content", "status"]
                                ] as [String: Any]
                            ] as [String: Any]
                        ] as [String: Any],
                        "required": ["tasks"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        private static func pathOnlyDefinition(name: String, description: String, pathDescription: String) -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": pathDescription]
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }
    }
#endif
