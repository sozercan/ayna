import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let aynaConversation = UTType(
        exportedAs: "com.sertacozercan.ayna.conversation", conformingTo: .content
    )
}

enum SystemPromptMode: Equatable, Sendable {
    case inheritGlobal
    case custom(String)
    case disabled

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ModeType: String, Codable {
        case inheritGlobal
        case custom
        case disabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ModeType.self, forKey: .type)
        switch type {
        case .inheritGlobal:
            self = .inheritGlobal
        case .custom:
            let value = try container.decode(String.self, forKey: .value)
            self = .custom(value)
        case .disabled:
            self = .disabled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inheritGlobal:
            try container.encode(ModeType.inheritGlobal, forKey: .type)
        case let .custom(value):
            try container.encode(ModeType.custom, forKey: .type)
            try container.encode(value, forKey: .value)
        case .disabled:
            try container.encode(ModeType.disabled, forKey: .type)
        }
    }
}

extension SystemPromptMode: Codable {}

struct Conversation: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var systemPromptMode: SystemPromptMode
    var temperature: Double

    var multiModelEnabled: Bool
    var activeModels: [String]
    var responseGroups: [ResponseGroup]

    var pendingAutoSendPrompt: String?

    var metadataPreview: String?

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [Message] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        model: String = "gpt-4o",
        systemPromptMode: SystemPromptMode = .inheritGlobal,
        temperature: Double = 0.7,
        multiModelEnabled: Bool = false,
        activeModels: [String] = [],
        responseGroups: [ResponseGroup] = [],
        metadataPreview: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPromptMode = systemPromptMode
        self.temperature = temperature
        self.multiModelEnabled = multiModelEnabled
        self.activeModels = activeModels
        self.responseGroups = responseGroups
        self.metadataPreview = metadataPreview
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, model
        case systemPromptMode, temperature
        case multiModelEnabled, activeModels, responseGroups
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case systemPrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([Message].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        model = try container.decode(String.self, forKey: .model)
        if container.contains(.systemPromptMode) {
            systemPromptMode = try container.decode(SystemPromptMode.self, forKey: .systemPromptMode)
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let legacySystemPrompt = try legacyContainer.decodeIfPresent(String.self, forKey: .systemPrompt),
               !legacySystemPrompt.isEmpty
            {
                systemPromptMode = .custom(legacySystemPrompt)
            } else {
                systemPromptMode = .inheritGlobal
            }
        }
        temperature = try container.decode(Double.self, forKey: .temperature)
        multiModelEnabled = try container.decodeIfPresent(Bool.self, forKey: .multiModelEnabled) ?? false
        activeModels = try container.decodeIfPresent([String].self, forKey: .activeModels) ?? []
        responseGroups = try container.decodeIfPresent([ResponseGroup].self, forKey: .responseGroups) ?? []
        metadataPreview = nil
    }

    mutating func addMessage(_ message: Message) {
        messages.append(message)
        updatedAt = Date()
    }

    mutating func updateLastMessage(_ content: String) {
        if var lastMessage = messages.last {
            lastMessage.content = content
            messages[messages.count - 1] = lastMessage
            updatedAt = Date()
        }
    }

    func getEffectiveHistory() -> [Message] {
        var messagesByID: [UUID: Message] = [:]
        for message in messages where messagesByID[message.id] == nil {
            messagesByID[message.id] = message
        }

        var groupsByID: [UUID: ResponseGroup] = [:]
        var chosenMessageIDByGroupID: [UUID: UUID] = [:]
        for group in responseGroups where groupsByID[group.id] == nil {
            groupsByID[group.id] = group
            if let messageID = effectiveResponseMessageID(in: group, messagesByID: messagesByID) {
                chosenMessageIDByGroupID[group.id] = messageID
            }
        }

        return messages.filter { message in
            guard message.role != .assistant || message.hasMeaningfulHistoryContent else {
                return false
            }

            guard let groupID = message.responseGroupId else {
                return message.isSelectedResponse != false
            }

            guard groupsByID[groupID] != nil else {
                return message.isSelectedResponse != false
            }

            return chosenMessageIDByGroupID[groupID] == message.id
        }
    }

    private func effectiveResponseMessageID(
        in group: ResponseGroup,
        messagesByID: [UUID: Message]
    ) -> UUID? {
        func meaningfulMessageID(for entry: ResponseGroupEntry) -> UUID? {
            guard let message = messagesByID[entry.id],
                  message.responseGroupId == group.id,
                  message.role == .assistant,
                  message.hasMeaningfulHistoryContent
            else {
                return nil
            }
            return message.id
        }

        if let selectedResponseID = group.selectedResponseId,
           let selectedEntry = group.responses.first(where: { $0.id == selectedResponseID }),
           selectedEntry.status == .selected || selectedEntry.status == .completed,
           let selectedMessageID = meaningfulMessageID(for: selectedEntry)
        {
            return selectedMessageID
        }

        for entry in group.responses where entry.status == .selected {
            if let selectedMessageID = meaningfulMessageID(for: entry) {
                return selectedMessageID
            }
        }

        for entry in group.responses
            where entry.modelName == model && (entry.status == .selected || entry.status == .completed)
        {
            if let defaultModelMessageID = meaningfulMessageID(for: entry) {
                return defaultModelMessageID
            }
        }

        for entry in group.responses where entry.status == .completed {
            if let completedMessageID = meaningfulMessageID(for: entry) {
                return completedMessageID
            }
        }

        if let selectedResponseID = group.selectedResponseId,
           let selectedEntry = group.responses.first(where: {
               $0.id == selectedResponseID && $0.status == .failed
           }),
           let selectedMessageID = meaningfulMessageID(for: selectedEntry)
        {
            return selectedMessageID
        }

        for entry in group.responses where entry.modelName == model && entry.status == .failed {
            if let defaultModelMessageID = meaningfulMessageID(for: entry) {
                return defaultModelMessageID
            }
        }

        for entry in group.responses where entry.status == .failed {
            if let failedMessageID = meaningfulMessageID(for: entry) {
                return failedMessageID
            }
        }

        return nil
    }

    mutating func removeFailedResponseGroups(for userMessageId: UUID) {
        let failedGroupIDs = Set<UUID>(responseGroups.compactMap { existingGroup in
            guard existingGroup.userMessageId == userMessageId,
                  !existingGroup.responses.isEmpty,
                  existingGroup.responses.allSatisfy({ $0.status == .failed })
            else {
                return nil
            }
            return existingGroup.id
        })
        guard !failedGroupIDs.isEmpty else { return }

        messages.removeAll { message in
            guard let responseGroupId = message.responseGroupId else { return false }
            return failedGroupIDs.contains(responseGroupId)
        }
        responseGroups.removeAll { failedGroupIDs.contains($0.id) }
        updatedAt = Date()
    }

    mutating func addResponseGroup(_ group: ResponseGroup) {
        responseGroups.append(group)
        updatedAt = Date()
    }

    mutating func selectResponse(in groupId: UUID, messageId: UUID) {
        if let index = responseGroups.firstIndex(where: { $0.id == groupId }) {
            let previousSelection = responseGroups[index].selectedResponseId
            responseGroups[index].selectResponse(messageId)

            for msgIndex in messages.indices where messages[msgIndex].responseGroupId == groupId {
                let isNewSelection = messages[msgIndex].id == messageId
                let wasPreviousSelection = messages[msgIndex].id == previousSelection

                messages[msgIndex].isSelectedResponse = isNewSelection

                #if !os(watchOS)
                    if isNewSelection, let pendingCalls = messages[msgIndex].pendingToolCalls {
                        messages[msgIndex].toolCalls = pendingCalls
                        messages[msgIndex].pendingToolCalls = nil
                    }
                    if wasPreviousSelection, previousSelection != nil {
                        messages[msgIndex].toolCalls = nil
                    }
                #endif
            }

            updatedAt = Date()
        }
    }

    func getResponseGroup(_ groupId: UUID) -> ResponseGroup? {
        responseGroups.first { $0.id == groupId }
    }

    mutating func updateResponseGroup(_ group: ResponseGroup) {
        if let index = responseGroups.firstIndex(where: { $0.id == group.id }) {
            responseGroups[index] = group
            updatedAt = Date()
        }
    }
}

extension Message {
    var hasMeaningfulNonToolTranscriptContent: Bool {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let reasoning,
           !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        if !(citations?.isEmpty ?? true) {
            return true
        }
        if let imageData, !imageData.isEmpty {
            return true
        }
        if let imagePath,
           !imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        if attachments?.contains(where: { attachment in
            if let data = attachment.data, !data.isEmpty {
                return true
            }
            if let localPath = attachment.localPath,
               !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
            return false
        }) == true {
            return true
        }
        return false
    }

    var hasMeaningfulHistoryContent: Bool {
        hasMeaningfulNonToolTranscriptContent || !(toolCalls?.isEmpty ?? true)
    }
}

extension Conversation: Codable {}

extension Conversation {
    var attachmentPaths: [String] {
        var paths: Set<String> = []
        for message in messages {
            if let imagePath = message.imagePath {
                paths.insert(imagePath)
            }
            for attachment in message.attachments ?? [] {
                if let localPath = attachment.localPath {
                    paths.insert(localPath)
                }
            }
        }
        return paths.sorted()
    }
}
