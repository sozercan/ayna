#if os(macOS)
    @testable import Ayna
    import Foundation
    import Testing

    @Suite("ProjectContextService Tests")
    @MainActor
    struct ProjectContextServiceTests {
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

        @Suite("Detection")
        @MainActor
        struct DetectionTests {
            @Test("Detect Swift package project from nested directory")
            func detectSwiftPackageProjectFromNestedDirectory() async throws {
                let root = try TestHelpers.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }

                let packageFile = root.appendingPathComponent("Package.swift")
                let sourcesDir = root.appendingPathComponent("Sources/FixtureApp", isDirectory: true)
                try "// swift-tools-version: 6.0".write(to: packageFile, atomically: true, encoding: .utf8)
                try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

                let sut = ProjectContextService()
                await sut.detectProject(from: sourcesDir)

                #expect(sut.projectRoot?.standardized == root.standardized)
                #expect(sut.projectType == .swiftPackage)
                #expect(sut.briefSummary()?.contains(root.lastPathComponent) == true)
            }

            @Test("Detect project finds and loads context files")
            func detectProjectFindsContextFiles() async throws {
                let root = try TestHelpers.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }

                let packageFile = root.appendingPathComponent("Package.swift")
                let agentsFile = root.appendingPathComponent("AGENTS.md")
                try "// swift-tools-version: 6.0".write(to: packageFile, atomically: true, encoding: .utf8)
                try "Project fixture instructions".write(to: agentsFile, atomically: true, encoding: .utf8)

                let sut = ProjectContextService()
                await sut.detectProject(from: root)

                #expect(sut.projectRoot?.standardized == root.standardized)
                #expect(sut.projectType == .swift)
                #expect(sut.contextFiles.map(\.lastPathComponent) == ["AGENTS.md"])
                #expect(sut.contextContent?.contains("Project fixture instructions") == true)
                #expect(sut.systemPromptContext()?.contains("Project fixture instructions") == true)
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
