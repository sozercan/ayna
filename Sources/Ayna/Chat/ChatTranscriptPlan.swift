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

    var id: UUID {
        message.id
    }
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
            item.id.uuidString
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
struct ChatTranscriptPlan: Equatable, Sendable {
    let visibleMessages: [ChatTranscriptMessage]
    let items: [ChatTranscriptItem]
    let pendingAutoSelection: ChatTranscriptResponseSelection?

    init(conversation: Conversation, isGenerating: Bool) {
        let responseGroupsByID = conversation.responseGroups.reduce(into: [UUID: ResponseGroup]()) { result, group in
            if result[group.id] == nil {
                result[group.id] = group
            }
        }
        visibleMessages = conversation.messages.compactMap { message in
            Self.visibleMessage(for: message, in: conversation, isGenerating: isGenerating)
        }
        items = Self.makeItems(
            from: visibleMessages,
            in: conversation,
            responseGroupsByID: responseGroupsByID
        )
        pendingAutoSelection = Self.autoSelectionCandidate(in: conversation)
    }

    static func defaultCandidateId(
        for responses: [Message],
        in conversation: Conversation,
        responseGroup: ResponseGroup? = nil
    ) -> UUID? {
        let responseEntriesByID = responseGroup?.responses.reduce(into: [UUID: ResponseGroupEntry]()) { result, entry in
            if result[entry.id] == nil {
                result[entry.id] = entry
            }
        } ?? [:]
        let meaningfulResponses = responses.filter(\.hasMeaningfulHistoryContent)
        let contentCandidates = meaningfulResponses.isEmpty ? responses : meaningfulResponses
        let selectableResponses = contentCandidates.filter { message in
            guard responseGroup != nil,
                  let entry = responseEntriesByID[message.id]
            else {
                return true
            }
            return entry.status != .streaming && entry.status != .failed
        }
        let candidates = selectableResponses.isEmpty ? contentCandidates : selectableResponses

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
            let isWebSearchResult = message.toolCalls?.contains(where: {
                $0.toolName == WebSearchCoordinator.toolName
            }) == true
            guard !isWebSearchResult else { return nil }
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .toolResult
        }

        if message.imageData != nil || message.imagePath != nil {
            return .image
        }

        if message.role == .user, message.attachments?.isEmpty == false {
            return .text
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

        if message.role == .assistant,
           let reasoning = message.reasoning,
           !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .text
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
        in conversation: Conversation,
        responseGroupsByID: [UUID: ResponseGroup]
    ) -> [ChatTranscriptItem] {
        let messagesByID = visibleMessages.reduce(into: [UUID: ChatTranscriptMessage]()) { result, item in
            result[item.id] = item
        }

        return DisplayableMessageGrouper.items(from: visibleMessages.map(\.message)).compactMap { groupedItem in
            switch groupedItem {
            case let .message(message):
                guard let item = messagesByID[message.id] else { return nil }
                return .message(item)
            case let .responseGroup(groupId, responses):
                let responseItems = responses.compactMap { messagesByID[$0.id] }
                let responseGroup = responseGroupsByID[groupId]
                return .responseGroup(ChatTranscriptResponseGroup(
                    id: groupId,
                    responses: responseItems,
                    selectedResponseId: responseGroup?.selectedResponseId,
                    defaultCandidateId: defaultCandidateId(
                        for: responses,
                        in: conversation,
                        responseGroup: responseGroup
                    )
                ))
            }
        }
    }
}
