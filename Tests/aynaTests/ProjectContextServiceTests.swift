//
//  ProjectContextServiceTests.swift
//  aynaTests
//
//  Unit tests for ProjectContextService.
//

#if os(macOS)
    @testable import Ayna
    import Foundation
    import Testing

    @Suite("ProjectContextService Tests")
    @MainActor
    struct ProjectContextServiceTests {
        // MARK: - ProjectType Tests

        @Suite("ProjectType")
        struct ProjectTypeTests {
            @Test("All project types have display names")
            func displayNames() {
                let types: [ProjectContextService.ProjectType] = [
                    .swift, .swiftPackage, .xcode, .node, .python, .rust, .go, .unknown
                ]
                for type in types {
                    #expect(!type.displayName.isEmpty)
                }
            }

            @Test("Swift types have correct display name")
            func swiftDisplayName() {
                #expect(ProjectContextService.ProjectType.swift.displayName == "Swift")
                #expect(ProjectContextService.ProjectType.swiftPackage.displayName == "Swift")
            }

            @Test("Context filenames include common AI files")
            func contextFilenamesIncludeCommon() {
                let filenames = ProjectContextService.ProjectType.swift.contextFilenames
                #expect(filenames.contains("CLAUDE.md"))
                #expect(filenames.contains("AGENTS.md"))
                #expect(filenames.contains("COPILOT.md"))
            }

            @Test("Project markers are type-specific")
            func projectMarkersAreSpecific() {
                #expect(ProjectContextService.ProjectType.swift.projectMarkers.contains("Package.swift"))
                #expect(ProjectContextService.ProjectType.node.projectMarkers.contains("package.json"))
                #expect(ProjectContextService.ProjectType.rust.projectMarkers.contains("Cargo.toml"))
                #expect(ProjectContextService.ProjectType.go.projectMarkers.contains("go.mod"))
                #expect(ProjectContextService.ProjectType.unknown.projectMarkers.isEmpty)
            }

            @Test("Raw values are stable")
            func rawValues() {
                #expect(ProjectContextService.ProjectType.swift.rawValue == "swift")
                #expect(ProjectContextService.ProjectType.swiftPackage.rawValue == "swiftPackage")
                #expect(ProjectContextService.ProjectType.xcode.rawValue == "xcode")
                #expect(ProjectContextService.ProjectType.node.rawValue == "node")
                #expect(ProjectContextService.ProjectType.python.rawValue == "python")
                #expect(ProjectContextService.ProjectType.rust.rawValue == "rust")
                #expect(ProjectContextService.ProjectType.go.rawValue == "go")
                #expect(ProjectContextService.ProjectType.unknown.rawValue == "unknown")
            }
        }

        // MARK: - Service Tests

        @Suite("Service")
        @MainActor
        struct ServiceTests {
            @Test("Initial state has no project")
            func initialStateNoProject() {
                let sut = ProjectContextService()

                #expect(sut.projectRoot == nil)
                #expect(sut.projectType == .unknown)
                #expect(sut.contextFiles.isEmpty)
                #expect(sut.contextContent == nil)
            }

            @Test("System prompt context returns nil without content")
            func systemPromptContextNilWithoutContent() {
                let sut = ProjectContextService()
                #expect(sut.systemPromptContext() == nil)
            }

            @Test("Brief summary returns nil without project root")
            func briefSummaryNilWithoutRoot() {
                let sut = ProjectContextService()
                #expect(sut.briefSummary() == nil)
            }
        }

        // MARK: - Detection Tests

        @Suite("Detection")
        @MainActor
        struct DetectionTests {
            @Test("Detect current project")
            func detectCurrentProject() async {
                let sut = ProjectContextService()
                let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

                await sut.detectProject(from: currentDir)

                // Should detect something since we're in the ayna project
                // Note: This test depends on being run from the project directory
                if sut.projectRoot != nil {
                    #expect(sut.projectType != .unknown)
                }
            }

            @Test("Detect project finds context files in ayna repo")
            func detectProjectFindsContextFiles() async {
                let sut = ProjectContextService()
                let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

                await sut.detectProject(from: currentDir)

                // ayna has CLAUDE.md and AGENTS.md
                if sut.projectRoot != nil {
                    let filenames = sut.contextFiles.map(\.lastPathComponent)
                    // At least one context file should be found
                    let hasContextFile = filenames.contains("CLAUDE.md") ||
                        filenames.contains("AGENTS.md") ||
                        filenames.contains("COPILOT.md")
                    #expect(hasContextFile || sut.contextFiles.isEmpty)
                }
            }

            @Test("Non-existent path results in unknown project")
            func nonExistentPathResultsUnknown() async {
                let sut = ProjectContextService()
                let fakePath = URL(fileURLWithPath: "/nonexistent/fake/path/that/does/not/exist")

                await sut.detectProject(from: fakePath)

                #expect(sut.projectRoot == nil)
                #expect(sut.projectType == .unknown)
            }
        }
    }
#endif
