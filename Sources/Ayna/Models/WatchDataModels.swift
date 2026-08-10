//
//  WatchDataModels.swift
//  ayna
//
//  Shared data models for Watch synchronization.
//  These types are used across macOS, iOS, and watchOS for WatchConnectivity sync.
//

import Foundation

struct WatchConversationSyncIdentity: Codable, Equatable, Sendable {
    let epoch: UUID?
    let generation: UInt64
}

struct WatchConversationClearTransaction: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let baselinePrivacyMarkerToken: String?

    init(id: UUID = UUID(), baselinePrivacyMarkerToken: String?) {
        self.id = id
        self.baselinePrivacyMarkerToken = baselinePrivacyMarkerToken
    }

    private static let notificationUserInfoKey = "watchConversationClearTransaction"

    var notificationUserInfo: [AnyHashable: Any] {
        [Self.notificationUserInfoKey: self]
    }

    init?(notification: Notification) {
        guard let transaction = notification.userInfo?[Self.notificationUserInfoKey]
            as? WatchConversationClearTransaction
        else {
            return nil
        }
        self = transaction
    }
}

struct WatchConversationSyncState: Codable, Equatable, Sendable {
    var identity: WatchConversationSyncIdentity
    var pendingClears: [WatchConversationClearTransaction]

    init(
        identity: WatchConversationSyncIdentity = .init(epoch: nil, generation: 0),
        pendingClears: [WatchConversationClearTransaction] = []
    ) {
        self.identity = identity
        self.pendingClears = pendingClears
    }

    var pendingClearCount: Int {
        pendingClears.count
    }

    @discardableResult
    mutating func beginClear(_ transaction: WatchConversationClearTransaction) -> Bool {
        guard !pendingClears.contains(where: { $0.id == transaction.id }) else { return false }
        pendingClears.append(transaction)
        return true
    }

    @discardableResult
    mutating func commitClear(id: UUID) -> Bool {
        guard pendingClears.contains(where: { $0.id == id }) else { return false }
        pendingClears.removeAll { $0.id == id }
        identity = WatchConversationSyncIdentity(
            epoch: identity.epoch,
            generation: identity.generation &+ 1
        )
        return true
    }

    @discardableResult
    mutating func rollBackClear(id: UUID) -> Bool {
        let previousCount = pendingClears.count
        pendingClears.removeAll { $0.id == id }
        return pendingClears.count != previousCount
    }
}

enum WatchConversationSyncFence {
    static func canInitiateMutation(currentEpoch: UUID?) -> Bool {
        currentEpoch != nil
    }

    static func acceptsMutation(
        incomingEpoch: UUID?,
        incomingGeneration: UInt64?,
        currentEpoch: UUID,
        currentGeneration: UInt64,
        pendingClearCount: Int
    ) -> Bool {
        guard pendingClearCount == 0 else { return false }
        if incomingEpoch == nil, incomingGeneration == nil {
            return currentGeneration == 0
        }
        guard incomingEpoch == currentEpoch, let incomingGeneration else {
            return false
        }
        return incomingGeneration == currentGeneration
    }

    static func acceptsContext(
        incomingEpoch: UUID?,
        incomingGeneration: UInt64?,
        currentEpoch: UUID?,
        currentGeneration: UInt64
    ) -> Bool {
        guard let incomingEpoch, let incomingGeneration else {
            return currentEpoch == nil && currentGeneration == 0
        }
        guard incomingEpoch == currentEpoch else { return true }
        return incomingGeneration >= currentGeneration
    }

    static func contextRequiresAuthoritativeReset(
        incomingEpoch: UUID,
        incomingGeneration: UInt64,
        currentEpoch: UUID?,
        currentGeneration: UInt64
    ) -> Bool {
        incomingEpoch != currentEpoch || incomingGeneration > currentGeneration
    }
}

/// Lightweight conversation model for Watch sync (strips heavy data like images and attachments)
struct WatchConversation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var messages: [WatchMessage]
    var model: String
    var updatedAt: Date
    var createdAt: Date

    init(from conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        model = conversation.model
        updatedAt = conversation.updatedAt
        createdAt = conversation.createdAt
        // Only include recent messages and strip attachments
        messages = conversation.messages.suffix(20).map { WatchMessage(from: $0) }
    }

    func toConversation() -> Conversation {
        var conversation = Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            model: model
        )
        conversation.updatedAt = updatedAt
        conversation.messages = messages.map { $0.toMessage() }
        return conversation
    }
}

/// Lightweight message model for Watch sync (no images or attachments)
struct WatchMessage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var model: String?

    init(from message: Message) {
        id = message.id
        role = message.role.rawValue
        content = message.content
        timestamp = message.timestamp
        model = message.model
    }

    func toMessage() -> Message {
        let messageRole: Message.Role
        if let r = Message.Role(rawValue: role) {
            messageRole = r
        } else {
            DiagnosticsLogger.log(.watchConnectivity, level: .default, message: "Invalid message role", metadata: ["role": role])
            messageRole = .assistant
        }

        return Message(
            id: id,
            role: messageRole,
            content: content,
            timestamp: timestamp,
            model: model
        )
    }
}

struct WatchConversationMutation: Codable, Equatable, Identifiable, Sendable {
    enum Payload: Codable, Equatable, Sendable {
        case newMessage(message: WatchMessage, conversationId: UUID)
        case newConversation(WatchConversation)
        case titleUpdate(conversationId: UUID, title: String)
    }

    let id: UUID
    let syncEpoch: UUID?
    let clearGeneration: UInt64?
    let payload: Payload

    init(
        id: UUID = UUID(),
        syncEpoch: UUID?,
        clearGeneration: UInt64?,
        payload: Payload
    ) {
        self.id = id
        self.syncEpoch = syncEpoch
        self.clearGeneration = clearGeneration
        self.payload = payload
    }
}
