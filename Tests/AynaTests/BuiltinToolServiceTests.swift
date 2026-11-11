//
//  BuiltinToolServiceTests.swift
//  aynaTests
//
//  Unit tests for BuiltinToolService.
//

#if os(macOS)
    // swiftlint:disable identifier_name
    @testable import Ayna
    import Darwin
    import Foundation
    import Testing

    @Suite("BuiltinToolService Tests")
    @MainActor
    struct BuiltinToolServiceTests {
        // MARK: - Tool Name Detection

        @Suite("Tool Name Detection")
        @MainActor
        struct ToolNameDetectionTests {
            @Test
            func `Identifies builtin file tools`() {
                #expect(BuiltinToolService.isBuiltinTool("read_file"))
                #expect(BuiltinToolService.isBuiltinTool("write_file"))
                #expect(BuiltinToolService.isBuiltinTool("edit_file"))
                #expect(BuiltinToolService.isBuiltinTool("list_directory"))
                #expect(BuiltinToolService.isBuiltinTool("search_files"))
            }

            @Test
            func `Identifies run_command as builtin`() {
                #expect(BuiltinToolService.isBuiltinTool("run_command"))
            }

            @Test
            func `Does not identify non-builtin tools`() {
                #expect(!BuiltinToolService.isBuiltinTool("custom_tool"))
                #expect(!BuiltinToolService.isBuiltinTool("mcp_tool"))
                #expect(!BuiltinToolService.isBuiltinTool(""))
            }
        }

        // MARK: - Tool Definitions

        @Suite("Tool Definitions")
        @MainActor
        struct ToolDefinitionTests {
            @Test
            func `All tool definitions have required fields`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)
                let definitions = sut.allToolDefinitions()

                #expect(!definitions.isEmpty)

                for definition in definitions {
                    // Each definition should have type and function
                    #expect(definition["type"] as? String == "function")

                    let function = definition["function"] as? [String: Any]
                    #expect(function != nil)

                    // Function should have name, description, parameters
                    #expect(function?["name"] is String)
                    #expect(function?["description"] is String)
                    #expect(function?["parameters"] is [String: Any])
                }
            }

            @Test
            func `Tool definitions include all expected tools`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)
                let definitions = sut.allToolDefinitions()

                let toolNames = definitions.compactMap { def -> String? in
                    let function = def["function"] as? [String: Any]
                    return function?["name"] as? String
                }

                #expect(toolNames.contains("read_file"))
                #expect(toolNames.contains("write_file"))
                #expect(toolNames.contains("edit_file"))
                #expect(toolNames.contains("list_directory"))
                #expect(toolNames.contains("search_files"))
                #expect(toolNames.contains("run_command"))
                #expect(toolNames.contains("web_fetch"))
            }

            @Test
            func `Tool count is 7`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)
                let definitions = sut.allToolDefinitions()

                #expect(definitions.count == 7)
            }
        }

        // MARK: - Service Configuration

        @Suite("Service Configuration")
        @MainActor
        struct ServiceConfigurationTests {
            @Test
            func `Default timeout is 30 seconds`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.commandTimeoutSeconds == 30)
            }

            @Test
            func `Timeout is configurable`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                sut.commandTimeoutSeconds = 60
                #expect(sut.commandTimeoutSeconds == 60)
            }

            @Test
            func `Default max read size is 10MB`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.maxReadSize == 10 * 1024 * 1024)
            }

            @Test
            func `Service can be disabled`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.isEnabled)

                sut.isEnabled = false
                #expect(!sut.isEnabled)
            }

            @Test
            func `Project root is stored`() {
                let permissionService = PermissionService()
                let projectRoot = URL(fileURLWithPath: "/tmp/test-project")
                let sut = BuiltinToolService(
                    permissionService: permissionService,
                    projectRoot: projectRoot
                )

                #expect(sut.projectRoot == projectRoot)
            }

            @Test
            func `Project root is nil by default`() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.projectRoot == nil)
            }
        }

        // MARK: - Formatting and Search Performance Checks

        @Suite("Formatting and Search Performance Checks")
        @MainActor
        struct FormattingAndSearchPerformanceTests {
            @Test("File size formatting is stable across repeated calls")
            func fileSizeFormattingStableAcrossRepeatedCalls() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)
                let expected = sut.formatFileSize(1_048_576)

                let iterations = 200
                let start = Date()
                for _ in 0..<iterations {
                    #expect(sut.formatFileSize(1_048_576) == expected)
                }
                let elapsed = Date().timeIntervalSince(start)

                print("BENCH BuiltinToolService formatFileSize: \(iterations) in \(String(format: "%.4f", elapsed))s")
            }

            @Test("Search files handles bulk text tree")
            func searchFilesHandlesBulkTextTree() async throws {
                // Use /tmp explicitly; FileManager.temporaryDirectory may resolve under /var/folders,
                // which is intentionally protected by PathValidator and would require approval.
                let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }

                let fileCount = 80
                for index in 0..<fileCount {
                    let subdirectory = root.appendingPathComponent("dir\(index % 8)")
                    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

                    let containsNeedle = index % 4 == 0
                    let content = containsNeedle
                        ? "first line\nneedle match \(index)\nlast line\n"
                        : "first line\nordinary content \(index)\nlast line\n"
                    let fileURL = subdirectory.appendingPathComponent("file\(index).txt")
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                }

                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                let start = Date()
                let results = try await sut.searchFiles(pattern: "needle", path: root.path, conversationId: UUID())
                let elapsed = Date().timeIntervalSince(start)

                #expect(results.count == fileCount / 4)
                #expect(results.allSatisfy { $0.content.contains("needle") })
                print("BENCH BuiltinToolService searchFiles: \(fileCount) files in \(String(format: "%.4f", elapsed))s")
            }
        }

        // MARK: - Tool Name Constants

        @Suite("Tool Name Constants")
        struct ToolNameConstantsTests {
            @Test
            func `Tool names are correct`() {
                #expect(BuiltinToolService.ToolName.readFile == "read_file")
                #expect(BuiltinToolService.ToolName.writeFile == "write_file")
                #expect(BuiltinToolService.ToolName.editFile == "edit_file")
                #expect(BuiltinToolService.ToolName.listDirectory == "list_directory")
                #expect(BuiltinToolService.ToolName.searchFiles == "search_files")
                #expect(BuiltinToolService.ToolName.runCommand == "run_command")
                #expect(BuiltinToolService.ToolName.webFetch == "web_fetch")
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func `Cancellation before result delivery wins atomically`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolCompletion-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let command = "echo complete"
            let completionReached = FlightTestSignal()
            let releaseCompletion = FlightTestSignal()
            let permissionService = PermissionService()
            permissionService.recordSessionApproval(
                tool: BuiltinToolService.ToolName.runCommand,
                details: command
            )
            let service = BuiltinToolService(
                permissionService: permissionService,
                projectRoot: directory,
                processCompletionGate: {
                    completionReached.signal()
                    await releaseCompletion.wait()
                }
            )

            let task = Task {
                try await service.runCommand(
                    command: command,
                    workingDirectory: directory.path,
                    conversationId: UUID()
                )
            }
            #expect(await completionReached.wait(timeout: .seconds(1)))
            task.cancel()
            releaseCompletion.signal()

            do {
                _ = try await task.value
                Issue.record("Expected cancellation to win before result delivery")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func `Cancellation before process startup prevents command execution`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolCancellation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("executed.txt")
            let command = "echo executed > '\(marker.path)'"
            let gateStarted = FlightTestSignal()
            let releaseGate = FlightTestSignal()
            let permissionService = PermissionService()
            permissionService.recordSessionApproval(
                tool: BuiltinToolService.ToolName.runCommand,
                details: command
            )
            let service = BuiltinToolService(
                permissionService: permissionService,
                projectRoot: directory,
                processStartGate: {
                    gateStarted.signal()
                    await releaseGate.wait()
                }
            )

            let task = Task {
                try await service.runCommand(
                    command: command,
                    workingDirectory: directory.path,
                    conversationId: UUID()
                )
            }
            #expect(await gateStarted.wait(timeout: .seconds(1)))
            task.cancel()
            releaseGate.signal()

            do {
                _ = try await task.value
                Issue.record("Expected command startup to be cancelled")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(100))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }

        private func approveNextPending(_ permissionService: PermissionService) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while permissionService.pendingApprovals.isEmpty, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let approvalID = try #require(permissionService.pendingApprovals.first?.id)
            permissionService.approve(approvalID, rememberForSession: false)
        }

        private func waitForPendingApproval(_ permissionService: PermissionService) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while permissionService.pendingApprovals.isEmpty, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func `Approved write to an unchanged protected target succeeds`() async throws {
            // The temporary directory lives under the protected /var path, so the write
            // needs approval both before and after symlink resolution.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolApprovedWrite-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent("note.txt")
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService, projectRoot: directory)

            let task = Task {
                try await service.writeFile(path: target.path, content: "approved", conversationId: UUID())
            }
            try await approveNextPending(permissionService)
            try await task.value

            #expect(try String(contentsOf: target, encoding: .utf8) == "approved")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Write rejects a symlink retargeted while approval is pending`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolRetargetWrite-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = directory.appendingPathComponent("original.txt")
            let other = directory.appendingPathComponent("other.txt")
            let link = directory.appendingPathComponent("link.txt")
            try "original".write(to: original, atomically: true, encoding: .utf8)
            try "other".write(to: other, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService, projectRoot: directory)

            let task = Task {
                try await service.writeFile(path: link.path, content: "overwritten", conversationId: UUID())
            }
            await waitForPendingApproval(permissionService)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
            try await approveNextPending(permissionService)

            await #expect(throws: ToolExecutionError.self) { try await task.value }
            #expect(try String(contentsOf: original, encoding: .utf8) == "original")
            #expect(try String(contentsOf: other, encoding: .utf8) == "other")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Remembered write approval does not follow a retargeted symlink`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolRememberedRetarget-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = directory.appendingPathComponent("original.txt")
            let other = directory.appendingPathComponent("other.txt")
            let link = directory.appendingPathComponent("link.txt")
            try "original".write(to: original, atomically: true, encoding: .utf8)
            try "other".write(to: other, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService, projectRoot: directory)

            // First write: approve and remember for the session.
            let first = Task {
                try await service.writeFile(path: link.path, content: "first", conversationId: UUID())
            }
            await waitForPendingApproval(permissionService)
            let firstID = try #require(permissionService.pendingApprovals.first?.id)
            permissionService.approve(firstID, rememberForSession: true)
            try await first.value
            #expect(try String(contentsOf: original, encoding: .utf8) == "first")

            // Retarget the link; the remembered approval must not cover the new file.
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
            let second = Task {
                try await service.writeFile(path: link.path, content: "second", conversationId: UUID())
            }
            await waitForPendingApproval(permissionService)
            let secondApproval = try #require(permissionService.pendingApprovals.first)
            #expect(secondApproval.details == other.resolvingSymlinksInPath().standardized.path)
            permissionService.deny(secondApproval.id)

            await #expect(throws: ToolExecutionError.self) { try await second.value }
            #expect(try String(contentsOf: other, encoding: .utf8) == "other")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Edit rejects a symlink swapped away and back across approval steps`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolSwapBackEdit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = directory.appendingPathComponent("original.txt")
            let other = directory.appendingPathComponent("other.txt")
            let link = directory.appendingPathComponent("link.txt")
            try "hello original".write(to: original, atomically: true, encoding: .utf8)
            try "hello other".write(to: other, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService, projectRoot: directory)

            func retarget(to destination: URL) throws {
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            }

            let task = Task {
                try await service.editFile(path: link.path, oldText: "hello", newText: "bye", conversationId: UUID())
            }
            // Point the link at `other` while the read is pending, and back at `original`
            // before the edit approval, so only the read step sees the other file.
            var approvals = 0
            while approvals < 3 {
                await waitForPendingApproval(permissionService)
                guard let pending = permissionService.pendingApprovals.first else { break }
                if pending.toolName == BuiltinToolService.ToolName.readFile {
                    try retarget(to: other)
                } else if pending.toolName == BuiltinToolService.ToolName.editFile {
                    try retarget(to: original)
                }
                permissionService.approve(pending.id, rememberForSession: false)
                approvals += 1
                if pending.toolName == BuiltinToolService.ToolName.editFile { break }
            }

            // The path no longer points at the captured target after the read, so the edit
            // must be rejected and neither file may change.
            await #expect(throws: ToolExecutionError.self) { try await task.value }
            #expect(try String(contentsOf: original, encoding: .utf8) == "hello original")
            #expect(try String(contentsOf: other, encoding: .utf8) == "hello other")
        }

        private func approveAllUntilDone(_ permissionService: PermissionService, task: Task<Void, Error>) async throws {
            while true {
                await waitForPendingApproval(permissionService)
                guard let pending = permissionService.pendingApprovals.first else { break }
                permissionService.approve(pending.id, rememberForSession: false)
                if pending.toolName == BuiltinToolService.ToolName.editFile { break }
            }
            try await task.value
        }

        @Test(.timeLimit(.minutes(1)))
        func `Edit expands environment variables in the input path like validation does`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolEnvEdit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let note = directory.appendingPathComponent("note.txt")
            try "hello env".write(to: note, atomically: true, encoding: .utf8)
            let variable = "AYNA_TEST_EDIT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            setenv(variable, directory.path, 1)
            defer { unsetenv(variable) }
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService, projectRoot: directory)

            let task = Task {
                try await service.editFile(
                    path: "$\(variable)/note.txt",
                    oldText: "hello",
                    newText: "bye",
                    conversationId: UUID()
                )
            }
            try await approveAllUntilDone(permissionService, task: task)

            #expect(try String(contentsOf: note, encoding: .utf8) == "bye env")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Edit does not re-expand a literal dollar component in the resolved target`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolLiteralDollar-\(UUID().uuidString)")
            let unsetName = "AYNA_UNSET_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let literalDirectory = directory.appendingPathComponent("$\(unsetName)")
            try FileManager.default.createDirectory(at: literalDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let real = literalDirectory.appendingPathComponent("note.txt")
            let decoy = directory.appendingPathComponent("note.txt")
            let link = directory.appendingPathComponent("link.txt")
            try "hello real".write(to: real, atomically: true, encoding: .utf8)
            try "hello decoy".write(to: decoy, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService, projectRoot: directory)

            let task = Task {
                try await service.editFile(path: link.path, oldText: "hello", newText: "bye", conversationId: UUID())
            }
            try await approveAllUntilDone(permissionService, task: task)

            #expect(try String(contentsOf: real, encoding: .utf8) == "bye real")
            #expect(try String(contentsOf: decoy, encoding: .utf8) == "hello decoy")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Search skips sensitive files under an allowed root`() async throws {
            // /tmp is not a protected path, so the root itself needs no approval.
            let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("AynaSearchSensitive-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "needle in notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            try "needle secret".write(to: root.appendingPathComponent("credentials.json"), atomically: true, encoding: .utf8)
            try "needle key".write(to: root.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService)

            let results = try await service.searchFiles(pattern: "needle", path: root.path, conversationId: UUID())

            #expect(permissionService.pendingApprovals.isEmpty)
            #expect(Set(results.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["notes.txt"])
        }

        @Test(.timeLimit(.minutes(1)))
        func `Search includes sensitive files once the user approves a protected root`() async throws {
            // The temporary directory is under protected /var, so searching it asks first.
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AynaSearchApprovedRoot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "needle in notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            try "needle secret".write(to: root.appendingPathComponent("credentials.json"), atomically: true, encoding: .utf8)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService)

            let task = Task {
                try await service.searchFiles(pattern: "needle", path: root.path, conversationId: UUID())
            }
            try await approveNextPending(permissionService)
            let results = try await task.value

            #expect(Set(results.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["notes.txt", "credentials.json"])
        }

        @Test(.timeLimit(.minutes(1)))
        func `Edit rejects a symlink retargeted while approval is pending`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolRetargetEdit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = directory.appendingPathComponent("original.txt")
            let other = directory.appendingPathComponent("other.txt")
            let link = directory.appendingPathComponent("link.txt")
            try "hello world".write(to: original, atomically: true, encoding: .utf8)
            try "other".write(to: other, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let permissionService = PermissionService()
            let service = BuiltinToolService(permissionService: permissionService, projectRoot: directory)

            let task = Task {
                try await service.editFile(path: link.path, oldText: "hello", newText: "bye", conversationId: UUID())
            }
            // Approve every request (read, then edit) but retarget the link before the last one.
            var approvals = 0
            while approvals < 3 {
                await waitForPendingApproval(permissionService)
                guard let pending = permissionService.pendingApprovals.first else { break }
                if pending.toolName == BuiltinToolService.ToolName.editFile {
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
                }
                permissionService.approve(pending.id, rememberForSession: false)
                approvals += 1
                if pending.toolName == BuiltinToolService.ToolName.editFile { break }
            }

            await #expect(throws: ToolExecutionError.self) { try await task.value }
            #expect(try String(contentsOf: original, encoding: .utf8) == "hello world")
            #expect(try String(contentsOf: other, encoding: .utf8) == "other")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Cancellation after approval neither grants permission nor starts the command`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolApprovalCancellation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("executed.txt")
            let command = "echo executed > '\(marker.path)'"
            let gateStarted = FlightTestSignal()
            let releaseGate = FlightTestSignal()
            let permissionService = PermissionService()
            let service = BuiltinToolService(
                permissionService: permissionService,
                projectRoot: directory,
                processStartGate: {
                    gateStarted.signal()
                    await releaseGate.wait()
                }
            )

            let task = Task {
                try await service.runCommand(
                    command: command,
                    workingDirectory: directory.path,
                    conversationId: UUID()
                )
            }

            let clock = ContinuousClock()
            let approvalDeadline = clock.now.advanced(by: .seconds(1))
            while permissionService.pendingApprovals.isEmpty, clock.now < approvalDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let approvalID = try #require(permissionService.pendingApprovals.first?.id)
            permissionService.approve(approvalID, rememberForSession: false)
            #expect(await gateStarted.wait(timeout: .seconds(1)))

            task.cancel()
            releaseGate.signal()

            do {
                _ = try await task.value
                Issue.record("Expected cancellation before process startup")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(permissionService.checkPermission(
                tool: BuiltinToolService.ToolName.runCommand,
                details: command,
                defaultLevel: .askOnce
            ) == .askOnce)
        }

        @Test(.timeLimit(.minutes(1)))
        func `Cancellation force-kills a command that ignores SIGTERM`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolForceKill-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let pidFile = directory.appendingPathComponent("command.pid")
            let command = "echo $$ > '\(pidFile.path)'; trap '' TERM; while :; do :; done"
            let permissionService = PermissionService()
            permissionService.recordSessionApproval(
                tool: BuiltinToolService.ToolName.runCommand,
                details: command
            )
            let service = BuiltinToolService(
                permissionService: permissionService,
                projectRoot: directory
            )
            service.commandTimeoutSeconds = 30

            let commandTask = Task {
                try await service.runCommand(
                    command: command,
                    workingDirectory: directory.path,
                    conversationId: UUID()
                )
            }

            let clock = ContinuousClock()
            let startDeadline = clock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: pidFile.path), clock.now < startDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let processIdentifier = try #require(pid_t(pidText))

            let outcome = FlightTestBox<String?>(nil)
            let finished = FlightTestSignal()
            let waiter = Task {
                defer { finished.signal() }
                do {
                    _ = try await commandTask.value
                    outcome.value = "completed"
                } catch is CancellationError {
                    outcome.value = "cancelled"
                } catch {
                    outcome.value = "error: \(error.localizedDescription)"
                }
            }

            commandTask.cancel()
            let completedPromptly = await finished.wait(timeout: .seconds(2))
            if !completedPromptly {
                // Keep the pre-fix regression deterministic instead of leaking the child process.
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
            _ = await waiter.result

            #expect(completedPromptly)
            #expect(outcome.value == "cancelled")
        }

        @Test(.timeLimit(.minutes(1)))
        func `Delayed escalation cannot signal a PID reused after cancellation reaps the child`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolPIDReuse-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let pidFile = directory.appendingPathComponent("command.pid")
            let releaseFile = directory.appendingPathComponent("release-command")
            let command = "echo $$ > '\(pidFile.path)'; trap '' TERM; "
                + "while [ ! -f '\(releaseFile.path)' ]; do sleep 0.01; done"
            let completionReached = FlightTestSignal()
            let releaseCompletion = FlightTestSignal()
            let releaseEscalation = FlightTestSignal()
            let simulatePIDReuse = FlightTestBox(false)
            let staleSignalAttempts = FlightTestBox<[Int32]>([])
            let permissionService = PermissionService()
            permissionService.recordSessionApproval(
                tool: BuiltinToolService.ToolName.runCommand,
                details: command
            )
            let service = BuiltinToolService(
                permissionService: permissionService,
                projectRoot: directory,
                processCompletionGate: {
                    simulatePIDReuse.value = true
                    completionReached.signal()
                    await releaseCompletion.wait()
                },
                processEscalationGate: {
                    await releaseEscalation.wait()
                },
                subprocessSignal: { processIdentifier, signal in
                    if simulatePIDReuse.value {
                        staleSignalAttempts.update { $0.append(signal) }
                        return 0
                    }
                    return Darwin.kill(processIdentifier, signal)
                }
            )

            let commandTask = Task {
                try await service.runCommand(
                    command: command,
                    workingDirectory: directory.path,
                    conversationId: UUID()
                )
            }

            let clock = ContinuousClock()
            let startDeadline = clock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: pidFile.path), clock.now < startDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            _ = try String(contentsOf: pidFile, encoding: .utf8)

            commandTask.cancel()
            try Data().write(to: releaseFile)
            let childWasReaped = await completionReached.wait(timeout: .seconds(2))
            #expect(childWasReaped)

            releaseEscalation.signal()
            try? await Task.sleep(for: .milliseconds(100))
            #expect(staleSignalAttempts.value.isEmpty)

            releaseCompletion.signal()
            do {
                _ = try await commandTask.value
                Issue.record("Expected cancellation after child reap")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func `Background descendants cannot retain command pipes or survive completion`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BuiltinToolDescendant-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let pidFile = directory.appendingPathComponent("child.pid")
            let command = "sleep 60 & child=$!; echo $child > '\(pidFile.path)'; echo done"
            let permissionService = PermissionService()
            permissionService.recordSessionApproval(
                tool: BuiltinToolService.ToolName.runCommand,
                details: command
            )
            let service = BuiltinToolService(
                permissionService: permissionService,
                projectRoot: directory
            )

            let outcome = FlightTestBox<Result<CommandResult, Error>?>(nil)
            let finished = FlightTestSignal()
            let task = Task {
                defer { finished.signal() }
                do {
                    outcome.value = try await .success(service.runCommand(
                        command: command,
                        workingDirectory: directory.path,
                        conversationId: UUID()
                    ))
                } catch {
                    outcome.value = .failure(error)
                }
            }

            let clock = ContinuousClock()
            let pidDeadline = clock.now.advanced(by: .seconds(1))
            while !FileManager.default.fileExists(atPath: pidFile.path), clock.now < pidDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let childPIDText = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try #require(pid_t(childPIDText))

            let completedPromptly = await finished.wait(timeout: .seconds(2))
            if !completedPromptly {
                // Deterministic cleanup for the pre-fix behavior, where the pipe drain blocks.
                _ = Darwin.kill(childPID, SIGKILL)
            }
            _ = await task.result

            #expect(completedPromptly)
            if case let .success(result) = outcome.value {
                #expect(result.stdout.contains("done"))
            } else {
                Issue.record("Expected successful command completion, got \(String(describing: outcome.value))")
            }

            let exitDeadline = clock.now.advanced(by: .seconds(1))
            while Darwin.kill(childPID, 0) == 0, clock.now < exitDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
        }
    }
    // swiftlint:enable identifier_name
#endif
