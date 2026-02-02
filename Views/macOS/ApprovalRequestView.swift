//
//  ApprovalRequestView.swift
//  Ayna
//
//  Inline approval UI for agentic tool operations.
//  Displays pending approval requests in the chat interface.
//

import SwiftUI

/// View for displaying a single pending approval request
struct ApprovalRequestView: View {
    let approval: PendingApproval
    let onApprove: (Bool) -> Void // Bool indicates whether to remember for session
    let onDeny: () -> Void
    let pendingCount: Int // Total pending approvals for batch approval option

    @State private var showDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with icon and tool name
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)

                Text(approval.toolName.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.headline)

                Spacer()

                // Time since request
                Text(timeSinceRequest)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Description
            Text(approval.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Details (path or command)
            detailsView

            // Diff preview for edit operations
            if let diff = approval.diffPreview {
                DisclosureGroup("Show changes", isExpanded: $showDiff) {
                    DiffPreviewView(diff: diff)
                        .frame(maxHeight: 200)
                }
                .font(.subheadline)
            }

            Divider()

            // Action buttons
            actionButtons
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private var detailsView: some View {
        if approval.toolName == "run_command" {
            // Command display with monospace font
            ScrollView(.horizontal, showsIndicators: false) {
                Text(approval.details)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            // File path display
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(approval.details)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Deny button
            Button(action: onDeny) {
                Label("Deny", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityLabel("Deny \(approval.toolName.replacingOccurrences(of: "_", with: " ")) operation")
            .accessibilityHint("Denies this tool operation and returns an error to the AI")

            Spacer()

            // Batch approval option for file operations
            if isFileOperation, pendingCount > 1 {
                Menu {
                    Button("Allow All (\(pendingCount))") {
                        onApprove(true)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Approve all pending file operations")
                .accessibilityLabel("More approval options")
                .accessibilityHint("Opens menu with batch approval options")
            }

            // Approve button
            Button(action: { onApprove(false) }) {
                Label("Allow", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityLabel("Allow \(approval.toolName.replacingOccurrences(of: "_", with: " ")) operation")
            .accessibilityHint("Allows this single operation")

            // Remember option
            Button(action: { onApprove(true) }) {
                Label("Allow & Remember", systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .help("Allow and remember this approval for the session")
            .accessibilityLabel("Allow and remember for session")
            .accessibilityHint("Allows this operation and remembers approval for similar operations in this session")
        }
    }

    // MARK: - Computed Properties

    private var iconName: String {
        switch approval.toolName {
        case "read_file":
            "doc.text"
        case "write_file":
            "doc.badge.plus"
        case "edit_file":
            "pencil"
        case "list_directory":
            "folder"
        case "search_files":
            "magnifyingglass"
        case "run_command":
            "terminal"
        default:
            "exclamationmark.shield"
        }
    }

    private var iconColor: Color {
        switch approval.toolName {
        case "read_file", "list_directory", "search_files":
            .blue
        case "write_file", "edit_file":
            .orange
        case "run_command":
            .red
        default:
            .yellow
        }
    }

    private var borderColor: Color {
        switch approval.toolName {
        case "run_command":
            .red.opacity(0.3)
        case "write_file", "edit_file":
            .orange.opacity(0.3)
        default:
            .clear
        }
    }

    private var isFileOperation: Bool {
        ["write_file", "edit_file", "read_file"].contains(approval.toolName)
    }

    private var timeSinceRequest: String {
        let interval = Date().timeIntervalSince(approval.createdAt)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }
    }
}

// MARK: - Diff Preview View

/// Displays a diff preview with syntax highlighting
struct DiffPreviewView: View {
    let diff: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(diff.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                    diffLine(line)
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func diffLine(_ line: String) -> some View {
        HStack(spacing: 0) {
            Text(line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(lineColor(for: line))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(for: line))
    }

    private func lineColor(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return .green
        } else if line.hasPrefix("-"), !line.hasPrefix("---") {
            return .red
        } else if line.hasPrefix("@@") {
            return .cyan
        }
        return .primary
    }

    private func lineBackground(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return .green.opacity(0.1)
        } else if line.hasPrefix("-"), !line.hasPrefix("---") {
            return .red.opacity(0.1)
        }
        return .clear
    }
}

// MARK: - Pending Approvals List View

/// View for displaying all pending approval requests.
/// Uses NotificationCenter to listen for changes instead of timer-based polling.
struct PendingApprovalsView: View {
    var permissionService: PermissionService
    let conversationId: UUID

    // Refresh trigger updated via NotificationCenter instead of timer polling
    @State private var refreshTrigger = false

    var body: some View {
        let allApprovals = permissionService.pendingApprovals
        let approvals = allApprovals.filter {
            $0.conversationId == conversationId
        }

        Group {
            if !approvals.isEmpty {
                VStack(spacing: 12) {
                    ForEach(approvals) { approval in
                        ApprovalRequestView(
                            approval: approval,
                            onApprove: { rememberForSession in
                                permissionService.approve(approval.id, rememberForSession: rememberForSession)
                            },
                            onDeny: {
                                permissionService.deny(approval.id)
                            },
                            pendingCount: approvals.count
                        )
                    }
                }
                .padding(.horizontal)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        // Use refreshTrigger to force re-evaluation when approvals change
        .id(refreshTrigger)
        .onReceive(NotificationCenter.default.publisher(for: .pendingApprovalsChanged)) { notification in
            // Only refresh if the notification is for this conversation or unspecified
            if let notificationConversationId = notification.userInfo?["conversationId"] as? UUID {
                if notificationConversationId == conversationId {
                    refreshTrigger.toggle()
                }
            } else {
                // No conversation specified, refresh anyway
                refreshTrigger.toggle()
            }
        }
    }
}

// MARK: - Approval Status Badge

/// Small badge showing pending approval count
struct ApprovalStatusBadge: View {
    let pendingCount: Int

    var body: some View {
        if pendingCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.shield")
                    .font(.caption2)
                Text("\(pendingCount)")
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(.orange)
            )
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Preview

#Preview("Approval Request - Command") {
    ApprovalRequestView(
        approval: PendingApproval(
            id: UUID(),
            toolName: "run_command",
            description: "Execute shell command",
            details: "git status && git diff HEAD~1",
            diffPreview: nil,
            createdAt: Date(),
            conversationId: UUID()
        ),
        onApprove: { _ in },
        onDeny: {},
        pendingCount: 1
    )
    .frame(width: 400)
    .padding()
}

#Preview("Approval Request - Edit File") {
    ApprovalRequestView(
        approval: PendingApproval(
            id: UUID(),
            toolName: "edit_file",
            description: "Edit file",
            details: "/Users/test/project/src/main.swift",
            diffPreview: """
            --- old
            +++ new
            - func oldFunction() {
            -     print("old")
            - }
            + func newFunction() {
            +     print("new")
            + }
            """,
            createdAt: Date().addingTimeInterval(-120),
            conversationId: UUID()
        ),
        onApprove: { _ in },
        onDeny: {},
        pendingCount: 3
    )
    .frame(width: 400)
    .padding()
}
