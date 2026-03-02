//
//  ConversationTask.swift
//  Ayna
//
//  Model for tracking tasks within a conversation.
//  Used by the update_tasks tool for agentic task management.
//

import Foundation

/// Status of a conversation task
enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case blocked

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        case .failed: "Failed"
        case .blocked: "Blocked"
        }
    }

    var iconName: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.inset.filled"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .blocked: "exclamationmark.circle.fill"
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

/// A task within a conversation
struct ConversationTask: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var content: String
    var status: TaskStatus
    var createdAt: Date
    var updatedAt: Date
    var parentId: UUID? // For nested tasks
    var notes: String? // Optional notes/blockers

    init(
        id: UUID = UUID(),
        content: String,
        status: TaskStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        parentId: UUID? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.content = content
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentId = parentId
        self.notes = notes
    }

    /// Updates the status and records the time
    mutating func updateStatus(_ newStatus: TaskStatus) {
        status = newStatus
        updatedAt = Date()
    }

    /// Adds or updates notes
    mutating func setNotes(_ newNotes: String?) {
        notes = newNotes
        updatedAt = Date()
    }
}

// Manages tasks for a conversation
#if os(macOS)
    @Observable @MainActor
    final class ConversationTaskManager {
        /// Tasks indexed by conversation ID
        private(set) var tasksByConversation: [UUID: [ConversationTask]] = [:]

        /// Current conversation ID
        var currentConversationId: UUID?

        /// Tasks for the current conversation
        var currentTasks: [ConversationTask] {
            guard let id = currentConversationId else { return [] }
            return tasksByConversation[id] ?? []
        }

        /// Root tasks (no parent) for the current conversation
        var rootTasks: [ConversationTask] {
            currentTasks.filter { $0.parentId == nil }
        }

        /// Subtasks for a given parent task
        func subtasks(of parentId: UUID) -> [ConversationTask] {
            currentTasks.filter { $0.parentId == parentId }
        }

        // MARK: - Task Operations

        /// Adds a new task
        func addTask(
            _ content: String,
            status: TaskStatus = .pending,
            parentId: UUID? = nil,
            toConversation conversationId: UUID? = nil
        ) -> ConversationTask {
            let id = conversationId ?? currentConversationId ?? UUID()
            var tasks = tasksByConversation[id] ?? []

            let task = ConversationTask(
                content: content,
                status: status,
                parentId: parentId
            )
            tasks.append(task)
            tasksByConversation[id] = tasks

            logTaskChange("added", task: task)
            return task
        }

        /// Updates an existing task
        func updateTask(
            id taskId: UUID,
            content: String? = nil,
            status: TaskStatus? = nil,
            notes: String? = nil,
            inConversation conversationId: UUID? = nil
        ) {
            let id = conversationId ?? currentConversationId ?? UUID()
            guard var tasks = tasksByConversation[id],
                  let index = tasks.firstIndex(where: { $0.id == taskId })
            else {
                return
            }

            if let content {
                tasks[index].content = content
                tasks[index].updatedAt = Date()
            }
            if let status {
                tasks[index].updateStatus(status)
            }
            if let notes {
                tasks[index].setNotes(notes)
            }

            tasksByConversation[id] = tasks
            logTaskChange("updated", task: tasks[index])
        }

        /// Removes a task
        func removeTask(id taskId: UUID, inConversation conversationId: UUID? = nil) {
            let id = conversationId ?? currentConversationId ?? UUID()
            guard var tasks = tasksByConversation[id] else { return }

            if let task = tasks.first(where: { $0.id == taskId }) {
                logTaskChange("removed", task: task)
            }

            // Also remove subtasks
            let subtaskIds = tasks.filter { $0.parentId == taskId }.map(\.id)
            tasks.removeAll { $0.id == taskId || subtaskIds.contains($0.id) }
            tasksByConversation[id] = tasks
        }

        /// Clears all tasks for a conversation
        func clearTasks(forConversation conversationId: UUID? = nil) {
            let id = conversationId ?? currentConversationId ?? UUID()
            tasksByConversation[id] = []

            DiagnosticsLogger.log(
                .builtinTools,
                level: .info,
                message: "Tasks cleared",
                metadata: ["conversationId": id.uuidString]
            )
        }

        /// Replaces all tasks for a conversation (used by update_tasks tool)
        func replaceTasks(_ tasks: [ConversationTask], forConversation conversationId: UUID? = nil) {
            let id = conversationId ?? currentConversationId ?? UUID()
            tasksByConversation[id] = tasks

            DiagnosticsLogger.log(
                .builtinTools,
                level: .info,
                message: "Tasks replaced",
                metadata: [
                    "conversationId": id.uuidString,
                    "count": "\(tasks.count)"
                ]
            )
        }

        // MARK: - Statistics

        /// Returns task statistics for a conversation
        func statistics(forConversation conversationId: UUID? = nil) -> TaskStatistics {
            let id = conversationId ?? currentConversationId ?? UUID()
            let tasks = tasksByConversation[id] ?? []

            return TaskStatistics(
                total: tasks.count,
                pending: tasks.count(where: { $0.status == .pending }),
                inProgress: tasks.count(where: { $0.status == .inProgress }),
                completed: tasks.count(where: { $0.status == .completed }),
                failed: tasks.count(where: { $0.status == .failed }),
                blocked: tasks.count(where: { $0.status == .blocked })
            )
        }

        // MARK: - Private

        private func logTaskChange(_ action: String, task: ConversationTask) {
            DiagnosticsLogger.log(
                .builtinTools,
                level: .info,
                message: "Task \(action)",
                metadata: [
                    "taskId": task.id.uuidString,
                    "status": task.status.rawValue,
                    "content": String(task.content.prefix(50))
                ]
            )
        }
    }

    /// Statistics about tasks
    struct TaskStatistics: Sendable {
        let total: Int
        let pending: Int
        let inProgress: Int
        let completed: Int
        let failed: Int
        let blocked: Int

        var progressPercentage: Double {
            guard total > 0 else { return 0 }
            return Double(completed) / Double(total) * 100
        }
    }
#endif
