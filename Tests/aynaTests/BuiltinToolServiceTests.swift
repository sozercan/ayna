//
//  BuiltinToolServiceTests.swift
//  aynaTests
//
//  Unit tests for BuiltinToolService.
//

#if os(macOS)
    @testable import Ayna
    import Foundation
    import Testing

    @Suite("BuiltinToolService Tests")
    @MainActor
    struct BuiltinToolServiceTests {
        // MARK: - Tool Name Detection

        @Suite("Tool Name Detection")
        @MainActor
        struct ToolNameDetectionTests {
            @Test("Identifies builtin file tools")
            func identifiesFileTools() {
                #expect(BuiltinToolService.isBuiltinTool("read_file"))
                #expect(BuiltinToolService.isBuiltinTool("write_file"))
                #expect(BuiltinToolService.isBuiltinTool("edit_file"))
                #expect(BuiltinToolService.isBuiltinTool("list_directory"))
                #expect(BuiltinToolService.isBuiltinTool("search_files"))
            }

            @Test("Identifies run_command as builtin")
            func identifiesRunCommand() {
                #expect(BuiltinToolService.isBuiltinTool("run_command"))
            }

            @Test("Does not identify non-builtin tools")
            func doesNotIdentifyNonBuiltin() {
                #expect(!BuiltinToolService.isBuiltinTool("custom_tool"))
                #expect(!BuiltinToolService.isBuiltinTool("mcp_tool"))
                #expect(!BuiltinToolService.isBuiltinTool("web_fetch")) // web_fetch handled separately
                #expect(!BuiltinToolService.isBuiltinTool(""))
            }
        }

        // MARK: - Tool Definitions

        @Suite("Tool Definitions")
        @MainActor
        struct ToolDefinitionTests {
            @Test("All tool definitions have required fields")
            func allDefinitionsHaveRequiredFields() {
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

            @Test("Tool definitions include all expected tools")
            func definitionsIncludeExpectedTools() {
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
            }

            @Test("Tool count is 6")
            func toolCountIs6() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)
                let definitions = sut.allToolDefinitions()

                #expect(definitions.count == 6)
            }
        }

        // MARK: - Service Configuration

        @Suite("Service Configuration")
        @MainActor
        struct ServiceConfigurationTests {
            @Test("Default timeout is 30 seconds")
            func defaultTimeout() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.commandTimeoutSeconds == 30)
            }

            @Test("Timeout is configurable")
            func timeoutConfigurable() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                sut.commandTimeoutSeconds = 60
                #expect(sut.commandTimeoutSeconds == 60)
            }

            @Test("Default max read size is 10MB")
            func defaultMaxReadSize() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.maxReadSize == 10 * 1024 * 1024)
            }

            @Test("Service can be disabled")
            func serviceCanBeDisabled() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.isEnabled)

                sut.isEnabled = false
                #expect(!sut.isEnabled)
            }

            @Test("Project root is stored")
            func projectRootStored() {
                let permissionService = PermissionService()
                let projectRoot = URL(fileURLWithPath: "/tmp/test-project")
                let sut = BuiltinToolService(
                    permissionService: permissionService,
                    projectRoot: projectRoot
                )

                #expect(sut.projectRoot == projectRoot)
            }

            @Test("Project root is nil by default")
            func projectRootNilByDefault() {
                let permissionService = PermissionService()
                let sut = BuiltinToolService(permissionService: permissionService)

                #expect(sut.projectRoot == nil)
            }
        }

        // MARK: - Tool Name Constants

        @Suite("Tool Name Constants")
        struct ToolNameConstantsTests {
            @Test("Tool names are correct")
            func toolNamesCorrect() {
                #expect(BuiltinToolService.ToolName.readFile == "read_file")
                #expect(BuiltinToolService.ToolName.writeFile == "write_file")
                #expect(BuiltinToolService.ToolName.editFile == "edit_file")
                #expect(BuiltinToolService.ToolName.listDirectory == "list_directory")
                #expect(BuiltinToolService.ToolName.searchFiles == "search_files")
                #expect(BuiltinToolService.ToolName.runCommand == "run_command")
                #expect(BuiltinToolService.ToolName.webFetch == "web_fetch")
            }
        }
    }
#endif
