//
//  PermissionService.swift
//  Ayna
//
//  Manages permission checks and approval workflow for agentic tool operations.
//

import Foundation
import os.log
import UserNotifications

#if os(macOS)
import AppKit
#endif

// MARK: - Notifications

extension Notification.Name {
    /// Posted when pending approvals change (added or removed)
    static let pendingApprovalsChanged = Notification.Name("pendingApprovalsChanged")
}

// MARK: - System Notification Constants

private enum ApprovalNotificationConstants {
    static let categoryIdentifier = "TOOL_APPROVAL"
    static let approveActionIdentifier = "APPROVE_ACTION"
    static let denyActionIdentifier = "DENY_ACTION"
}

// MARK: - Permission Level

/// Permission level for tool operations
enum PermissionLevel: String, Codable, CaseIterable, Sendable {
    case automatic // Read-only operations, web search
    case askOnce // Approve once per session (file writes in project directory)
    case askAlways // Always confirm (shell commands, writes outside project)
    case denied // Never allow (destructive commands, sensitive paths)

    /// Forward-compatible decoding (new cases default to askAlways)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = PermissionLevel(rawValue: value) ?? .askAlways
    }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .askOnce: "Ask Once"
        case .askAlways: "Ask Always"
        case .denied: "Denied"
        }
    }

    var description: String {
        switch self {
        case .automatic: "Execute without prompting"
        case .askOnce: "Ask once per session"
        case .askAlways: "Always ask before executing"
        case .denied: "Never allow"
        }
    }
}

// MARK: - Pending Approval

/// Represents a pending approval request
struct PendingApproval: Identifiable, Sendable, Equatable {
    let id: UUID
    let toolName: String
    let description: String
    let details: String // File path or command
    let diffPreview: String? // For edit operations, show what will change
    let createdAt: Date
    let conversationId: UUID // Track which conversation this belongs to

    // Callbacks are not Sendable, so we use a different approach
    // The PermissionService will handle the callbacks internally

    static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Permission Service

/// Manages approval workflow for dangerous operations.
///
/// Approval queue behavior:
/// - Concurrent approvals: Processed in order, UI shows queue count
/// - User closes conversation: Pending approvals auto-denied
/// - App terminates: Pending approvals lost (not persisted)
/// - Timeout: Auto-deny after timeout period (configurable)
@Observable @MainActor
final class PermissionService {
    // MARK: - Properties

    /// Pending approvals waiting for user action
    private(set) var pendingApprovals: [PendingApproval] = []

    /// Approval timeout in seconds (default 5 minutes)
    var approvalTimeoutSeconds: Int = 300

    /// Session approvals - tools that have been approved for this session
    /// Key format: "toolName:path" or "toolName:command"
    private var sessionApprovals: Set<String> = []

    /// Whether to persist approvals across sessions
    var persistApprovalsAcrossSessions: Bool = false

    /// Continuations for async approval flow
    private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Timeout tasks for auto-deny
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    #if os(macOS)
    /// Notification delegate for handling system notification responses
    private let notificationDelegate = ApprovalNotificationDelegate()

    /// Whether system notifications are enabled
    private var systemNotificationsEnabled: Bool = false
    #endif

    // MARK: - Initialization

    init() {
        setupNotifications()
    }

    // MARK: - System Notification Setup

    private func setupNotifications() {
        #if os(macOS)
        let center = UNUserNotificationCenter.current()

        // Set delegate to handle notification actions
        notificationDelegate.permissionService = self

        // Request notification permissions
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                if granted {
                    self?.systemNotificationsEnabled = true
                    self?.log(.info, "System notifications enabled")
                } else if let error {
                    self?.log(.error, "Notification permission denied", metadata: ["error": error.localizedDescription])
                } else {
                    self?.log(.info, "Notification permission denied by user")
                }
            }
        }

        // Configure notification actions
        let approveAction = UNNotificationAction(
            identifier: ApprovalNotificationConstants.approveActionIdentifier,
            title: "Approve",
            options: [.foreground]
        )
        let denyAction = UNNotificationAction(
            identifier: ApprovalNotificationConstants.denyActionIdentifier,
            title: "Deny",
            options: [.destructive, .foreground]
        )

        let category = UNNotificationCategory(
            identifier: ApprovalNotificationConstants.categoryIdentifier,
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
        center.delegate = notificationDelegate
        #endif
    }

