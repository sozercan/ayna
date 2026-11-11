// swiftlint:disable identifier_name
@testable import Ayna
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

#if os(macOS)
    @Suite("Agent context tools", .serialized)
    @MainActor
    struct AgentContextToolsTests {
        /// A directory under /tmp, which is not protected, so read-only tools run without asking.
        private func makeRoot() throws -> URL {
            let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("AynaContextTools-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root.resolvingSymlinksInPath()
        }

        private func makeService(root: URL) -> BuiltinToolService {
            let service = BuiltinToolService(permissionService: PermissionService())
            var settings = AgentSettings.default
            settings.projectRootPath = root.path
            service.apply(settings)
            return service
        }

        @Test(.timeLimit(.minutes(1)))
        func `git_context reports branch and changed files`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = await GitContextService.runGit(["init", "-b", "trunk"], in: root, timeout: .seconds(10))
            try "hello".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            let service = makeService(root: root)

            let output = await service.executeToolCall(toolName: "git_context", arguments: [:], conversationId: UUID())

            #expect(output.contains("Current branch: trunk"))
            #expect(output.contains("untracked: notes.txt"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A git command that hangs is stopped at the timeout`() async {
            let clock = ContinuousClock()
            let start = clock.now
            let result = await GitContextService.runGit(
                ["-c", "alias.wait=!sleep 30", "wait"],
                in: URL(fileURLWithPath: "/tmp"),
                timeout: .seconds(1)
            )
            #expect(result.exitCode != 0)
            #expect(clock.now - start < .seconds(10))
        }

        @Test(.timeLimit(.minutes(1)))
        func `Large stderr does not deadlock the git runner`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            // About 200 KB on stderr, well past a pipe buffer, while stdout stays open.
            let result = await GitContextService.runGit(
                ["-c", "alias.noisy=!yes error-line | head -n 20000 >&2; echo done", "noisy"],
                in: root,
                timeout: .seconds(20)
            )
            #expect(result.stdout.contains("done"))
            #expect(result.stderr.count > 100_000)
        }

        @Test(.timeLimit(.minutes(1)))
        func `A detached HEAD still reports status and commits`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            for arguments in [
                ["init", "-b", "trunk"],
                ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "first"],
                ["checkout", "--detach"]
            ] {
                _ = await GitContextService.runGit(arguments, in: root, timeout: .seconds(10))
            }
            let service = makeService(root: root)

            let output = await service.executeToolCall(toolName: "git_context", arguments: [:], conversationId: UUID())

            #expect(output.contains("(detached HEAD)"))
            #expect(output.contains("first"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A repository's fsmonitor command never runs`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("fsmonitor-ran")
            _ = await GitContextService.runGit(["init"], in: root, timeout: .seconds(10))
            _ = await GitContextService.runGit(
                ["config", "core.fsmonitor", "touch \(marker.path); false"],
                in: root,
                timeout: .seconds(10)
            )
            let service = makeService(root: root)

            _ = await service.executeToolCall(toolName: "git_context", arguments: [:], conversationId: UUID())

            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A repository's filter driver never runs`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("filter-ran")
            for arguments in [
                ["init"],
                ["config", "user.name", "t"],
                ["config", "user.email", "t@example.com"]
            ] {
                _ = await GitContextService.runGit(arguments, in: root, timeout: .seconds(10))
            }
            try "*.txt filter=evil\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            let file = root.appendingPathComponent("notes.txt")
            try "one".write(to: file, atomically: true, encoding: .utf8)
            for arguments in [["add", "."], ["commit", "-m", "first"]] {
                _ = await GitContextService.runGit(arguments, in: root, timeout: .seconds(10))
            }
            for (key, value) in [
                ("filter.evil.clean", "touch '\(marker.path)'; cat"),
                ("filter.evil.process", "touch '\(marker.path)'"),
                ("filter.evil.required", "true")
            ] {
                _ = await GitContextService.runGit(["config", key, value], in: root, timeout: .seconds(10))
            }
            // Same size, new mtime: status can only tell by rehashing the file through its filter.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3600)],
                ofItemAtPath: file.path
            )
            let service = makeService(root: root)

            let output = await service.executeToolCall(toolName: "git_context", arguments: [:], conversationId: UUID())

            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(output.contains("Current branch:"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A signed commit's verifier never runs`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("verifier-ran")
            let verifier = root.appendingPathComponent("verify.sh")
            try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: verifier, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: verifier.path)
            _ = await GitContextService.runGit(["init", "-b", "trunk"], in: root, timeout: .seconds(10))
            let tree = await GitContextService.runGit(["write-tree"], in: root, timeout: .seconds(10))
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = """
            tree \(tree)
            author t <t@example.com> 1700000000 +0000
            committer t <t@example.com> 1700000000 +0000
            gpgsig -----BEGIN PGP SIGNATURE-----
             
             AAAA
             -----END PGP SIGNATURE-----

            signed
            """
            let commitFile = root.appendingPathComponent("commit.txt")
            try (commit + "\n").write(to: commitFile, atomically: true, encoding: .utf8)
            let sha = await GitContextService.runGit(
                ["hash-object", "-t", "commit", "-w", commitFile.path],
                in: root,
                timeout: .seconds(10)
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            for arguments in [
                ["update-ref", "refs/heads/trunk", sha],
                ["config", "log.showSignature", "true"],
                ["config", "gpg.program", verifier.path]
            ] {
                _ = await GitContextService.runGit(arguments, in: root, timeout: .seconds(10))
            }
            let service = makeService(root: root)

            let output = await service.executeToolCall(toolName: "git_context", arguments: [:], conversationId: UUID())

            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(output.contains("signed"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `Git output past the limit fails instead of being cut short`() async {
            let bytes = GitContextService.maximumOutputBytes * 2
            let result = await GitContextService.runGit(
                ["-c", "alias.flood=!yes line | head -c \(bytes)", "flood"],
                in: URL(fileURLWithPath: "/tmp"),
                timeout: .seconds(20)
            )
            #expect(result.exitCode != 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("exceeded"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `Cancelling the caller stops the git process group`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("still-running")
            let started = root.appendingPathComponent("started")
            let call = Task {
                await GitContextService.runGit(
                    ["-c", "alias.slow=!touch '\(started.path)'; sleep 2; touch '\(marker.path)'", "slow"],
                    in: root,
                    timeout: .seconds(20)
                )
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !FileManager.default.fileExists(atPath: started.path), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let cancelledAt = clock.now
            call.cancel()
            let result = await call.value

            #expect(result.exitCode != 0)
            #expect(clock.now - cancelledAt < .seconds(2))
            try await Task.sleep(for: .seconds(3))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A FIFO context file is skipped without blocking`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try "// swift-tools-version:6.0".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            #expect(mkfifo(root.appendingPathComponent("AGENTS.md").path, 0o644) == 0)
            try "Use tabs.".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
            let service = makeService(root: root)

            let output = await service.executeToolCall(toolName: "project_context", arguments: [:], conversationId: UUID())

            #expect(output.contains("Use tabs."))
            #expect(!output.contains("## AGENTS.md"))
        }

        @Test
        func `An opened context file keeps reading the file that was checked`() throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("real.md")
            try "checked".write(to: target, atomically: false, encoding: .utf8)
            let link = root.appendingPathComponent("AGENTS.md")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let (handle, path) = try #require(ProjectContextService.openContextFile(link))
            // Swap the name for a link to another file, as could happen while approval is pending.
            let other = root.appendingPathComponent("other.md")
            try "swapped".write(to: other, atomically: false, encoding: .utf8)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)

            #expect(path.lastPathComponent == "real.md")
            #expect(ProjectContextService.readContextFile(handle) == "checked")
        }

        @Test(.timeLimit(.minutes(1)))
        func `A helper that keeps a pipe open cannot hold the git runner`() async {
            let clock = ContinuousClock()
            let start = clock.now
            let result = await GitContextService.runGit(
                ["-c", "alias.linger=!(sleep 30 &) ; echo started", "linger"],
                in: URL(fileURLWithPath: "/tmp"),
                timeout: .seconds(20)
            )
            #expect(result.stdout.contains("started"))
            #expect(clock.now - start < .seconds(10))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A context file that links to a sensitive file asks before it is read`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let secrets = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
            let key = secrets.appendingPathComponent("id_rsa")
            try "PRIVATE KEY".write(to: key, atomically: true, encoding: .utf8)
            try "// swift-tools-version:6.0".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("AGENTS.md"), withDestinationURL: key)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService)
            var settings = AgentSettings.default
            settings.projectRootPath = root.path
            service.apply(settings)

            let call = Task {
                await service.executeToolCall(toolName: "project_context", arguments: [:], conversationId: UUID())
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while permissionService.pendingApprovals.isEmpty, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let pending = try #require(permissionService.pendingApprovals.first)
            #expect(pending.details.hasSuffix("id_rsa"))
            permissionService.deny(pending.id)

            #expect(await !call.value.contains("PRIVATE KEY"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `project_context returns the project type and context files`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try "// swift-tools-version:6.0".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "Use tabs.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
            let service = makeService(root: root)

            let output = await service.executeToolCall(toolName: "project_context", arguments: [:], conversationId: UUID())

            #expect(output.contains("Swift"))
            #expect(output.contains("Use tabs."))
        }

        @Test
        func `update_tasks replaces the list and keeps unchanged tasks`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let service = makeService(root: root)
            let conversationId = UUID()

            _ = await service.executeToolCall(
                toolName: "update_tasks",
                arguments: ["tasks": [
                    ["content": "Write tests", "status": "in_progress"],
                    ["content": "Ship", "status": "pending"]
                ]],
                conversationId: conversationId
            )
            let first = ConversationTaskManager.shared.tasksByConversation[conversationId] ?? []
            let output = await service.executeToolCall(
                toolName: "update_tasks",
                arguments: ["tasks": [
                    ["content": "Write tests", "status": "completed"],
                    ["content": "Ship", "status": "in_progress"]
                ]],
                conversationId: conversationId
            )
            let second = ConversationTaskManager.shared.tasksByConversation[conversationId] ?? []

            #expect(second.map(\.id) == first.map(\.id))
            #expect(second.map(\.status) == [.completed, .inProgress])
            #expect(output.contains("2 tasks, 1 completed, 1 in progress"))
            ConversationTaskManager.shared.clearTasks(forConversation: conversationId)
        }

        @Test
        func `A long task list scrolls instead of growing past its height limit`() throws {
            let manager = ConversationTaskManager()
            let conversationId = UUID()
            let view = TaskListView(taskManager: manager, conversationId: conversationId).frame(width: 480)
            func renderedHeight() throws -> CGFloat {
                let renderer = ImageRenderer(content: view)
                return try #require(renderer.nsImage).size.height
            }

            manager.replaceTasks([ConversationTask(content: "Only task")], forConversation: conversationId)
            let short = try renderedHeight()
            manager.replaceTasks(
                (1 ... 50).map { ConversationTask(content: "Task \($0)") },
                forConversation: conversationId
            )
            let long = try renderedHeight()

            #expect(short < 150)
            #expect(long > short)
            #expect(long < 320)
        }

        @Test
        func `Saved settings pick up defaults for tools added later`() throws {
            let suite = "AgentContextToolsTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let previous = AppPreferences.storage
            AppPreferences.use(defaults)
            defer { AppPreferences.use(previous) }
            var older = AgentSettings.default
            older.defaultPermissions = ["read_file": .askAlways]
            older.save()

            let loaded = AgentSettings.load()

            #expect(loaded.permissionLevel(for: "read_file") == .askAlways)
            #expect(loaded.permissionLevel(for: "git_context") == .automatic)
        }
    }

    @Suite("Hotkey combinations")
    struct HotkeyCombinationTests {
        /// Labels as the US layout would, so expectations do not depend on this Mac's layout.
        private func usLabel(_ combination: HotkeyCombination) -> String {
            combination.displayString(layoutCharacter: { _ in nil })
        }

        @Test
        func `Older saved strings parse to the key that was recorded`() throws {
            #expect(HotkeyCombination(storage: "⌘⇧Space") == .default)
            #expect(HotkeyCombination(storage: "cmd+shift+space") == .default)
            let combination = HotkeyCombination(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
            #expect(usLabel(combination) == "⌃⌥K")
            #expect(HotkeyCombination(storage: usLabel(combination)) == combination)
            let function = HotkeyCombination(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))
            #expect(HotkeyCombination(storage: usLabel(function)) == function)
            #expect(HotkeyCombination(storage: "⌘Nonsense") == nil)
            // Keys without a name (keypad, F13+) round-trip through their numeric fallback.
            let keypad = HotkeyCombination(keyCode: 105, modifiers: UInt32(cmdKey))
            #expect(usLabel(keypad) == "⌘Key 105")
            #expect(HotkeyCombination(storage: usLabel(keypad)) == keypad)
        }

        @Test
        func `The saved shortcut keeps its key code whatever the layout shows`() throws {
            // On a German layout the key in the US "Z" position types "y".
            let combination = HotkeyCombination(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))
            let german = combination.displayString(layoutCharacter: { $0 == UInt32(kVK_ANSI_Z) ? "Y" : nil })

            #expect(german == "⌃⌥Y")
            #expect(HotkeyCombination(storage: combination.storageString) == combination)
            // Space and function keys keep their fixed names on every layout.
            #expect(HotkeyCombination.default.displayString(layoutCharacter: { _ in "X" }) == "⇧⌘Space")
        }

        @Test
        @MainActor
        func `The active layout labels a letter key`() {
            let label = HotkeyCombination(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)).displayString
            #expect(label.hasPrefix("⌘"))
            #expect(label.count == 2)
        }

        @Test
        func `Shortcuts that would break typing or collide with macOS are flagged`() {
            #expect(!HotkeyCombination(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)).hasRequiredModifier)
            #expect(HotkeyCombination.default.hasRequiredModifier)
            #expect(HotkeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)).systemConflict == "Spotlight")
            #expect(HotkeyCombination.default.systemConflict == nil)
        }
    }
#endif

// swiftlint:enable identifier_name
