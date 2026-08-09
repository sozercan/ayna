@testable import Ayna
import Foundation
import Testing

@Suite("ProjectStore Tests", .tags(.persistence, .slow))
struct ProjectStoreTests {
    @Test("Save load and delete round trips projects")
    func saveLoadDeleteRoundTrip() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestProjectStore(directory: directory)
        let project = TestHelpers.sampleProject()

        try await store.save(project)

        let loaded = try await store.loadProjects()
        #expect(loaded == [project])

        try await store.delete(project.id)
        let afterDelete = try await store.loadProjects()
        #expect(afterDelete.isEmpty)
    }

    @Test("Second store instance loads data using shared encryption key")
    func secondStoreInstanceLoadsDataUsingSameKey() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyIdentifier = UUID().uuidString
        let project = TestHelpers.sampleProject(title: "Persisted Project")

        let firstStore = ProjectStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        try await firstStore.save(project)

        let secondStore = ProjectStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )
        let loaded = try await secondStore.loadProjects()

        #expect(loaded.first?.title == "Persisted Project")
    }
}