    /// Shows a system notification for an approval request
    private func showSystemNotification(for approval: PendingApproval) {
        #if os(macOS)
        guard systemNotificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tool Approval Required"
        content.subtitle = approval.toolName
        content.body = "\(approval.description)\n\(approval.details)"
        content.sound = .default
        content.categoryIdentifier = ApprovalNotificationConstants.categoryIdentifier
        content.userInfo = ["approvalId": approval.id.uuidString]

        let request = UNNotificationRequest(
            identifier: approval.id.uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.log(.error, "Failed to show notification", metadata: ["error": error.localizedDescription])
                }
            } else {
                Task { @MainActor in
                    self?.log(.info, "System notification shown", metadata: ["approvalId": approval.id.uuidString])
                }
            }
        }
        #endif
    }

    /// Removes a system notification for an approval
    private func removeSystemNotification(for approvalId: UUID) {
        #if os(macOS)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [approvalId.uuidString])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [approvalId.uuidString])
        #endif
    }

    // MARK: - Permission Checking

    /// Checks the permission level for a tool operation.
    ///
    /// - Parameters:
    ///   - tool: The tool name
    ///   - details: Additional details (path, command, etc.)
    ///   - defaultLevel: The default permission level for this tool
    /// - Returns: The effective permission level
    func checkPermission(
        tool: String,
        details: String,
        defaultLevel: PermissionLevel
    ) -> PermissionLevel {
        // Check if already approved this session
        let key = approvalKey(tool: tool, details: details)
        if sessionApprovals.contains(key) {
            return .automatic
        }

        return defaultLevel
    }

    /// Records a session approval for a tool operation.
    ///
    /// - Parameters:
    ///   - tool: The tool name
    ///   - details: The specific details that were approved
    func recordSessionApproval(tool: String, details: String) {
        let key = approvalKey(tool: tool, details: details)
        sessionApprovals.insert(key)

        log(.info, "Session approval recorded", metadata: ["tool": tool, "key": key])
    }

    /// Records a session approval for a directory (for batch approvals).
    ///
    /// - Parameters:
    ///   - tool: The tool name
    ///   - directory: The directory path
    func recordDirectoryApproval(tool: String, directory: String) {
        let key = "dir:\(tool):\(directory)"
        sessionApprovals.insert(key)

        log(.info, "Directory approval recorded", metadata: ["tool": tool, "directory": directory])
    }

    /// Checks if a directory has been approved.
    func isDirectoryApproved(tool: String, directory: String) -> Bool {
        let key = "dir:\(tool):\(directory)"
        return sessionApprovals.contains(key)
    }

    // MARK: - Approval Workflow

    /// Requests approval for a tool operation.
    ///
    /// This method suspends until the user approves or denies the request,
    /// or the request times out.
    ///
    /// - Parameters:
    ///   - toolName: Name of the tool requesting approval
    ///   - description: Human-readable description of the operation
    ///   - details: Specific details (file path, command, etc.)
    ///   - diffPreview: Optional diff preview for edit operations
    ///   - conversationId: The conversation this request belongs to
    /// - Returns: true if approved, false if denied
    func requestApproval(
        toolName: String,
        description: String,
        details: String,
        diffPreview: String? = nil,
        conversationId: UUID
    ) async -> Bool {
        let approval = PendingApproval(
            id: UUID(),
            toolName: toolName,
            description: description,
            details: details,
            diffPreview: diffPreview,
            createdAt: Date(),
            conversationId: conversationId
        )

        // Wait for approval - store continuation BEFORE adding to pending list
        // and starting timeout to prevent race conditions where deny() could be
        // called before the continuation is stored
        return await withCheckedContinuation { continuation in
            approvalContinuations[approval.id] = continuation
            pendingApprovals.append(approval)
            log(.info, "Approval requested", metadata: [
                "tool": toolName,
                "id": approval.id.uuidString
            ])

            // Post notification for UI updates
            NotificationCenter.default.post(name: .pendingApprovalsChanged, object: nil, userInfo: [
                "conversationId": conversationId,
                "count": pendingApprovals.count
            ])

            // Show system notification for user attention
            showSystemNotification(for: approval)

            startTimeoutTask(for: approval.id)
        }
    }

    /// Approves a pending request.
    ///
    /// - Parameters:
    ///   - approvalId: The ID of the pending approval
    ///   - rememberForSession: Whether to remember this approval for the session
    func approve(_ approvalId: UUID, rememberForSession: Bool = false) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approvalId }) else {
            return
        }

        let approval = pendingApprovals[index]

        // Record session approval if requested
        if rememberForSession {
            recordSessionApproval(tool: approval.toolName, details: approval.details)
        }

        // Remove from pending
        pendingApprovals.remove(at: index)

        // Cancel timeout
        timeoutTasks[approvalId]?.cancel()
        timeoutTasks.removeValue(forKey: approvalId)

        // Remove system notification
        removeSystemNotification(for: approvalId)

        // Resume continuation
        if let continuation = approvalContinuations.removeValue(forKey: approvalId) {
            continuation.resume(returning: true)
        }

        log(.info, "Approval granted", metadata: [
            "tool": approval.toolName,
            "id": approvalId.uuidString
        ])

        // Post notification for UI updates
        NotificationCenter.default.post(name: .pendingApprovalsChanged, object: nil, userInfo: [
            "conversationId": approval.conversationId,
            "count": pendingApprovals.count
        ])
    }

    /// Denies a pending request.
    ///
    /// - Parameter approvalId: The ID of the pending approval
    func deny(_ approvalId: UUID) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approvalId }) else {
            return
        }

        let approval = pendingApprovals[index]

        // Remove from pending
        pendingApprovals.remove(at: index)

        // Cancel timeout
        timeoutTasks[approvalId]?.cancel()
        timeoutTasks.removeValue(forKey: approvalId)

        // Remove system notification
        removeSystemNotification(for: approvalId)

        // Resume continuation
        if let continuation = approvalContinuations.removeValue(forKey: approvalId) {
            continuation.resume(returning: false)
        }

        log(.info, "Approval denied", metadata: [
            "tool": approval.toolName,
            "id": approvalId.uuidString
        ])

        // Post notification for UI updates
        NotificationCenter.default.post(name: .pendingApprovalsChanged, object: nil, userInfo: [
            "conversationId": approval.conversationId,
            "count": pendingApprovals.count
        ])
    }

    /// Approves all pending file operations.
    ///
    /// - Parameter rememberForSession: Whether to remember approvals for the session
    func approveAllFileOperations(rememberForSession: Bool = true) {
        let fileOps = pendingApprovals.filter {
            $0.toolName == "write_file" ||
                $0.toolName == "edit_file" ||
                $0.toolName == "read_file"
        }

        for approval in fileOps {
            approve(approval.id, rememberForSession: rememberForSession)
        }

        log(.info, "Batch file operations approved", metadata: ["count": "\(fileOps.count)"])
    }

    /// Denies all pending approvals for a conversation.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation ID
    ///   - reason: The reason for denial
    func denyAllPending(forConversation conversationId: UUID, reason: String) {
        let toRemove = pendingApprovals.filter { $0.conversationId == conversationId }

        for approval in toRemove {
            deny(approval.id)
        }

        log(.info, "All pending approvals denied", metadata: [
            "reason": reason,
            "count": "\(toRemove.count)"
        ])
    }

    /// Clears all session approvals.
    func clearSessionApprovals() {
        sessionApprovals.removeAll()
        log(.info, "Session approvals cleared")
    }

    /// Returns the count of pending approvals for a conversation.
    func pendingCount(forConversation conversationId: UUID) -> Int {
        pendingApprovals.count(where: { $0.conversationId == conversationId })
    }

    // MARK: - Timeout Management

    /// Expires stale approvals that have been pending too long.
    func expireStaleApprovals() {
        let now = Date()
        let stale = pendingApprovals.filter { approval in
            now.timeIntervalSince(approval.createdAt) > Double(approvalTimeoutSeconds)
        }

        for approval in stale {
            deny(approval.id)
            log(.info, "Approval expired", metadata: [
                "tool": approval.toolName,
                "id": approval.id.uuidString
            ])
        }
    }

    // MARK: - Private Helpers

    private func approvalKey(tool: String, details: String) -> String {
        "\(tool):\(details)"
    }

    private func startTimeoutTask(for approvalId: UUID) {
        let timeout = approvalTimeoutSeconds
        timeoutTasks[approvalId] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                await self?.deny(approvalId)
            } catch {
                // Task was cancelled, which is expected
            }
        }
    }

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: "🔐 Permission: \(message)", metadata: metadata)
    }
}

