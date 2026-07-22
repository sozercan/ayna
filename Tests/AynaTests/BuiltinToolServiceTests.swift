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
