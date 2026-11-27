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

    @Test("Starts with no pending approvals")
    func startsEmpty() {
        #expect(sut.pendingApprovals.isEmpty)
    }

    @Test("Pending count for conversation is zero initially")
    func pendingCountZeroInitially() {
        let conversationId = UUID()
        #expect(sut.pendingCount(forConversation: conversationId) == 0)
    }

    private func waitForPendingApprovals(
        count: Int,
        in service: PermissionService? = nil,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let target = service ?? sut
        if target.pendingApprovals.count >= count {
            return true
        }
        let observed = FlightTestSignal()
        let observer = NotificationCenter.default.addObserver(
            forName: .pendingApprovalsChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if target.pendingApprovals.count >= count {
                    observed.signal()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        if target.pendingApprovals.count >= count {
            return true
        }
        let signaled = await observed.wait(timeout: timeout)
        return signaled && target.pendingApprovals.count >= count
    }

    @Test("Approve removes from pending and resumes")
    func approveRemovesFromPending() async {
        let conversationId = UUID()

        let task = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write file",
                details: "/path/to/file.txt",
                conversationId: conversationId
            )
        }
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }

        #expect(sut.pendingApprovals.count == 1)

        if let approvalId = sut.pendingApprovals.first?.id {
            sut.approve(approvalId)
        }

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
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }

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
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }

        if let approvalId = sut.pendingApprovals.first?.id {
            sut.approve(approvalId, rememberForSession: true)
        }

        _ = await task.value

        let level = sut.checkPermission(
            tool: "write_file",
            details: "/path/to/file.txt",
            defaultLevel: .askOnce
        )
        #expect(level == .automatic)
    }

    @Test("Cancelling an approval request denies only that request")
    func cancellingApprovalRequestDeniesOnlyThatRequest() async {
        let conversationId = UUID()
        let task = Task {
            await sut.requestApproval(
                toolName: "run_command",
                description: "Run command",
                details: "sleep 30",
                conversationId: conversationId
            )
        }
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }
        #expect(sut.pendingApprovals.count == 1)

        task.cancel()
        #expect(await task.value == false)
        #expect(sut.pendingApprovals.isEmpty)
    }

    @Test("Remembered approval is not visible until request commits")
    func rememberedApprovalIsNotVisibleUntilRequestCommits() async {
        let conversationId = UUID()
        let details = "/tmp/provisional"
        let task = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write",
                details: details,
                conversationId: conversationId
            )
        }
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }
        guard let approvalID = sut.pendingApprovals.first?.id else {
            Issue.record("Approval did not become pending")
            return
        }

        sut.approve(approvalID, rememberForSession: true)
        #expect(sut.checkPermission(tool: "write_file", details: details, defaultLevel: .askOnce) == .askOnce)
        #expect(await task.value)
        #expect(sut.checkPermission(tool: "write_file", details: details, defaultLevel: .askOnce) == .automatic)
    }

    @Test("Cancelled approval cannot grant session permission")
    func cancelledApprovalCannotGrantSessionPermission() async {
        let conversationId = UUID()
        let details = "echo unsafe"
        let task = Task {
            await sut.requestApproval(
                toolName: "run_command",
                description: "Run command",
                details: details,
                conversationId: conversationId
            )
        }
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }
        let approvalID = sut.pendingApprovals.first?.id
        #expect(approvalID != nil)
        guard let approvalID else { return }

        task.cancel()
        sut.approve(approvalID, rememberForSession: true)

        #expect(await task.value == false)
        #expect(sut.checkPermission(tool: "run_command", details: details, defaultLevel: .askAlways) == .askAlways)
    }

    @Test("Cancelling an identical approval preserves another committed grant")
    func cancellingIdenticalApprovalPreservesCommittedGrant() async {
        let conversationId = UUID()
        let details = "/tmp/shared"
        let first = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "First",
                details: details,
                conversationId: conversationId
            )
        }
        let second = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Second",
                details: details,
                conversationId: conversationId
            )
        }
        defer {
            first.cancel()
            second.cancel()
        }

        guard await waitForPendingApprovals(count: 2) else {
            Issue.record("Timed out waiting for pending approvals")
            return
        }
        #expect(sut.pendingApprovals.count == 2)
        guard let firstID = sut.pendingApprovals.first?.id else { return }

        sut.approve(firstID, rememberForSession: true)
        #expect(await first.value)
        second.cancel()
        #expect(await second.value == false)

        #expect(sut.checkPermission(tool: "write_file", details: details, defaultLevel: .askOnce) == .automatic)
    }

    @Test("Cancellation after approval resumes still rejects the operation")
    func cancellationAfterApprovalResumesStillRejectsOperation() async {
        let conversationId = UUID()
        let task = Task {
            await sut.requestApproval(
                toolName: "run_command",
                description: "Run command",
                details: "echo unsafe",
                conversationId: conversationId
            )
        }
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }
        let approvalID = sut.pendingApprovals.first?.id
        #expect(approvalID != nil)
        guard let approvalID else { return }

        sut.approve(approvalID)
        task.cancel()

        #expect(await task.value == false)
    }

    @Test("Cancelling a stale approval preserves a replacement in the same conversation")
    func cancellingStaleApprovalPreservesReplacementInSameConversation() async {
        let conversationId = UUID()
        let staleTask = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Stale write",
                details: "/tmp/stale",
                conversationId: conversationId
            )
        }
        let replacementTask = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Replacement write",
                details: "/tmp/replacement",
                conversationId: conversationId
            )
        }
        defer {
            staleTask.cancel()
            replacementTask.cancel()
        }

        guard await waitForPendingApprovals(count: 2) else {
            Issue.record("Timed out waiting for pending approvals")
            return
        }
        #expect(sut.pendingApprovals.count == 2)

        staleTask.cancel()
        #expect(await staleTask.value == false)
        #expect(sut.pendingApprovals.count == 1)
        #expect(sut.pendingApprovals.first?.details == "/tmp/replacement")

        if let replacementID = sut.pendingApprovals.first?.id {
            sut.deny(replacementID)
        }
        #expect(await replacementTask.value == false)
    }

    @Test("Deny all pending for conversation")
    func denyAllPendingForConversation() async {
        let conversationId = UUID()
        let otherConversationId = UUID()

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

        let task3 = Task {
            await sut.requestApproval(
                toolName: "write_file",
                description: "Write file 3",
                details: "/path/to/file3.txt",
                conversationId: otherConversationId
            )
        }
        defer {
            task1.cancel()
            task2.cancel()
            task3.cancel()
        }

        guard await waitForPendingApprovals(count: 3) else {
            Issue.record("Timed out waiting for pending approvals")
            return
        }

        sut.denyAllPending(forConversation: conversationId, reason: "Conversation closed")

        let result1 = await task1.value
        let result2 = await task2.value

        #expect(result1 == false)
        #expect(result2 == false)

        #expect(sut.pendingCount(forConversation: otherConversationId) == 1)

        if let approvalId = sut.pendingApprovals.first?.id {
            sut.deny(approvalId)
        }
        _ = await task3.value
    }

    @Test("Default timeout is 5 minutes")
    func defaultTimeout() {
        #expect(sut.approvalTimeoutSeconds == 300)
    }

    @Test("No timeout keeps an approval pending until cancelled", .timeLimit(.minutes(1)))
    func noTimeoutKeepsApprovalPending() async {
        let timeoutScheduled = FlightTestBox(false)
        let service = PermissionService(timeoutSleep: { _ in
            timeoutScheduled.value = true
        })
        service.approvalTimeoutSeconds = 0
        let task = Task {
            await service.requestApproval(
                toolName: "write_file",
                description: "Write file",
                details: "/tmp/no-timeout.txt",
                conversationId: UUID()
            )
        }
        defer { task.cancel() }

        guard await waitForPendingApprovals(count: 1, in: service) else {
            Issue.record("Timed out waiting for pending approval")
            return
        }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(service.pendingApprovals.count == 1)
        #expect(!timeoutScheduled.value)

        task.cancel()
        #expect(await task.value == false)
        #expect(service.pendingApprovals.isEmpty)
    }

    @Test("A positive timeout still denies a pending approval", .timeLimit(.minutes(1)))
    func positiveTimeoutDeniesPendingApproval() async {
        let timeoutStarted = FlightTestSignal()
        let releaseTimeout = FlightTestSignal()
        let observedSeconds = FlightTestBox<Int?>(nil)
        let service = PermissionService(timeoutSleep: { seconds in
            observedSeconds.value = seconds
            timeoutStarted.signal()
            await releaseTimeout.wait()
        })
        service.approvalTimeoutSeconds = 1
        let task = Task {
            await service.requestApproval(
                toolName: "write_file",
                description: "Write file",
                details: "/tmp/timeout.txt",
                conversationId: UUID()
            )
        }

        await timeoutStarted.wait()
        #expect(observedSeconds.value == 1)
        #expect(service.pendingApprovals.count == 1)

        releaseTimeout.signal()
        let approved = await task.value
        #expect(approved == false)
        #expect(service.pendingApprovals.isEmpty)
    }

    @Test("Timeout is configurable")
    func timeoutIsConfigurable() {
        sut.approvalTimeoutSeconds = 60
        #expect(sut.approvalTimeoutSeconds == 60)
    }
}
