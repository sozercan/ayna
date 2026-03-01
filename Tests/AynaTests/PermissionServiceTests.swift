//
//  PermissionServiceTests.swift
//  aynaTests
//
//  Unit tests for PermissionService approval workflow.
//

@testable import Ayna
import Foundation
import Testing

@Suite("PermissionService Tests")
@MainActor
struct PermissionServiceTests {
    private var sut: PermissionService

    init() {
        sut = PermissionService()
    }

    // MARK: - Permission Level

    @Test("PermissionLevel has correct display names")
    func permissionLevelDisplayNames() {
        #expect(PermissionLevel.automatic.displayName == "Automatic")
        #expect(PermissionLevel.askOnce.displayName == "Ask Once")
        #expect(PermissionLevel.askAlways.displayName == "Ask Always")
        #expect(PermissionLevel.denied.displayName == "Denied")
    }

    @Test("Default permission levels are correct")
    func defaultPermissionLevels() {
        #expect(PermissionService.defaultPermissionLevel(for: "read_file") == .automatic)
        #expect(PermissionService.defaultPermissionLevel(for: "list_directory") == .automatic)
        #expect(PermissionService.defaultPermissionLevel(for: "search_files") == .automatic)
        #expect(PermissionService.defaultPermissionLevel(for: "web_fetch") == .automatic)
        #expect(PermissionService.defaultPermissionLevel(for: "write_file") == .askOnce)
        #expect(PermissionService.defaultPermissionLevel(for: "edit_file") == .askOnce)
        #expect(PermissionService.defaultPermissionLevel(for: "run_command") == .askAlways)
        #expect(PermissionService.defaultPermissionLevel(for: "unknown_tool") == .askAlways)
    }

    // MARK: - Session Approvals

    @Test("Records session approval")
    func recordsSessionApproval() {
        let tool = "write_file"
        let details = "/path/to/file.txt"

        sut.recordSessionApproval(tool: tool, details: details)

        let level = sut.checkPermission(tool: tool, details: details, defaultLevel: .askOnce)
        #expect(level == .automatic)
    }

    @Test("Session approval is specific to tool and details")
    func sessionApprovalIsSpecific() {
        sut.recordSessionApproval(tool: "write_file", details: "/path/to/file1.txt")

        // Different file should still require approval
        let level = sut.checkPermission(
            tool: "write_file",
            details: "/path/to/file2.txt",
            defaultLevel: .askOnce
        )
        #expect(level == .askOnce)
    }

    @Test("Clears session approvals")
    func clearsSessionApprovals() {
        sut.recordSessionApproval(tool: "write_file", details: "/path/to/file.txt")
        sut.clearSessionApprovals()

        let level = sut.checkPermission(
            tool: "write_file",
            details: "/path/to/file.txt",
            defaultLevel: .askOnce
        )
        #expect(level == .askOnce)
    }

    // MARK: - Directory Approvals

    @Test("Records directory approval")
    func recordsDirectoryApproval() {
        sut.recordDirectoryApproval(tool: "write_file", directory: "/path/to/project")

        #expect(sut.isDirectoryApproved(tool: "write_file", directory: "/path/to/project") == true)
    }

    @Test("Directory approval is specific to tool")
    func directoryApprovalIsSpecificToTool() {
        sut.recordDirectoryApproval(tool: "write_file", directory: "/path/to/project")

        #expect(sut.isDirectoryApproved(tool: "edit_file", directory: "/path/to/project") == false)
    }

    // MARK: - Pending Approvals

    @Test("Starts with no pending approvals")
    func startsEmpty() {
        #expect(sut.pendingApprovals.isEmpty)
    }

    @Test("Pending count for conversation is zero initially")
    func pendingCountZeroInitially() {
        let conversationId = UUID()
        #expect(sut.pendingCount(forConversation: conversationId) == 0)
    }

    // MARK: - Approval Workflow

    @Test("Approve removes from pending and resumes")
    func approveRemovesFromPending() async {
        let conversationId = UUID()

        // Start approval request in background
        let task = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write file",
                details: "/path/to/file.txt",
                conversationId: conversationId
            )
        }

        // Wait for approval to be queued
        try? await Task.sleep(for: .milliseconds(50))

        // Check pending
        #expect(sut.pendingApprovals.count == 1)

        // Approve
        if let approvalId = sut.pendingApprovals.first?.id {
            sut.approve(approvalId)
        }

        // Check result
        let result = await task.value
        #expect(result == true)
        #expect(sut.pendingApprovals.isEmpty)
    }

    @Test("Deny removes from pending and returns false")
    func denyReturnsEmpty() async {
        let conversationId = UUID()

        let task = Task {
            await sut.requestApproval(
                toolName: "run_command",
                description: "Run command",
                details: "ls -la",
                conversationId: conversationId
            )
        }

        try? await Task.sleep(for: .milliseconds(50))

        if let approvalId = sut.pendingApprovals.first?.id {
            sut.deny(approvalId)
        }

        let result = await task.value
        #expect(result == false)
        #expect(sut.pendingApprovals.isEmpty)
    }

    @Test("Approve with remember records session approval")
    func approveWithRemember() async {
        let conversationId = UUID()

        let task = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write file",
                details: "/path/to/file.txt",
                conversationId: conversationId
            )
        }

        try? await Task.sleep(for: .milliseconds(50))

        if let approvalId = sut.pendingApprovals.first?.id {
            sut.approve(approvalId, rememberForSession: true)
        }

        _ = await task.value

        // Check that it was remembered
        let level = sut.checkPermission(
            tool: "write_file",
            details: "/path/to/file.txt",
            defaultLevel: .askOnce
        )
        #expect(level == .automatic)
    }

    // MARK: - Deny All Pending

    @Test("Deny all pending for conversation")
    func denyAllPendingForConversation() async {
        let conversationId = UUID()
        let otherConversationId = UUID()

        // Start two approval requests for same conversation
        let task1 = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write file 1",
                details: "/path/to/file1.txt",
                conversationId: conversationId
            )
        }

        let task2 = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write file 2",
                details: "/path/to/file2.txt",
                conversationId: conversationId
            )
        }

        // And one for a different conversation
        let task3 = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write file 3",
                details: "/path/to/file3.txt",
                conversationId: otherConversationId
            )
        }

        try? await Task.sleep(for: .milliseconds(50))

        // Deny all for first conversation
        sut.denyAllPending(forConversation: conversationId, reason: "Conversation closed")

        let result1 = await task1.value
        let result2 = await task2.value

        #expect(result1 == false)
        #expect(result2 == false)

        // Other conversation should still have pending
        #expect(sut.pendingCount(forConversation: otherConversationId) == 1)

        // Clean up
        if let approvalId = sut.pendingApprovals.first?.id {
            sut.deny(approvalId)
        }
        _ = await task3.value
    }

    // MARK: - Timeout Configuration

    @Test("Default timeout is 5 minutes")
    func defaultTimeout() {
        #expect(sut.approvalTimeoutSeconds == 300)
    }

    @Test("Timeout is configurable")
    func timeoutIsConfigurable() {
        sut.approvalTimeoutSeconds = 60
        #expect(sut.approvalTimeoutSeconds == 60)
    }
}
