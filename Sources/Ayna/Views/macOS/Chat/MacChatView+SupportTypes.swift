// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

struct ToolChainTimeoutContext {
    let operationID: ToolChainCoordinator.OperationID
    let assistantMessageID: UUID
    let conversationID: UUID
}

struct MacPendingAutoSendClaim {
    let conversationID: UUID
    let prompt: String

    @MainActor
    func restore(in conversationManager: ConversationManager) {
        guard let index = conversationManager.conversations.firstIndex(where: {
            $0.id == conversationID
        }) else {
            return
        }

        if conversationManager.conversations[index].pendingAutoSendPrompt == nil {
            conversationManager.conversations[index].pendingAutoSendPrompt = prompt
            conversationManager.saveImmediately(conversationManager.conversations[index])
        }
    }

    @MainActor
    func consume(
        committedPrompt: String,
        conversationID committedConversationID: UUID,
        in conversationManager: ConversationManager
    ) {
        guard committedConversationID == conversationID,
              committedPrompt == prompt
        else {
            restore(in: conversationManager)
            return
        }
        guard let index = conversationManager.conversations.firstIndex(where: {
                  $0.id == conversationID
              }),
              conversationManager.conversations[index].pendingAutoSendPrompt == prompt
        else {
            return
        }

        conversationManager.conversations[index].pendingAutoSendPrompt = nil
        conversationManager.saveImmediately(conversationManager.conversations[index])
    }
}

enum MacChatMessagePresentation {
    static func isVisible(
        _ message: Message,
        lastMessageID: UUID?,
        isGenerating: Bool
    ) -> Bool {
        if message.role == .system {
            return false
        }

        if message.role == .tool {
            let isWebSearchResult = message.toolCalls?.contains(where: {
                $0.toolName == WebSearchCoordinator.toolName
            }) == true
            return !isWebSearchResult
                && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard message.role == .assistant else {
            return !message.content.isEmpty
                || message.imageData != nil
                || message.imagePath != nil
                || message.mediaType == .image
        }

        if hasVisibleAssistantOutput(message) {
            return true
        }
        if message.toolCalls?.isEmpty == false {
            return false
        }
        if message.responseGroupId != nil {
            return true
        }
        return message.id == lastMessageID && isGenerating
    }

    static func isRemovableAssistantPlaceholder(_ message: Message) -> Bool {
        message.role == .assistant
            && !hasVisibleAssistantOutput(message)
            && message.toolCalls?.isEmpty != false
            && message.responseGroupId == nil
    }

    private static func hasVisibleAssistantOutput(_ message: Message) -> Bool {
        !message.content.isEmpty
            || message.reasoning?.isEmpty == false
            || message.imageData != nil
            || message.imagePath != nil
            || message.mediaType == .image
            || message.citations?.isEmpty == false
    }
}

struct PendingApprovalsSectionView: View {
    let conversationId: UUID
    let permissionService: PermissionService?

    private var approvals: [PendingApproval] {
        permissionService?.pendingApprovals.filter { $0.conversationId == conversationId } ?? []
    }

    var body: some View {
        Group {
            if let permService = permissionService, !approvals.isEmpty {
                VStack(spacing: 12) {
                    ForEach(approvals) { approval in
                        ApprovalRequestView(
                            approval: approval,
                            onApprove: { rememberForSession in
                                permService.approve(approval.id, rememberForSession: rememberForSession)
                            },
                            onDeny: {
                                permService.deny(approval.id)
                            },
                            pendingCount: approvals.count,
                            onApproveAll: {
                                permService.approveAllPending(forConversation: conversationId)
                            }
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
        .animation(.easeInOut(duration: 0.2), value: approvals.count)
    }
}
#endif
