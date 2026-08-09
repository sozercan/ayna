//
//  ProjectManager.swift
//  Ayna
//
//  Created on 3/7/26.
//

import Foundation
import Observation
import os.log

@Observable @MainActor
final class ProjectManager {
    enum DeletionBehavior {
        case unassignConversations
        case deleteProjectAndConversations
    }

    var projects: [Project] = []
    var selectedProjectId: UUID?

    private let store: ProjectStore
    private let persistenceCoordinator: ProjectPersistenceCoordinator
    private let conversationManager: ConversationManager
    var loadingTask: Task<Void, Never>?
    private var isLoaded = false

    init(
        conversationManager: ConversationManager,
        store: ProjectStore? = nil,
        saveDebounceDuration: Duration = .milliseconds(200)
    ) {
        let effectiveStore = store ?? .shared
        self.store = effectiveStore
        self.conversationManager = conversationManager
        persistenceCoordinator = ProjectPersistenceCoordinator(
            store: effectiveStore,
            debounceDuration: saveDebounceDuration
        )
        loadingTask = Task {
            await loadProjects()
        }
    }

    private func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.conversationManager, level: level, message: message, metadata: metadata)
    }

    @discardableResult
    func createProject(
        title: String,
        workspaceRoot: String,
        defaultModel: String? = nil
    ) -> Project {
        let canonicalRoot = Self.canonicalWorkspaceRoot(workspaceRoot)
        let now = Date()
        let project = Project(
            title: title,
            workspaceRoot: canonicalRoot,
            defaultModel: defaultModel,
            createdAt: now,
            updatedAt: now
        )

        projects.append(project)
        selectedProjectId = project.id
        persist(project)
        sortProjectsByTimestamp()

        log(
            "📁 Created project",
            level: .info,
            metadata: ["projectId": project.id.uuidString, "workspaceRoot": canonicalRoot]
        )

        return project
    }

    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            return
        }

        var updatedProject = project
        updatedProject.workspaceRoot = Self.canonicalWorkspaceRoot(project.workspaceRoot)
        updatedProject.updatedAt = Date()
        projects[index] = updatedProject
        persist(updatedProject)
        sortProjectsByTimestamp()
    }

    func deleteProject(
        _ project: Project,
        behavior: DeletionBehavior = .unassignConversations
    ) {
        let projectConversations = conversationsForProject(project.id)

        switch behavior {
        case .unassignConversations:
            for conversation in projectConversations {
                var updatedConversation = conversation
                updatedConversation.projectId = nil
                updatedConversation.updatedAt = Date()
                conversationManager.updateConversation(updatedConversation)
            }
        case .deleteProjectAndConversations:
            for conversation in projectConversations {
                conversationManager.deleteConversation(conversation)
            }
        }

        removeProjectFromMemory(project.id)
        Task {
            do {
                try await persistenceCoordinator.delete(project.id)
            } catch {
                log(
                    "❌ Failed to delete project",
                    level: .error,
                    metadata: ["projectId": project.id.uuidString, "error": error.localizedDescription]
                )
            }
        }
    }

    func project(byId id: UUID) -> Project? {
        projects.first(where: { $0.id == id })
    }

    func project(forWorkspaceRoot workspaceRoot: String) -> Project? {
        let canonicalRoot = Self.canonicalWorkspaceRoot(workspaceRoot)
        return projects.first { Self.canonicalWorkspaceRoot($0.workspaceRoot) == canonicalRoot }
    }

    func conversationsForProject(_ projectId: UUID) -> [Conversation] {
        conversationManager.conversations
            .filter { $0.projectId == projectId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func flushPendingSaves() async {
        await persistenceCoordinator.flushPendingSaves()
    }

    private func persist(_ project: Project) {
        Task {
            if !isLoaded {
                _ = await loadingTask?.value
            }
            await persistenceCoordinator.enqueueSave(project)
        }
    }

    private func loadProjects() async {
        do {
            let loadedProjects = try await store.loadProjects()
            let reconciledProjects = reconcileProjectsWithDisk(loadedProjects)
            projects = reconciledProjects

            if let selectedProjectId,
               !reconciledProjects.contains(where: { $0.id == selectedProjectId })
            {
                self.selectedProjectId = nil
            }

            isLoaded = true

            log(
                "✅ Loaded projects",
                level: .info,
                metadata: ["count": "\(reconciledProjects.count)"]
            )
        } catch {
            isLoaded = true
            log(
                "❌ Failed to load projects",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func removeProjectFromMemory(_ projectId: UUID) {
        projects.removeAll { $0.id == projectId }
        if selectedProjectId == projectId {
            selectedProjectId = nil
        }
    }

    private func reconcileProjectsWithDisk(_ loadedProjects: [Project]) -> [Project] {
        let memoryById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let diskById = Dictionary(loadedProjects.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })

        var reconciled: [Project] = []
        reconciled.reserveCapacity(max(memoryById.count, diskById.count))

        for diskProject in loadedProjects {
            if let memoryProject = memoryById[diskProject.id], memoryProject.updatedAt >= diskProject.updatedAt {
                reconciled.append(memoryProject)
            } else {
                reconciled.append(diskProject)
            }
        }

        for memoryProject in projects where diskById[memoryProject.id] == nil {
            reconciled.append(memoryProject)
        }

        return reconciled.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func sortProjectsByTimestamp() {
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private static func canonicalWorkspaceRoot(_ workspaceRoot: String) -> String {
        URL(fileURLWithPath: workspaceRoot)
            .resolvingSymlinksInPath()
            .standardized.path
    }
}

extension ProjectManager: ObservableObject {}

private actor ProjectPersistenceCoordinator {
    private var pendingSaves: [UUID: Project] = [:]
    private var activeSaveTasks: [UUID: Task<Void, Never>] = [:]
    private let store: ProjectStore
    private let debounceDuration: Duration

    init(store: ProjectStore, debounceDuration: Duration) {
        self.store = store
        self.debounceDuration = debounceDuration
    }

    func enqueueSave(_ project: Project) {
        pendingSaves[project.id] = project
        activeSaveTasks[project.id]?.cancel()
        activeSaveTasks[project.id] = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await performSave()
        }
    }

    func delete(_ projectId: UUID) async throws {
        activeSaveTasks[projectId]?.cancel()
        activeSaveTasks.removeValue(forKey: projectId)
        pendingSaves.removeValue(forKey: projectId)
        try await store.delete(projectId)
    }

    func flushPendingSaves() async {
        for task in activeSaveTasks.values {
            task.cancel()
        }
        activeSaveTasks.removeAll()

        let projectsToSave = pendingSaves
        pendingSaves.removeAll()

        for project in projectsToSave.values {
            try? await store.save(project)
        }
    }

    private func performSave() async {
        let projectsToSave = pendingSaves
        pendingSaves.removeAll()

        guard !Task.isCancelled else {
            for (id, project) in projectsToSave where pendingSaves[id] == nil {
                pendingSaves[id] = project
            }
            return
        }

        let persistenceStore = store
        await withTaskGroup(of: Void.self) { group in
            for project in projectsToSave.values {
                group.addTask {
                    do {
                        try await persistenceStore.save(project)
                    } catch {
                        DiagnosticsLogger.log(
                            .conversationManager,
                            level: .error,
                            message: "❌ Failed to save project",
                            metadata: [
                                "projectId": project.id.uuidString,
                                "error": error.localizedDescription
                            ]
                        )
                    }
                }
            }

            await group.waitForAll()
        }
    }
}
