// swiftlint:disable identifier_name
@testable import Ayna
import Foundation
import Testing

#if os(macOS)
    @Suite("Agent tool settings", .serialized)
    @MainActor
    struct AgentToolSettingsTests {
        private func makeRoot() throws -> URL {
            let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("AynaAgentSettings-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private func makeService(
            root: URL,
            _ configure: (inout AgentSettings) -> Void = { _ in }
        ) -> (BuiltinToolService, PermissionService) {
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService)
            var settings = AgentSettings.default
            settings.projectRootPath = root.path
            configure(&settings)
            service.apply(settings)
            return (service, permissionService)
        }

        private func waitForPending(_ permissionService: PermissionService) async -> PendingApproval? {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while permissionService.pendingApprovals.isEmpty, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return permissionService.pendingApprovals.first
        }

        @Test
        func `Denied tools refuse without asking`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try "hi".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let (service, permissionService) = makeService(root: root) { $0.setPermissionLevel(.denied, for: "read_file") }

            await #expect(throws: ToolExecutionError.self) {
                try await service.readFile(path: "a.txt", conversationId: UUID())
            }
            #expect(permissionService.pendingApprovals.isEmpty)
        }

        @Test
        func `Automatic writes inside the project root run without asking`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, permissionService) = makeService(root: root) { $0.setPermissionLevel(.automatic, for: "write_file") }

            try await service.writeFile(path: "notes/out.txt", content: "done", conversationId: UUID())

            #expect(permissionService.pendingApprovals.isEmpty)
            #expect(try String(contentsOf: root.appendingPathComponent("notes/out.txt"), encoding: .utf8) == "done")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Ask Once asks the first time and remembers the target`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, permissionService) = makeService(root: root)
            let conversationId = UUID()

            let first = Task { try await service.writeFile(path: "a.txt", content: "1", conversationId: conversationId) }
            let pending = try #require(await waitForPending(permissionService))
            permissionService.approve(pending.id)
            try await first.value

            try await service.writeFile(path: "a.txt", content: "2", conversationId: conversationId)
            #expect(permissionService.pendingApprovals.isEmpty)
            #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "2")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Writes outside the project root follow the approval setting`() async throws {
            let root = try makeRoot()
            let outside = try makeRoot()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            let target = outside.appendingPathComponent("x.txt").path

            let (asking, askingPermissions) = makeService(root: root) { $0.setPermissionLevel(.automatic, for: "write_file") }
            let write = Task { try await asking.writeFile(path: target, content: "x", conversationId: UUID()) }
            let pending = try #require(await waitForPending(askingPermissions))
            #expect(pending.description.contains("outside project"))
            askingPermissions.deny(pending.id)
            await #expect(throws: ToolExecutionError.self) { try await write.value }

            let (open, openPermissions) = makeService(root: root) {
                $0.setPermissionLevel(.automatic, for: "write_file")
                $0.requireApprovalOutsideProject = false
            }
            try await open.writeFile(path: target, content: "y", conversationId: UUID())
            #expect(openPermissions.pendingApprovals.isEmpty)
        }

        @Test
        func `Extra blocked patterns refuse matching commands`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, _) = makeService(root: root) { $0.additionalBlockedPatterns = ["echo forbidden"] }

            let output = await service.executeToolCall(
                toolName: "run_command",
                arguments: ["command": "echo forbidden"],
                conversationId: UUID()
            )
            #expect(output.contains("blocked by security policy"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `Extra allowed commands run without the allowlist approval`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, permissionService) = makeService(root: root) {
                $0.setPermissionLevel(.automatic, for: "run_command")
                $0.additionalAllowedCommands = ["true"]
            }

            let output = await service.executeToolCall(
                toolName: "run_command",
                arguments: ["command": "true"],
                conversationId: UUID()
            )
            #expect(permissionService.pendingApprovals.isEmpty)
            #expect(output.contains("Exit code: 0"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A failing command keeps its stdout`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, _) = makeService(root: root) { $0.setPermissionLevel(.automatic, for: "run_command") }

            let output = await service.executeToolCall(
                toolName: "run_command",
                arguments: ["command": "echo partial-output && ls /definitely-missing-\(UUID().uuidString)"],
                conversationId: UUID()
            )
            #expect(output.hasPrefix("ERROR:"))
            #expect(output.contains("partial-output"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A command that hits the timeout says so`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, _) = makeService(root: root) {
                $0.setPermissionLevel(.automatic, for: "run_command")
                $0.additionalAllowedCommands = ["sleep"]
                $0.commandTimeoutSeconds = 1
            }

            let output = await service.executeToolCall(
                toolName: "run_command",
                arguments: ["command": "echo started && sleep 10"],
                conversationId: UUID()
            )
            #expect(output.contains("timed out after 1 seconds"))
            #expect(output.contains("started"))
        }

        @Test(.timeLimit(.minutes(1)))
        func `Denying a tool while its approval is pending stops it`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, permissionService) = makeService(root: root)

            let write = Task { try await service.writeFile(path: "late.txt", content: "x", conversationId: UUID()) }
            let pending = try #require(await waitForPending(permissionService))
            service.toolPermissions["write_file"] = .denied
            permissionService.approve(pending.id)

            await #expect(throws: ToolExecutionError.self) { try await write.value }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("late.txt").path))
        }

        @Test(.timeLimit(.minutes(1)))
        func `Remembering the edit pre-read does not approve the edit`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AynaPreRead-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("notes.txt")
            try "hello".write(to: file, atomically: true, encoding: .utf8)
            let (service, permissionService) = makeService(root: directory)

            let edit = Task {
                try await service.editFile(path: file.path, oldText: "hello", newText: "bye", conversationId: UUID())
            }
            let preRead = try #require(await waitForPending(permissionService))
            #expect(preRead.description.hasPrefix("Read file before editing"))
            permissionService.approve(preRead.id, rememberForSession: true)

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while permissionService.pendingApprovals.first?.id == preRead.id || permissionService.pendingApprovals.isEmpty,
                  clock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let editApproval = try #require(permissionService.pendingApprovals.first)
            #expect(editApproval.diffPreview != nil)
            permissionService.deny(editApproval.id)
            await #expect(throws: ToolExecutionError.self) { try await edit.value }
            #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
        }

        @Test(.timeLimit(.minutes(1)))
        func `A listing approval does not follow a retargeted symlink`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            let (service, permissionService) = makeService(root: root) { $0.setPermissionLevel(.askOnce, for: "list_directory") }
            let conversationId = UUID()

            let firstListing = Task { try await service.listDirectory(path: link.path, conversationId: conversationId) }
            try permissionService.approve(#require(await waitForPending(permissionService)).id)
            _ = try await firstListing.value

            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
            let secondListing = Task { try await service.listDirectory(path: link.path, conversationId: conversationId) }

            let pending = try #require(await waitForPending(permissionService))
            #expect(pending.details.hasSuffix("/second"))
            permissionService.deny(pending.id)
            await #expect(throws: ToolExecutionError.self) { try await secondListing.value }
        }

        @Test(.timeLimit(.minutes(1)))
        func `A command blocked while its approval waits does not run`() async throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (service, permissionService) = makeService(root: root)

            let run = Task {
                await service.executeToolCall(toolName: "run_command", arguments: ["command": "touch marker"], conversationId: UUID())
            }
            let pending = try #require(await waitForPending(permissionService))
            var settings = AgentSettings.default
            settings.projectRootPath = root.path
            settings.additionalBlockedPatterns = ["touch"]
            service.apply(settings)
            permissionService.approve(pending.id)

            #expect(await run.value.contains("blocked by security policy"))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
        }

        @Test(.timeLimit(.minutes(1)))
        func `A command runs where its approval said, even if the project root changes`() async throws {
            let first = try makeRoot()
            let second = try makeRoot()
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            let (service, permissionService) = makeService(root: first)

            let run = Task {
                await service.executeToolCall(toolName: "run_command", arguments: ["command": "pwd"], conversationId: UUID())
            }
            let pending = try #require(await waitForPending(permissionService))
            #expect(pending.details.contains(first.resolvingSymlinksInPath().path))
            var settings = AgentSettings.default
            settings.projectRootPath = second.path
            service.apply(settings)
            permissionService.approve(pending.id)

            #expect(await run.value.contains(first.resolvingSymlinksInPath().path))
        }

        @Test(.timeLimit(.minutes(1)))
        func `Allow All approves every pending request in the conversation only`() async throws {
            let permissionService = PermissionService()
            let conversation = UUID()
            let other = UUID()
            let first = Task { await permissionService.requestApproval(toolName: "run_command", description: "a", details: "a", conversationId: conversation) }
            let second = Task { await permissionService.requestApproval(toolName: "write_file", description: "b", details: "b", conversationId: conversation) }
            let unrelated = Task { await permissionService.requestApproval(toolName: "run_command", description: "c", details: "c", conversationId: other) }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while permissionService.pendingApprovals.count < 3, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }

            permissionService.approveAllPending(forConversation: conversation)

            #expect(await first.value)
            #expect(await second.value)
            #expect(permissionService.pendingApprovals.map(\.conversationId) == [other])
            try permissionService.deny(#require(permissionService.pendingApprovals.first).id)
            #expect(await unrelated.value == false)
        }

        @Test
        func `AIService applies AgentSettingsStore synchronously on initialization`() throws {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            var configured = AgentSettings.default
            configured.isEnabled = false
            configured.commandTimeoutSeconds = 90
            configured.approvalTimeoutSeconds = 60
            configured.persistApprovals = true
            configured.requireApprovalOutsideProject = false
            configured.projectRootPath = root.path
            configured.setPermissionLevel(.denied, for: "read_file")
            configured.setPermissionLevel(.denied, for: WebFetchService.toolName)

            let webFetchService = WebFetchService()
            let store = AgentSettingsStore(
                initialSettings: configured,
                webFetchService: webFetchService
            )

            let aiService = AIService(
                agentSettingsStore: store,
                webFetchService: webFetchService
            )

            let builtinService = try #require(aiService.builtinToolService)
            let permissionService = try #require(aiService.permissionService)

            #expect(builtinService.isEnabled == false)
            #expect(builtinService.commandTimeoutSeconds == 90)
            #expect(builtinService.requireApprovalOutsideProject == false)
            #expect(builtinService.projectRoot?.path == root.path)
            #expect(builtinService.toolPermissions["read_file"] == .denied)
            #expect(permissionService.approvalTimeoutSeconds == 60)
            #expect(permissionService.persistApprovalsAcrossSessions == true)
            #expect(webFetchService.isEnabled == false)
            #expect(webFetchService.timeoutSeconds == 90)
        }

        @Test
        func `Updating AgentSettingsStore propagates immediately to attached services`() throws {
            var initial = AgentSettings.default
            initial.isEnabled = false
            initial.commandTimeoutSeconds = 45
            initial.approvalTimeoutSeconds = 120
            initial.persistApprovals = false

            let webFetchService = WebFetchService()
            let store = AgentSettingsStore(
                initialSettings: initial,
                webFetchService: webFetchService
            )
            let aiService = AIService(
                agentSettingsStore: store,
                webFetchService: webFetchService
            )
            let builtinService = try #require(aiService.builtinToolService)
            let permissionService = try #require(aiService.permissionService)

            #expect(builtinService.isEnabled == false)
            #expect(webFetchService.isEnabled == false)

            var updated = initial
            updated.isEnabled = true
            updated.commandTimeoutSeconds = 15
            updated.approvalTimeoutSeconds = 900
            updated.persistApprovals = true
            updated.setPermissionLevel(.automatic, for: WebFetchService.toolName)
            store.settings = updated

            #expect(builtinService.isEnabled == true)
            #expect(builtinService.commandTimeoutSeconds == 15)
            #expect(permissionService.approvalTimeoutSeconds == 900)
            #expect(permissionService.persistApprovalsAcrossSessions == true)
            #expect(webFetchService.isEnabled == true)
            #expect(webFetchService.timeoutSeconds == 15)
        }

        @Test
        func `AgentSettingsStore applies settings immediately when initialized with services`() {
            var configured = AgentSettings.default
            configured.isEnabled = false
            configured.commandTimeoutSeconds = 75
            configured.approvalTimeoutSeconds = 0
            configured.persistApprovals = true

            let permissionService = PermissionService()
            let builtinService = BuiltinToolService(permissionService: permissionService)
            let webFetchService = WebFetchService()

            _ = AgentSettingsStore(
                initialSettings: configured,
                builtinToolService: builtinService,
                permissionService: permissionService,
                webFetchService: webFetchService
            )

            #expect(builtinService.isEnabled == false)
            #expect(builtinService.commandTimeoutSeconds == 75)
            #expect(permissionService.approvalTimeoutSeconds == 0)
            #expect(permissionService.persistApprovalsAcrossSessions == true)
            #expect(webFetchService.isEnabled == false)
            #expect(webFetchService.timeoutSeconds == 75)
        }
    }
