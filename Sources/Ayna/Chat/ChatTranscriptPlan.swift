//
//  ChatTranscriptPlan.swift
//  ayna
//
//  Plans the transcript items that chat views should render.
//

import Foundation

/// How a visible message should be interpreted by transcript renderers.
enum ChatTranscriptDisplayKind: Equatable, Sendable {
    case text
    case toolResult
    case typingPlaceholder
    case image
    case citationsOnly
}

/// A visible transcript message plus the display semantics used to make it visible.
struct ChatTranscriptMessage: Identifiable, Equatable, Sendable {
    let message: Message
    let displayKind: ChatTranscriptDisplayKind

    var id: UUID { message.id }
}

/// A visible group of parallel model responses.
struct ChatTranscriptResponseGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let responses: [ChatTranscriptMessage]
    let selectedResponseId: UUID?
    let defaultCandidateId: UUID?

    var messages: [Message] {
        responses.map(\.message)
    }
}

/// Represents either a single visible message or one grouped set of parallel responses.
enum ChatTranscriptItem: Identifiable, Equatable, Sendable {
    case message(ChatTranscriptMessage)
    case responseGroup(ChatTranscriptResponseGroup)

    var id: String {
        switch self {
        case let .message(item):
            item.message.id.uuidString
        case let .responseGroup(group):
            "group-\(group.id.uuidString)"
        }
    }
}

/// A response that should be auto-selected if the user continues from an unselected group.
struct ChatTranscriptResponseSelection: Equatable, Sendable {
    let groupId: UUID
    let messageId: UUID
}

/// Pure display plan for a conversation transcript.
///
/// This Module centralizes the shared transcript rules that macOS and iOS views
/// need to agree on: which messages are visible, how response groups are
/// represented, and which grouped response is the default continuation choice.
struct ChatTranscriptPlan: Equatable, Sendable {
    let visibleMessages: [ChatTranscriptMessage]
    let items: [ChatTranscriptItem]
    let pendingAutoSelection: ChatTranscriptResponseSelection?

    init(conversation: Conversation, isGenerating: Bool) {
        visibleMessages = conversation.messages.compactMap { message in
            Self.visibleMessage(for: message, in: conversation, isGenerating: isGenerating)
        }
        items = Self.makeItems(from: visibleMessages, in: conversation)
        pendingAutoSelection = Self.autoSelectionCandidate(in: conversation)
    }

    static func defaultCandidateId(
        for responses: [Message],
        in conversation: Conversation,
        responseGroup: ResponseGroup? = nil
    ) -> UUID? {
        let selectableResponses = responses.filter { message in
            guard let responseGroup,
                  let entry = responseGroup.responses.first(where: { $0.id == message.id })
            else {
                return true
            }
            return entry.status != .streaming && entry.status != .failed
        }
        let candidates = selectableResponses.isEmpty ? responses : selectableResponses

        if let match = candidates.first(where: { $0.model == conversation.model }) {
            return match.id
        }
        return candidates.first?.id
    }

    static func autoSelectionCandidate(in conversation: Conversation) -> ChatTranscriptResponseSelection? {
        guard let lastMessage = conversation.messages.last,
              let groupId = lastMessage.responseGroupId,
              let group = conversation.getResponseGroup(groupId),
              group.selectedResponseId == nil
        else {
            return nil
        }

        let responses = conversation.messages.filter { $0.responseGroupId == groupId }
        guard let messageId = defaultCandidateId(
            for: responses,
            in: conversation,
            responseGroup: group
        ) else {
            return nil
        }
        return ChatTranscriptResponseSelection(groupId: groupId, messageId: messageId)
    }

    private static func visibleMessage(
        for message: Message,
        in conversation: Conversation,
        isGenerating: Bool
    ) -> ChatTranscriptMessage? {
        guard let displayKind = displayKind(for: message, in: conversation, isGenerating: isGenerating) else {
            return nil
        }
        return ChatTranscriptMessage(message: message, displayKind: displayKind)
    }

    private static func displayKind(
        for message: Message,
        in conversation: Conversation,
        isGenerating: Bool
    ) -> ChatTranscriptDisplayKind? {
        if message.role == .system {
            return nil
        }

        if message.role == .tool {
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .toolResult
        }

        if message.imageData != nil || message.imagePath != nil {
            return .image
        }

        if message.mediaType == .image {
            if message.responseGroupId != nil {
                return .image
            }

            let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if message.role == .assistant, !hasContent {
                return message.id == conversation.messages.last?.id && isGenerating ? .image : nil
            }
            return hasContent ? .text : nil
        }

        if message.role == .assistant, let citations = message.citations, !citations.isEmpty {
            if message.content.isEmpty {
                return message.id == conversation.messages.last?.id && isGenerating ? .typingPlaceholder : .citationsOnly
            }
            return .text
        }

        if message.role == .assistant, message.content.isEmpty {
            #if !os(watchOS)
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    return nil
                }
            #endif

            if message.responseGroupId != nil {
                return .typingPlaceholder
            }

            return message.id == conversation.messages.last?.id && isGenerating ? .typingPlaceholder : nil
        }

        return message.content.isEmpty ? nil : .text
    }

    private static func makeItems(
        from visibleMessages: [ChatTranscriptMessage],
        in conversation: Conversation
    ) -> [ChatTranscriptItem] {
        var items: [ChatTranscriptItem] = []
        var processedGroupIds: Set<UUID> = []

        for item in visibleMessages {
            let message = item.message
            if let groupId = message.responseGroupId {
                guard !processedGroupIds.contains(groupId) else { continue }
                processedGroupIds.insert(groupId)

                let groupResponses = visibleMessages.filter { $0.message.responseGroupId == groupId }
                let responseGroup = conversation.getResponseGroup(groupId)
                items.append(.responseGroup(ChatTranscriptResponseGroup(
                    id: groupId,
                    responses: groupResponses,
                    selectedResponseId: responseGroup?.selectedResponseId,
                    defaultCandidateId: defaultCandidateId(
                        for: groupResponses.map(\.message),
                        in: conversation,
                        responseGroup: responseGroup
                    )
                )))
            } else {
                items.append(.message(item))
            }
        }

        return items
    }
}
