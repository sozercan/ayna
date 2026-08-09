@testable import Ayna
import Foundation
import Testing

@Suite("ProjectManager Tests", .tags(.viewModel, .persistence))
@MainActor
struct ProjectManagerTests {
    private var defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: "ProjectManagerTests") else {
            fatalError("Failed to create UserDefaults suite for ProjectManagerTests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "ProjectManagerTests")
        defaults.synchronize()
        AppPreferences.use(defaults)
        AIService.keychain = InMemoryKeychainStorage()
    }

    private func makeManagers() throws -> (
        conversationManager: ConversationManager,
        projectManager: ProjectManager
    ) {
        let conversationDirectory = try TestHelpers.makeTemporaryDirectory()
        let projectDirectory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()

        let conversationStore = TestHelpers.makeTestStore(
            directory: conversationDirectory,
            keyIdentifier: UUID().uuidString,
            keychain: keychain
        )
        let projectStore = TestHelpers.makeTestProjectStore(
            directory: projectDirectory,
            keyIdentifier: UUID().uuidString,
            keychain: keychain
        )

        let conversationManager = ConversationManager(
            store: conversationStore,
            saveDebounceDuration: .milliseconds(0)
        )
        let projectManager = ProjectManager(
            conversationManager: conversationManager,
            store: projectStore,
            saveDebounceDuration: .milliseconds(0)
        )

        return (conversationManager, projectManager)
    }

    @Test("Create update and delete projects")
    func createUpdateDeleteProjects() async throws {
        let (conversationManager, projectManager) = try makeManagers()
        _ = await conversationManager.loadingTask?.value
        _ = await projectManager.loadingTask?.value

        let project = projectManager.createProject(
            title: "Ayna",
            workspaceRoot: "/tmp/ayna",
            defaultModel: "gpt-4o"
        )

        #expect(projectManager.projects.count == 1)
        #expect(projectManager.selectedProjectId == project.id)

        var renamed = try #require(projectManager.project(byId: project.id))
        renamed.title = "Renamed"
        projectManager.updateProject(renamed)

        #expect(projectManager.project(byId: project.id)?.title == "Renamed")

        projectManager.deleteProject(renamed)

        #expect(projectManager.projects.isEmpty)
        #expect(projectManager.selectedProjectId == nil)
    }

    @Test("conversationsForProject filters by projectId")
    func conversationsForProjectFiltersByProjectId() async throws {
        let (conversationManager, projectManager) = try makeManagers()
        _ = await conversationManager.loadingTask?.value
        _ = await projectManager.loadingTask?.value

        let project = projectManager.createProject(
            title: "Ayna",
            workspaceRoot: "/tmp/ayna"
        )
        let matchingConversation = conversationManager.createNewConversation(
            title: "Scoped",
            projectId: project.id
        )
        _ = conversationManager.createNewConversation(title: "Unassigned")

        let filtered = projectManager.conversationsForProject(project.id)

        #expect(filtered.count == 1)
        #expect(filtered.first?.id == matchingConversation.id)
    }

    @Test("create project during initial load stays visible")
    func createProjectDuringInitialLoadStaysVisible() async throws {
        let conversationDirectory = try TestHelpers.makeTemporaryDirectory()
        let projectDirectory = try TestHelpers.makeTemporaryDirectory()
        let conversationStore = TestHelpers.makeTestStore(directory: conversationDirectory)
        let slowKeychain = SlowKeychainStorage(delay: 0.2)
        let projectStore = ProjectStore(
            directoryURL: projectDirectory,
            keyIdentifier: UUID().uuidString,
            keychain: slowKeychain
        )

        let conversationManager = ConversationManager(
            store: conversationStore,
            saveDebounceDuration: .milliseconds(0)
        )
        let projectManager = ProjectManager(
            conversationManager: conversationManager,
            store: projectStore,
            saveDebounceDuration: .milliseconds(0)
        )

        let createdProject = projectManager.createProject(
            title: "During Load",
            workspaceRoot: "/tmp/during-load",
            defaultModel: "gpt-4o"
        )

        _ = await projectManager.loadingTask?.value

        #expect(projectManager.projects.contains(where: { $0.id == createdProject.id }))
        #expect(projectManager.selectedProjectId == createdProject.id)
    }
}

private final class SlowKeychainStorage: KeychainStoring, @unchecked Sendable {
    private let base = InMemoryKeychainStorage()
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func setString(_ value: String, for key: String) throws {
        try base.setString(value, for: key)
    }

    func string(for key: String) throws -> String? {
        Thread.sleep(forTimeInterval: delay)
        return try base.string(for: key)
    }

    func setData(_ data: Data, for key: String) throws {
        try base.setData(data, for: key)
    }

    func data(for key: String) throws -> Data? {
        Thread.sleep(forTimeInterval: delay)
        return try base.data(for: key)
    }

    func removeValue(for key: String) throws {
        try base.removeValue(for: key)
    }
}
