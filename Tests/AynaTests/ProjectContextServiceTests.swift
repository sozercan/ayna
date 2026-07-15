@testable import Ayna
import Foundation
import Testing

@Suite("ProjectContextService Tests", .tags(.fast, .persistence))
@MainActor
struct ProjectContextServiceTests {
    @Test("Detect project refreshes cached context after file changes")
    func detectProjectRefreshesCachedContextAfterFileChanges() async throws {
        let projectRoot = try TestHelpers.makeTemporaryDirectory()
        let gitDirectory = projectRoot.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)

        let agentsURL = projectRoot.appendingPathComponent("AGENTS.md")
        try "Initial instructions".write(to: agentsURL, atomically: true, encoding: .utf8)

        let service = ProjectContextService()

        await service.detectProject(from: projectRoot)
        let initialContext = try #require(service.systemPromptContext())
        #expect(initialContext.contains("Initial instructions"))

        try "Updated instructions with new content".write(
            to: agentsURL,
            atomically: true,
            encoding: .utf8
        )

        await service.detectProject(from: projectRoot)
        let updatedContext = try #require(service.systemPromptContext())

        #expect(updatedContext.contains("Updated instructions with new content"))
        #expect(!updatedContext.contains("Initial instructions"))
    }
}