#endif

@Suite("MCP tool naming")
struct MCPToolNamingTests {
    private func tool(_ name: String, server: String) -> MCPTool {
        MCPTool(name: name, description: "", inputSchema: JSONSchema(type: "object", properties: nil, required: nil, items: nil), serverName: server)
    }

    @Test
    func `Unique names are kept and only clashes get a server prefix`() {
        var naming = MCPToolNaming()
        let unique = tool("lookup", server: "docs")
        let builtinClash = tool("read_file", server: "fs")
        let sharedA = tool("search", server: "alpha")
        let sharedB = tool("search", server: "beta server")

        let names = naming.assign([unique, builtinClash, sharedA, sharedB], reserved: ["read_file", "web_search"])

        #expect(names[unique.id] == "lookup")
        #expect(names[builtinClash.id] == "fs__read_file")
        #expect(names[sharedA.id] == "alpha__search")
        #expect(names[sharedB.id] == "beta_server__search")
    }

    @Test
    func `An alias never moves to another server`() {
        var naming = MCPToolNaming()
        let first = tool("read_file", server: "a b")
        let second = tool("read_file", server: "a_b")
        let both = naming.assign([first, second], reserved: ["read_file"])
        #expect(both[first.id] == "a_b__read_file")
        #expect(both[second.id] == "a_b__read_file_2")

        let rediscovered = tool("read_file", server: "a_b")
        let afterDisconnect = naming.assign([rediscovered], reserved: ["read_file"])
        #expect(afterDisconnect[rediscovered.id] == "a_b__read_file_2")
    }

    @Test
    func `Names function-calling APIs would reject are aliased`() {
        var naming = MCPToolNaming()
        let dotted = tool("docs.search", server: "kb")
        let long = tool(String(repeating: "x", count: 70), server: "kb")

        let names = naming.assign([dotted, long], reserved: [])

        #expect(names[dotted.id] == "kb__docs_search")
        #expect(names[long.id].map { MCPToolNaming.isValidFunctionName($0) } == true)
    }

    @Test
    func `A newcomer with a taken name is prefixed and the original keeps it`() {
        var naming = MCPToolNaming()
        let original = tool("search", server: "alpha")
        _ = naming.assign([original], reserved: [])

        let newcomer = tool("search", server: "beta")
        let names = naming.assign([tool("search", server: "alpha"), newcomer], reserved: [])

        #expect(names.values.contains("search"))
        #expect(names[newcomer.id] == "beta__search")
    }
}

// swiftlint:enable identifier_name
