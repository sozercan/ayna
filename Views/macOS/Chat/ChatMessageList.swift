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
    @Binding var isNearBottom: Bool
    @Binding var showScrollToBottom: Bool

    let onRetryMessage: (Message) -> Void
    let onSwitchModelAndRetry: (Message, String) -> Void
    let onSelectResponse: (UUID, UUID) -> Void

    @EnvironmentObject var conversationManager: ConversationManager

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
                        .onAppear {
                            isNearBottom = true
                            showScrollToBottom = false
                        }
                        .onDisappear {
                            isNearBottom = false
                            showScrollToBottom = true
                        }
                }
                .padding(.horizontal, Spacing.contentPadding)
                .padding(.vertical, Spacing.contentPadding)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.messages.count) { _, _ in
                scrollToBottomIfNeeded(proxy: proxy)
            }
            .onChange(of: conversation.messages.last?.content) { _, _ in
                if isGenerating && isNearBottom {
                    scrollToLastMessage(proxy: proxy)
                }
            }
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

    private func scrollToBottomIfNeeded(proxy: ScrollViewProxy) {
        guard isNearBottom else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(isGenerating ? 150 : 0))
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

    private func scrollToLastMessage(proxy: ScrollViewProxy) {
        Task { @MainActor in
            if let lastMessage = conversation.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}

/// Helper to update displayable items from visible messages
struct DisplayableItemsBuilder {
    /// Updates cached displayable items from visible messages
    static func buildDisplayableItems(
        from messages: [Message],
        conversation: Conversation,
        isGenerating: Bool
    ) -> [DisplayableItem] {
        let visibleMessages = messages.filter { message in
            // Hide system messages entirely
            if message.role == .system {
                return false
            }

            // Always show tool messages when they have content
            if message.role == .tool {
                return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            // Always show assistant messages that have citations (from web search)
            if message.role == .assistant, let citations = message.citations, !citations.isEmpty {
                return true
            }

            // Show if: has content, has image data, or is generating image
            if message.role == .assistant && message.content.isEmpty && message.imageData == nil && message.imagePath == nil {
                // Hide assistant messages that only have tool calls (intermediate steps)
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    return false
                }
                // Always show assistant messages in a response group (multi-model mode)
                if message.responseGroupId != nil {
                    return true
                }
                // Only show empty assistant message if it's the last message and we're generating
                return message.id == messages.last?.id && isGenerating
            }

            return !message.content.isEmpty || message.imageData != nil || message.imagePath != nil || message.mediaType == .image
        }

        var items: [DisplayableItem] = []
        var processedGroupIds: Set<UUID> = []

        for message in visibleMessages {
            if let groupId = message.responseGroupId {
                guard !processedGroupIds.contains(groupId) else { continue }
                processedGroupIds.insert(groupId)

                let groupResponses = visibleMessages.filter { $0.responseGroupId == groupId }
                items.append(.responseGroup(groupId: groupId, responses: groupResponses))
            } else {
                items.append(.message(message))
            }
        }

        return items
    }
}
