#if os(macOS)
//
//  ChatMessageList.swift
//  ayna
//
//  Extracted from MacChatView.swift - Message list/scroll view component
//

import SwiftUI

/// Represents either a single message or a group of parallel responses
enum DisplayableItem: Identifiable {
    case message(Message)
    case responseGroup(groupId: UUID, responses: [Message])

    var id: String {
        switch self {
        case let .message(msg):
            msg.id.uuidString
        case let .responseGroup(groupId, _):
            "group-\(groupId.uuidString)"
        }
    }
}

/// The scrollable message list area showing conversation messages
struct ChatMessageList: View {
    let displayableItems: [DisplayableItem]
    let conversation: Conversation
    let isGenerating: Bool
    @Binding var isToolSectionExpanded: Bool

    let onRetryMessage: (Message) -> Void
    let onSwitchModelAndRetry: (Message, String) -> Void
    let onSelectResponse: (_ groupId: UUID, _ messageId: UUID) -> Void
    let onEditMessage: (Message, String) -> Void
    let onAppearAction: () -> Void
    let onConversationChange: () -> Void
    let onMessagesChange: () -> Void
    let onModelChange: () -> Void
    let onGeneratingChange: () -> Void

    @State private var isNearBottom = true
    @State private var showScrollToBottom = false
    @State private var scrollDebounceTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(displayableItems) { item in
                        switch item {
                        case let .message(message):
                            MacMessageView(
                                message: message,
                                modelName: message.model,
                                onRetry: message.role == .assistant ? { onRetryMessage(message) } : nil,
                                onSwitchModel: message.role == .assistant
                                    ? { newModel in onSwitchModelAndRetry(message, newModel) }
                                    : nil,
                                onEdit: message.role == .user
                                    ? { newContent in onEditMessage(message, newContent) }
                                    : nil
                            )
                            .id(message.id)

                        case let .responseGroup(groupId, responses):
                            MultiModelResponseView(
                                responseGroupId: groupId,
                                responses: responses,
                                conversation: conversation,
                                onSelectResponse: { messageId in
                                    onSelectResponse(groupId, messageId)
                                },
                                onRetry: { message in
                                    onRetryMessage(message)
                                }
                            )
                            .id(item.id)
                        }
                    }

                    // Anchor for scroll position detection
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { isNearBottom = true; showScrollToBottom = false }
                        .onDisappear { isNearBottom = false; showScrollToBottom = true }
                }
                .padding(.horizontal, Spacing.contentPadding)
                .padding(.vertical, Spacing.contentPadding)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.messages.count) { _, _ in
                scrollDebounceTask?.cancel()
                scrollDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(isGenerating ? 150 : 0))
                    guard !Task.isCancelled, isNearBottom else { return }
                    if let lastMessage = conversation.messages.last {
                        if isGenerating {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        } else {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .onAppear {
                onAppearAction()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    if let lastMessage = conversation.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .onDisappear {
                scrollDebounceTask?.cancel()
            }
            .onChange(of: conversation.id) { _, _ in
                onConversationChange()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    if let lastMessage = conversation.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: conversation.messages) { _, _ in
                onMessagesChange()
            }
            .onChange(of: conversation.messages.last?.content) { _, _ in
                if isGenerating {
                    Task { @MainActor in
                        guard isNearBottom else { return }
                        if let lastMessage = conversation.messages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: conversation.model) { _, _ in
                onModelChange()
            }
            .onChange(of: isGenerating) { _, _ in
                onGeneratingChange()
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    if isToolSectionExpanded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isToolSectionExpanded = false
                        }
                    }
                }
            )
            // Overlay scroll-to-bottom button inside ScrollViewReader so we can use proxy
            .overlay(alignment: .bottom) {
                MacScrollToBottomButton(
                    isVisible: showScrollToBottom && !isGenerating,
                    unreadCount: 0
                ) {
                    withAnimation(Motion.springStandard) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .padding(.bottom, Spacing.md)
            }
        }
    }
}
#endif
