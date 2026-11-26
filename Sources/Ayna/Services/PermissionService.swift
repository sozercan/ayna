import Foundation
import os.log
import UserNotifications

#if os(macOS)
    import AppKit
#endif

extension Notification.Name {
    static let pendingApprovalsChanged = Notification.Name("pendingApprovalsChanged")
}

private enum ApprovalNotificationConstants {
    static let categoryIdentifier = "TOOL_APPROVAL"
    static let approveActionIdentifier = "APPROVE_ACTION"
    static let denyActionIdentifier = "DENY_ACTION"
}

enum PermissionLevel: String, Codable, CaseIterable, Sendable {
    case automatic
    case askOnce
    case askAlways
    case denied

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

struct PendingApproval: Identifiable, Sendable, Equatable {
    let id: UUID
    let toolName: String
    let description: String
    let details: String
    let diffPreview: String?
    let createdAt: Date
    let conversationId: UUID

    static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool {
        lhs.id == rhs.id
    }
}

private final class CancelledApprovalRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func mark(_ id: UUID) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }

    func clear(_ id: UUID) {
        lock.lock()
        ids.remove(id)
        lock.unlock()
    }
}

@Observable @MainActor
final class PermissionService {
    private(set) var pendingApprovals: [PendingApproval] = []

    var approvalTimeoutSeconds: Int = 300

    private var sessionApprovals: Set<String> = []
    private var committedSessionApprovalKeys: Set<String> = []
    private var pendingSessionApprovalOwners: [UUID: String] = [:]

    var persistApprovalsAcrossSessions: Bool = false

    private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private nonisolated let cancelledApprovals = CancelledApprovalRegistry()

    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    #if os(macOS)
        private let notificationDelegate = ApprovalNotificationDelegate()

        private var systemNotificationsEnabled: Bool = false
    #endif

    init() {
        setupNotifications()
    }

