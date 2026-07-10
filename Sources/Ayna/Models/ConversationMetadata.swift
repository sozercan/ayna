//
//  ConversationMetadata.swift
//  ayna
//
//  Lightweight persisted conversation list metadata.
//

import Foundation

struct ConversationMetadata: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var systemPromptMode: SystemPromptMode
    var temperature: Double
    var multiModelEnabled: Bool
    var activeModels: [String]
    var messageCount: Int
    var responseGroupCount: Int
    var lastMessagePreview: String
    var searchableText: String
    var requiresBackfill: Bool

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        model: String,
        systemPromptMode: SystemPromptMode,
        temperature: Double,
        multiModelEnabled: Bool,
        activeModels: [String],
        messageCount: Int,
        responseGroupCount: Int,
        lastMessagePreview: String = "",
        searchableText: String = "",
        requiresBackfill: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPromptMode = systemPromptMode
        self.temperature = temperature
        self.multiModelEnabled = multiModelEnabled
        self.activeModels = activeModels
        self.messageCount = messageCount
        self.responseGroupCount = responseGroupCount
        self.lastMessagePreview = lastMessagePreview
        self.searchableText = searchableText
        self.requiresBackfill = requiresBackfill
    }

    init(conversation: Conversation) {
        self.init(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            model: conversation.model,
            systemPromptMode: conversation.systemPromptMode,
            temperature: conversation.temperature,
            multiModelEnabled: conversation.multiModelEnabled,
            activeModels: conversation.activeModels,
            messageCount: conversation.messages.count,
            responseGroupCount: conversation.responseGroups.count,
            lastMessagePreview: Self.previewText(from: conversation),
            searchableText: Self.searchText(from: conversation)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, model
        case systemPromptMode, temperature, multiModelEnabled, activeModels
        case messageCount, responseGroupCount, lastMessagePreview, searchableText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        model = try container.decode(String.self, forKey: .model)
        systemPromptMode = try container.decode(SystemPromptMode.self, forKey: .systemPromptMode)
        temperature = try container.decode(Double.self, forKey: .temperature)
        multiModelEnabled = try container.decode(Bool.self, forKey: .multiModelEnabled)
        activeModels = try container.decode([String].self, forKey: .activeModels)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        responseGroupCount = try container.decode(Int.self, forKey: .responseGroupCount)
        let decodedPreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        let decodedSearchText = try container.decodeIfPresent(String.self, forKey: .searchableText)
        lastMessagePreview = decodedPreview ?? ""
        searchableText = decodedSearchText ?? title
        requiresBackfill = messageCount > 0 && (decodedPreview == nil || decodedSearchText == nil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(model, forKey: .model)
        try container.encode(systemPromptMode, forKey: .systemPromptMode)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(multiModelEnabled, forKey: .multiModelEnabled)
        try container.encode(activeModels, forKey: .activeModels)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encode(responseGroupCount, forKey: .responseGroupCount)
        try container.encode(lastMessagePreview, forKey: .lastMessagePreview)
        try container.encode(searchableText, forKey: .searchableText)
    }

    private static func previewText(from conversation: Conversation) -> String {
        let previewSource = conversation.messages.last
        guard let content = previewSource?.content, !content.isEmpty else { return "" }
        return String(content.prefix(240))
    }

    private static func searchText(from conversation: Conversation) -> String {
        let maxSearchTextLength = 12000
        let headCount = maxSearchTextLength / 2
        let tailCount = maxSearchTextLength - headCount
        var completeText = ""
        completeText.reserveCapacity(maxSearchTextLength)
        var completeTextCount = 0
        var head = ""
        head.reserveCapacity(headCount)
        var headCharacterCount = 0
        var tail = ""
        tail.reserveCapacity(tailCount)
        var tailCharacterCount = 0
        var exceededLimit = false

        func append(_ segment: String) {
            let segmentCount = segment.count

            if !exceededLimit {
                if completeTextCount + segmentCount <= maxSearchTextLength {
                    completeText.append(segment)
                    completeTextCount += segmentCount
                } else {
                    exceededLimit = true
                    completeText.removeAll(keepingCapacity: false)
                }
            }

            let remainingHeadCount = headCount - headCharacterCount
            if remainingHeadCount > 0 {
                head.append(contentsOf: segment.prefix(remainingHeadCount))
                headCharacterCount += min(segmentCount, remainingHeadCount)
            }

            if segmentCount >= tailCount {
                tail = String(segment.suffix(tailCount))
                tailCharacterCount = tailCount
            } else {
                tail.append(segment)
                tailCharacterCount += segmentCount
                let overflow = tailCharacterCount - tailCount
                if overflow > 0 {
                    tail.removeFirst(overflow)
                    tailCharacterCount -= overflow
                }
            }
        }

        append(conversation.title)
        for message in conversation.messages {
            append("\n")
            append(message.content)
        }

        return exceededLimit ? "\(head)\n…\n\(tail)" : completeText
    }
}
