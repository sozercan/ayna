@testable import Ayna
import Foundation
import Testing

@Suite("Project Tests", .tags(.fast))
struct ProjectTests {
    @Test("Encode and decode preserves project fields")
    func encodeDecodeRoundTrip() throws {
        let project = Project(
            id: UUID(),
            title: "Ayna",
            workspaceRoot: "/tmp/ayna",
            defaultModel: "gpt-4o",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)

        #expect(decoded == project)
    }

    @Test("Decode succeeds when defaultModel is missing")
    func decodeWithoutDefaultModel() throws {
        let json = """
        {
          "id": "\(UUID())",
          "title": "Ayna",
          "workspaceRoot": "/tmp/ayna",
          "createdAt": 1000,
          "updatedAt": 2000
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let project = try decoder.decode(Project.self, from: Data(json.utf8))

        #expect(project.defaultModel == nil)
        #expect(project.title == "Ayna")
    }
}