    private func setupNotifications() {
        #if os(macOS)
            guard Bundle.main.bundlePath.hasSuffix(".app") else { return }

            let center = UNUserNotificationCenter.current()

            notificationDelegate.permissionService = self

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
                trigger: nil
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

    private func removeSystemNotification(for approvalId: UUID) {
        #if os(macOS)
            guard systemNotificationsEnabled else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [approvalId.uuidString])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [approvalId.uuidString])
        #endif
    }

    func checkPermission(
        tool: String,
        details: String,
        defaultLevel: PermissionLevel
    ) -> PermissionLevel {
        let key = approvalKey(tool: tool, details: details)
        if sessionApprovals.contains(key) {
            return .automatic
        }

        return defaultLevel
    }

    func recordSessionApproval(tool: String, details: String) {
        let key = approvalKey(tool: tool, details: details)
        sessionApprovals.insert(key)
        committedSessionApprovalKeys.insert(key)

        log(.info, "Session approval recorded", metadata: ["tool": tool, "key": key])
    }

    func recordDirectoryApproval(tool: String, directory: String) {
        let key = "dir:\(tool):\(directory)"
        sessionApprovals.insert(key)

        log(.info, "Directory approval recorded", metadata: ["tool": tool, "directory": directory])
    }

    func isDirectoryApproved(tool: String, directory: String) -> Bool {
        let key = "dir:\(tool):\(directory)"
        return sessionApprovals.contains(key)
    }

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

        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalContinuations[approval.id] = continuation
                pendingApprovals.append(approval)

                guard !Task.isCancelled else {
                    deny(approval.id)
                    return
                }

                log(.info, "Approval requested", metadata: [
                    "tool": toolName,
                    "id": approval.id.uuidString
                ])

                NotificationCenter.default.post(name: .pendingApprovalsChanged, object: nil, userInfo: [
                    "conversationId": conversationId,
                    "count": pendingApprovals.count
                ])
                showSystemNotification(for: approval)
                startTimeoutTask(for: approval.id)
            }
        } onCancel: { [weak self] in
            self?.cancelledApprovals.mark(approval.id)
            Task { @MainActor [weak self] in
                self?.handleCancelledApproval(approval)
            }
        }
        let accepted = approved && !Task.isCancelled
        if accepted {
            commitSessionApproval(for: approval.id)
        }
        return accepted
    }

    func approve(_ approvalId: UUID, rememberForSession: Bool = false) {
        guard !cancelledApprovals.contains(approvalId) else {
            deny(approvalId)
            return
        }
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approvalId }) else {
            return
        }

        let approval = pendingApprovals[index]

        if rememberForSession {
            let key = approvalKey(tool: approval.toolName, details: approval.details)
            pendingSessionApprovalOwners[approvalId] = key
        }

        pendingApprovals.remove(at: index)

        timeoutTasks[approvalId]?.cancel()
        timeoutTasks.removeValue(forKey: approvalId)

        removeSystemNotification(for: approvalId)

        if let continuation = approvalContinuations.removeValue(forKey: approvalId) {
            continuation.resume(returning: true)
        }
        cancelledApprovals.clear(approvalId)

        log(.info, "Approval granted", metadata: [
            "tool": approval.toolName,
            "id": approvalId.uuidString
        ])

        NotificationCenter.default.post(name: .pendingApprovalsChanged, object: nil, userInfo: [
            "conversationId": approval.conversationId,
            "count": pendingApprovals.count
        ])
    }

    func deny(_ approvalId: UUID) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approvalId }) else {
            cancelledApprovals.clear(approvalId)
            return
        }

        let approval = pendingApprovals[index]

        pendingApprovals.remove(at: index)

        timeoutTasks[approvalId]?.cancel()
        timeoutTasks.removeValue(forKey: approvalId)

        removeSystemNotification(for: approvalId)

        if let continuation = approvalContinuations.removeValue(forKey: approvalId) {
            continuation.resume(returning: false)
        }
        pendingSessionApprovalOwners.removeValue(forKey: approvalId)
        cancelledApprovals.clear(approvalId)

        log(.info, "Approval denied", metadata: [
            "tool": approval.toolName,
            "id": approvalId.uuidString
        ])

        NotificationCenter.default.post(name: .pendingApprovalsChanged, object: nil, userInfo: [
            "conversationId": approval.conversationId,
            "count": pendingApprovals.count
        ])
    }

    func approveAllPending(forConversation conversationId: UUID) {
        let toApprove = pendingApprovals.filter { $0.conversationId == conversationId }
        for approval in toApprove {
            approve(approval.id)
        }
        log(.info, "All pending approvals granted", metadata: ["count": "\(toApprove.count)"])
    }

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

    func clearSessionApprovals() {
        sessionApprovals.removeAll()
        committedSessionApprovalKeys.removeAll()
        pendingSessionApprovalOwners.removeAll()
        log(.info, "Session approvals cleared")
    }

    func pendingCount(forConversation conversationId: UUID) -> Int {
        pendingApprovals.count(where: { $0.conversationId == conversationId })
    }

    private func handleCancelledApproval(_ approval: PendingApproval) {
        if let key = pendingSessionApprovalOwners.removeValue(forKey: approval.id),
           !committedSessionApprovalKeys.contains(key),
           !pendingSessionApprovalOwners.values.contains(key)
        {
            sessionApprovals.remove(key)
        }
        deny(approval.id)
        cancelledApprovals.clear(approval.id)
    }

    private func commitSessionApproval(for approvalID: UUID) {
        guard let key = pendingSessionApprovalOwners.removeValue(forKey: approvalID) else { return }
        sessionApprovals.insert(key)
        committedSessionApprovalKeys.insert(key)
    }

    private func approvalKey(tool: String, details: String) -> String {
        "\(tool):\(details)"
    }

    private func startTimeoutTask(for approvalId: UUID) {
        let timeout = approvalTimeoutSeconds
        guard timeout > 0 else { return }
        timeoutTasks[approvalId] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                self?.deny(approvalId)
            } catch {}
        }
    }

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: "🔐 Permission: \(message)", metadata: metadata)
    }
}

extension PermissionService {
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

#if os(macOS)
    private final class ApprovalNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        weak var permissionService: PermissionService?

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
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
                    NSApp.activate(ignoringOtherApps: true)

                default:
                    break
                }
            }

            completionHandler()
        }

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound, .badge])
        }
    }
#endif
