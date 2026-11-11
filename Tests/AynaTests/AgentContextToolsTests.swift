// swiftlint:disable identifier_name
@testable import Ayna
import Carbon.HIToolbox
import Foundation
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
        @Test
        func `Strings parse to the same combination they display as`() throws {
            #expect(HotkeyCombination(string: "⌘⇧Space") == .default)
            #expect(HotkeyCombination(string: "cmd+shift+space") == .default)
            let combination = HotkeyCombination(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
            #expect(combination.displayString == "⌃⌥K")
            #expect(HotkeyCombination(string: combination.displayString) == combination)
            let function = HotkeyCombination(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))
            #expect(HotkeyCombination(string: function.displayString) == function)
            #expect(HotkeyCombination(string: "⌘Nonsense") == nil)
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