// MARK: - Default Permission Levels

extension PermissionService {
    /// Returns the default permission level for a tool.
    static func defaultPermissionLevel(for tool: String) -> PermissionLevel {
        switch tool {
        case "read_file", "list_directory", "search_files", "web_fetch":
            .automatic
        case "write_file", "edit_file":
            .askOnce
        case "run_command":
            .askAlways
        default:
            .askAlways
        }
    }
}

// MARK: - Notification Delegate

/// Handles system notification responses for approval requests
/// Note: This class is intentionally NOT @MainActor to avoid sendability issues with
/// UNUserNotificationCenterDelegate on older Xcode versions (16.x). The delegate methods
/// are nonisolated and hop to @MainActor via Task where needed.
/// Marked @unchecked Sendable because permissionService is only accessed from MainActor context.
#if os(macOS)
private final class ApprovalNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    weak var permissionService: PermissionService?

    /// Called when user interacts with a notification action (Approve/Deny buttons)
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier

        guard let approvalIdString = userInfo["approvalId"] as? String,
              let approvalId = UUID(uuidString: approvalIdString)
        else {
            completionHandler()
            return
        }

        Task { @MainActor [weak self] in
            switch actionIdentifier {
            case ApprovalNotificationConstants.approveActionIdentifier:
                self?.permissionService?.approve(approvalId, rememberForSession: false)
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔐 Permission: Approved via system notification",
                    metadata: ["approvalId": approvalIdString]
                )

            case ApprovalNotificationConstants.denyActionIdentifier,
                 UNNotificationDismissActionIdentifier:
                self?.permissionService?.deny(approvalId)
                DiagnosticsLogger.log(
                    .aiService,
                    level: .info,
                    message: "🔐 Permission: Denied via system notification",
                    metadata: ["approvalId": approvalIdString]
                )

            case UNNotificationDefaultActionIdentifier:
                // User clicked the notification itself - bring app to front
                // The in-app UI can handle the approval
                NSApp.activate(ignoringOtherApps: true)

            default:
                break
            }

            completionHandler()
        }
    }

    /// Called when notification is about to be presented while app is in foreground
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
}
#endif
