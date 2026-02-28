//
//  PermissionService.swift
//  ayna
//

import Foundation

/// A tool execution request awaiting user approval.
struct PendingApproval: Identifiable, Sendable {
    let id: UUID
    let conversationId: UUID
    let toolName: String
    let toolCallId: String
    let arguments: [String: String]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        toolName: String,
        toolCallId: String,
        arguments: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.arguments = arguments
        self.timestamp = timestamp
    }
}

/// Manages tool execution permissions and pending approval requests.
/// Tools that require user approval before execution register their requests here.
@Observable
@MainActor
final class PermissionService {
    /// Pending approval requests waiting for user action
    var pendingApprovals: [PendingApproval] = []

    /// Tool names that have been approved for the current session
    private var sessionApprovedTools: Set<String> = []

    /// Add a new pending approval request
    func requestApproval(
        conversationId: UUID,
        toolName: String,
        toolCallId: String,
        arguments: [String: String] = [:]
    ) -> PendingApproval {
        let approval = PendingApproval(
            conversationId: conversationId,
            toolName: toolName,
            toolCallId: toolCallId,
            arguments: arguments
        )
        pendingApprovals.append(approval)
        return approval
    }

    /// Approve a pending request
    func approve(_ id: UUID, rememberForSession: Bool) {
        if let index = pendingApprovals.firstIndex(where: { $0.id == id }) {
            let approval = pendingApprovals[index]
            if rememberForSession {
                sessionApprovedTools.insert(approval.toolName)
            }
            pendingApprovals.remove(at: index)
        }
    }

    /// Deny a pending request
    func deny(_ id: UUID) {
        pendingApprovals.removeAll { $0.id == id }
    }

    /// Check if a tool is pre-approved for the session
    func isApprovedForSession(_ toolName: String) -> Bool {
        sessionApprovedTools.contains(toolName)
    }

    /// Clear all session approvals
    func clearSessionApprovals() {
        sessionApprovedTools.removeAll()
    }
}
