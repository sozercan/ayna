//
//  TaskListView.swift
//  Ayna
//
//  View for displaying tasks within a conversation.
//  Shows task progress, status, and allows manual status updates.
//

import SwiftUI

/// View for displaying conversation tasks
struct TaskListView: View {
    @Bindable var taskManager: ConversationTaskManager
    let conversationId: UUID

    @State private var isExpanded = true

    var body: some View {
        let tasks = taskManager.tasksByConversation[conversationId] ?? []

        if !tasks.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(taskManager.rootTasks) { task in
                        TaskRowView(
                            task: task,
                            taskManager: taskManager,
                            conversationId: conversationId
                        )

                        // Show subtasks
                        let subtasks = taskManager.subtasks(of: task.id)
                        if !subtasks.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(subtasks) { subtask in
                                    TaskRowView(
                                        task: subtask,
                                        taskManager: taskManager,
                                        conversationId: conversationId,
                                        isSubtask: true
                                    )
                                }
                            }
                            .padding(.leading, 24)
                        }
                    }
                }
            } label: {
                TaskListHeader(statistics: taskManager.statistics(forConversation: conversationId))
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
}

/// Header showing task progress
struct TaskListHeader: View {
    let statistics: TaskStatistics

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Tasks")
                .font(.headline)

            Spacer()

            // Progress indicator
            if statistics.total > 0 {
                HStack(spacing: 4) {
                    Text("\(statistics.completed)/\(statistics.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    ProgressView(value: statistics.progressPercentage, total: 100)
                        .progressViewStyle(.linear)
                        .frame(width: 60)
                }
            }

            // Status badges
            HStack(spacing: 4) {
                if statistics.inProgress > 0 {
                    StatusBadge(count: statistics.inProgress, status: .inProgress)
                }
                if statistics.blocked > 0 {
                    StatusBadge(count: statistics.blocked, status: .blocked)
                }
                if statistics.failed > 0 {
                    StatusBadge(count: statistics.failed, status: .failed)
                }
            }
        }
    }
}

/// Individual task row
struct TaskRowView: View {
    let task: ConversationTask
    @Bindable var taskManager: ConversationTaskManager
    let conversationId: UUID
    var isSubtask: Bool = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Button {
                cycleStatus()
            } label: {
                Image(systemName: task.status.iconName)
                    .foregroundStyle(statusColor)
                    .font(isSubtask ? .caption : .body)
            }
            .buttonStyle(.plain)
            .help("Click to change status")
            .accessibilityLabel("Task status: \(task.status.displayName)")
            .accessibilityHint("Double-tap to cycle to next status")

            // Task content
            VStack(alignment: .leading, spacing: 2) {
                Text(task.content)
                    .font(isSubtask ? .caption : .body)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status.isTerminal ? .secondary : .primary)

                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Time indicator
            if isHovering {
                Text(timeAgo)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3) : .clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button {
                    taskManager.updateTask(id: task.id, status: status, inConversation: conversationId)
                } label: {
                    Label(status.displayName, systemImage: status.iconName)
                }
            }

            Divider()

            Button(role: .destructive) {
                taskManager.removeTask(id: task.id, inConversation: conversationId)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: .secondary
        case .inProgress: .blue
        case .completed: .green
        case .failed: .red
        case .blocked: .orange
        }
    }

    private var timeAgo: String {
        let interval = Date().timeIntervalSince(task.updatedAt)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else {
            return "\(Int(interval / 3600))h ago"
        }
    }

    private func cycleStatus() {
        let newStatus: TaskStatus = switch task.status {
        case .pending: .inProgress
        case .inProgress: .completed
        case .completed: .pending
        case .failed: .inProgress
        case .blocked: .inProgress
        }
        taskManager.updateTask(id: task.id, status: newStatus, inConversation: conversationId)
    }
}

/// Small badge showing count for a status
struct StatusBadge: View {
    let count: Int
    let status: TaskStatus

    var body: some View {
        Text("\(count)")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(badgeColor.opacity(0.2))
            )
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch status {
        case .pending: .secondary
        case .inProgress: .blue
        case .completed: .green
        case .failed: .red
        case .blocked: .orange
        }
    }
}

// MARK: - Compact Task Indicator

/// Compact indicator for showing task progress in the message area
struct CompactTaskIndicator: View {
    let statistics: TaskStatistics

    var body: some View {
        if statistics.total > 0 {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.caption2)

                Text("\(statistics.completed)/\(statistics.total)")
                    .font(.caption2.monospacedDigit())

                if statistics.inProgress > 0 {
                    Circle()
                        .fill(.blue)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview("Task List") {
    let manager = ConversationTaskManager()
    let conversationId = UUID()
    manager.currentConversationId = conversationId

    _ = manager.addTask("Read the codebase", status: .completed, toConversation: conversationId)
    _ = manager.addTask("Implement feature X", status: .inProgress, toConversation: conversationId)
    _ = manager.addTask("Write tests", status: .pending, toConversation: conversationId)
    _ = manager.addTask("Update documentation", status: .pending, toConversation: conversationId)

    return TaskListView(taskManager: manager, conversationId: conversationId)
        .frame(width: 400)
        .padding()
}
