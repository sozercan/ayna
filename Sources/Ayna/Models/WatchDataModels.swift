//
//  WatchDataModels.swift
//  ayna
//
//  Shared data models for Watch synchronization.
//  These types are used across macOS, iOS, and watchOS for WatchConnectivity sync.
//

import Foundation

/// Compact phone-authoritative request settings for a conversation whose body is omitted.
struct WatchConversationRequestConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var model: String
    var temperature: Double
    var resolvedSystemPrompt: String?

    init(
        id: UUID,
        model: String,
        temperature: Double,
        resolvedSystemPrompt: String?
    ) {
        self.id = id
        self.model = model
        self.temperature = temperature
        self.resolvedSystemPrompt = resolvedSystemPrompt?.nilIfEmpty
    }

    init(from conversation: Conversation, resolvedSystemPrompt: String?) {
        self.init(
            id: conversation.id,
            model: conversation.model,
            temperature: conversation.temperature,
            resolvedSystemPrompt: resolvedSystemPrompt
        )
    }

    func apply(to conversation: inout WatchConversation) {
        guard conversation.id == id else { return }
        conversation.model = model
        conversation.temperature = temperature
        conversation.resolvedSystemPrompt = resolvedSystemPrompt?.nilIfEmpty
    }
}

/// Lightweight conversation model for Watch sync.
///
/// The model intentionally carries the resolved prompt and temperature needed to make
/// requests on Watch, while omitting phone-only state such as prompt inheritance mode,
/// pending auto-send prompts, attachments, and multi-model response bookkeeping.
struct WatchConversation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var messages: [WatchMessage]
    var model: String
    var updatedAt: Date
    var createdAt: Date
    var temperature: Double
    var resolvedSystemPrompt: String?
    var watchRevision: UInt64

    init(
        id: UUID,
        title: String,
        messages: [WatchMessage] = [],
        model: String,
        updatedAt: Date,
        createdAt: Date,
        temperature: Double = 0.7,
        resolvedSystemPrompt: String? = nil,
        watchRevision: UInt64 = 0
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.model = model
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.temperature = temperature
        self.resolvedSystemPrompt = resolvedSystemPrompt
        self.watchRevision = watchRevision
    }

    init(
        from conversation: Conversation,
        watchRevision: UInt64 = 0,
        maximumMessages: Int = 20
    ) {
        self.init(
            from: conversation,
            resolvedSystemPrompt: Self.resolveSystemPrompt(for: conversation),
            watchRevision: watchRevision,
            maximumMessages: maximumMessages
        )
    }

    init(
        from conversation: Conversation,
        resolvedSystemPrompt: String?,
        watchRevision: UInt64 = 0,
        maximumMessages: Int = 20
    ) {
        id = conversation.id
        title = conversation.title
        model = conversation.model
        updatedAt = conversation.updatedAt
        createdAt = conversation.createdAt
        temperature = conversation.temperature
        self.resolvedSystemPrompt = resolvedSystemPrompt?.nilIfEmpty
        self.watchRevision = watchRevision

        let history = conversation.getEffectiveHistory()
        messages = history.suffix(max(0, maximumMessages)).map { WatchMessage(from: $0) }
    }

    /// Converts the shared Watch state back into a new phone conversation.
    /// Existing phone conversations should instead be updated through
    /// ``PhoneWatchMutationReducer`` so phone-only state is preserved.
    func toConversation() -> Conversation {
        var conversation = Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            model: model,
            systemPromptMode: .inheritGlobal,
            temperature: temperature
        )
        conversation.updatedAt = updatedAt
        conversation.messages = messages.map { $0.toMessage() }
        return conversation
    }

    /// Request-ready effective history. The conversation's resolved prompt is prepended
    /// as a stable synthetic system message and the remaining messages are already the
    /// phone conversation's effective (selected-response) history.
    var effectiveHistory: [Message] {
        var history = messages.map { $0.toMessage() }
        if let resolvedSystemPrompt = resolvedSystemPrompt?.nilIfEmpty {
            history.insert(
                Message(
                    id: id,
                    role: .system,
                    content: resolvedSystemPrompt,
                    timestamp: createdAt
                ),
                at: 0
            )
        }
        return history
    }

    private static func resolveSystemPrompt(for conversation: Conversation) -> String? {
        switch conversation.systemPromptMode {
        case .inheritGlobal:
            AppPreferences.globalSystemPrompt.nilIfEmpty
        case let .custom(prompt):
            prompt.nilIfEmpty
        case .disabled:
            nil
        }
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case messages
        case model
        case updatedAt
        case createdAt
        case temperature
        case resolvedSystemPrompt
        case watchRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([WatchMessage].self, forKey: .messages)
        model = try container.decode(String.self, forKey: .model)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        resolvedSystemPrompt = try container.decodeIfPresent(String.self, forKey: .resolvedSystemPrompt)?.nilIfEmpty
        watchRevision = try container.decodeIfPresent(UInt64.self, forKey: .watchRevision) ?? 0
    }
}

/// A revisioned phone-authoritative snapshot.
///
/// Conversation bodies, authoritative IDs, and compact request configurations are bounded
/// independently. Body or page omission is not deletion; absence is authoritative only when
/// the ID manifest is explicitly complete. Tombstones always remain authoritative.
struct WatchSyncSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    static func supportsSchemaVersion(_ schemaVersion: Int) -> Bool {
        schemaVersion > 0 && schemaVersion <= currentSchemaVersion
    }

    var schemaVersion: Int
    var sourceID: UUID
    var revision: WatchSyncRevision
    var paginationCursor: WatchSyncRevision
    var conversations: [WatchConversation]
    var authoritativeConversationIDs: [UUID]
    var authoritativeConversationIDsAreComplete: Bool
    var conversationConfigurations: [WatchConversationRequestConfiguration]
    var conversationConfigurationsAreComplete: Bool
    var acknowledgedPeerID: UUID?
    var acknowledgedWatchRevisions: [UUID: WatchSyncRevision]
    var tombstones: [WatchConversationTombstone]

    var snapshotRevision: WatchSyncRevision {
        get { revision }
        set { revision = newValue }
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceID: UUID = WatchSyncIdentity.legacySourceID,
        revision: WatchSyncRevision,
        paginationCursor: WatchSyncRevision? = nil,
        conversations: [WatchConversation],
        authoritativeConversationIDs: [UUID],
        authoritativeConversationIDsAreComplete: Bool = true,
        conversationConfigurations: [WatchConversationRequestConfiguration] = [],
        conversationConfigurationsAreComplete: Bool = false,
        acknowledgedPeerID: UUID? = WatchSyncIdentity.legacyPeerID,
        acknowledgedWatchRevisions: [UUID: WatchSyncRevision] = [:],
        tombstones: [WatchConversationTombstone] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.revision = revision
        self.paginationCursor = paginationCursor ?? Self.defaultPaginationCursor(for: revision)
        self.conversations = WatchConversationCanonicalizer.watchConversations(conversations)
        self.authoritativeConversationIDs = WatchConversationCanonicalizer.uniqueIDs(
            authoritativeConversationIDs
        )
        self.authoritativeConversationIDsAreComplete = authoritativeConversationIDsAreComplete
        self.conversationConfigurations = WatchConversationCanonicalizer.requestConfigurations(
            conversationConfigurations
        )
        self.conversationConfigurationsAreComplete = conversationConfigurationsAreComplete
        self.acknowledgedPeerID = acknowledgedPeerID
        self.acknowledgedWatchRevisions = acknowledgedWatchRevisions
        self.tombstones = tombstones.sorted(by: Self.tombstoneSort)
    }

    init(
        snapshotRevision: WatchSyncRevision,
        sourceID: UUID = WatchSyncIdentity.legacySourceID,
        paginationCursor: WatchSyncRevision? = nil,
        conversations: [WatchConversation],
        authoritativeConversationIDs: [UUID],
        authoritativeConversationIDsAreComplete: Bool = true,
        conversationConfigurations: [WatchConversationRequestConfiguration] = [],
        conversationConfigurationsAreComplete: Bool = false,
        acknowledgedPeerID: UUID? = WatchSyncIdentity.legacyPeerID,
        acknowledgedWatchRevisions: [UUID: WatchSyncRevision] = [:],
        tombstoneRevisions: [UUID: WatchSyncRevision] = [:]
    ) {
        self.init(
            sourceID: sourceID,
            revision: snapshotRevision,
            paginationCursor: paginationCursor,
            conversations: conversations,
            authoritativeConversationIDs: authoritativeConversationIDs,
            authoritativeConversationIDsAreComplete: authoritativeConversationIDsAreComplete,
            conversationConfigurations: conversationConfigurations,
            conversationConfigurationsAreComplete: conversationConfigurationsAreComplete,
            acknowledgedPeerID: acknowledgedPeerID,
            acknowledgedWatchRevisions: acknowledgedWatchRevisions,
            tombstones: tombstoneRevisions.map {
                WatchConversationTombstone(conversationID: $0.key, revision: $0.value)
            }
        )
    }

    func acknowledgedRevision(for conversationID: UUID) -> WatchSyncRevision {
        acknowledgedWatchRevisions[conversationID] ?? 0
    }

    func tombstoneRevision(for conversationID: UUID) -> WatchSyncRevision? {
        tombstones
            .filter { $0.conversationID == conversationID }
            .map(\.revision)
            .max()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceID
        case revision
        case snapshotRevision
        case paginationCursor
        case conversations
        case authoritativeConversationIDs
        case authoritativeConversationIDsAreComplete
        case conversationConfigurations
        case conversationConfigurationsAreComplete
        case acknowledgedPeerID
        case acknowledgedWatchRevisions
        case tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.schemaVersion) {
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        } else {
            schemaVersion = 1
        }
        sourceID = try container.decodeIfPresent(UUID.self, forKey: .sourceID)
            ?? WatchSyncIdentity.legacySourceID
        revision = try container.decodeIfPresent(WatchSyncRevision.self, forKey: .revision)
            ?? container.decodeIfPresent(WatchSyncRevision.self, forKey: .snapshotRevision)
            ?? 0
        paginationCursor = try container.decodeIfPresent(
            WatchSyncRevision.self,
            forKey: .paginationCursor
        ) ?? Self.defaultPaginationCursor(for: revision)
        let decodedConversations = try container.decodeIfPresent(
            [WatchConversation].self,
            forKey: .conversations
        ) ?? []
        conversations = WatchConversationCanonicalizer.watchConversations(decodedConversations)
        if container.contains(.authoritativeConversationIDs) {
            authoritativeConversationIDs = try WatchConversationCanonicalizer.uniqueIDs(
                container.decode([UUID].self, forKey: .authoritativeConversationIDs)
            )
        } else {
            authoritativeConversationIDs = conversations.map(\.id)
        }
        authoritativeConversationIDsAreComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .authoritativeConversationIDsAreComplete
        ) ?? (schemaVersion <= 2)
        let decodedConfigurations = try container.decodeIfPresent(
            [WatchConversationRequestConfiguration].self,
            forKey: .conversationConfigurations
        ) ?? []
        conversationConfigurations = WatchConversationCanonicalizer.requestConfigurations(
            decodedConfigurations
        )
        conversationConfigurationsAreComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .conversationConfigurationsAreComplete
        ) ?? false
        acknowledgedPeerID = try container.decodeIfPresent(UUID.self, forKey: .acknowledgedPeerID)
            ?? WatchSyncIdentity.legacyPeerID
        let encodedAcknowledgements = try container.decodeIfPresent(
            [String: WatchSyncRevision].self,
            forKey: .acknowledgedWatchRevisions
        ) ?? [:]
        acknowledgedWatchRevisions = WatchSyncRevisionMapCodec.decode(encodedAcknowledgements)
        tombstones = try container.decodeIfPresent([WatchConversationTombstone].self, forKey: .tombstones) ?? []
        tombstones.sort(by: Self.tombstoneSort)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(revision, forKey: .revision)
        try container.encode(paginationCursor, forKey: .paginationCursor)
        try container.encode(conversations, forKey: .conversations)
        try container.encode(authoritativeConversationIDs, forKey: .authoritativeConversationIDs)
        try container.encode(
            authoritativeConversationIDsAreComplete,
            forKey: .authoritativeConversationIDsAreComplete
        )
        try container.encode(conversationConfigurations, forKey: .conversationConfigurations)
        try container.encode(
            conversationConfigurationsAreComplete,
            forKey: .conversationConfigurationsAreComplete
        )
        try container.encodeIfPresent(acknowledgedPeerID, forKey: .acknowledgedPeerID)
        let encodedAcknowledgements = WatchSyncRevisionMapCodec.encode(acknowledgedWatchRevisions)
        try container.encode(encodedAcknowledgements, forKey: .acknowledgedWatchRevisions)
        try container.encode(tombstones.sorted(by: Self.tombstoneSort), forKey: .tombstones)
    }

    private static func defaultPaginationCursor(
        for revision: WatchSyncRevision
    ) -> WatchSyncRevision {
        revision > 0 ? revision - 1 : 0
    }

    private static func tombstoneSort(
        _ lhs: WatchConversationTombstone,
        _ rhs: WatchConversationTombstone
    ) -> Bool {
        if lhs.conversationID != rhs.conversationID {
            return lhs.conversationID.uuidString < rhs.conversationID.uuidString
        }
        return lhs.revision < rhs.revision
    }
}

struct WatchSyncPayload: Equatable, Sendable {
    let snapshot: WatchSyncSnapshot
    let data: Data

    var encodedSnapshot: Data {
        data
    }
}

struct WatchMutationPayload: Equatable, Sendable {
    let mutation: WatchConversationMutation
    let data: Data
}

/// Lightweight message model for Watch sync (no images or attachments).
struct WatchMessage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var model: String?
    var toolCalls: [MCPToolCall]?
    var citations: [CitationReference]?

    init(
        id: UUID,
        role: String,
        content: String,
        timestamp: Date,
        model: String? = nil,
        toolCalls: [MCPToolCall]? = nil,
        citations: [CitationReference]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.model = model
        self.toolCalls = toolCalls
        self.citations = citations
    }

    init(from message: Message) {
        id = message.id
        role = message.role.rawValue
        content = message.content
        timestamp = message.timestamp
        model = message.model
        toolCalls = message.toolCalls
        citations = message.citations
    }

    func toMessage() -> Message {
        let messageRole: Message.Role
        if let decodedRole = Message.Role(rawValue: role) {
            messageRole = decodedRole
        } else {
            DiagnosticsLogger.log(
                .watchConnectivity,
                level: .default,
                message: "Invalid message role",
                metadata: ["role": role]
            )
            messageRole = .assistant
        }

        return Message(
            id: id,
            role: messageRole,
            content: content,
            timestamp: timestamp,
            toolCalls: toolCalls,
            model: model,
            citations: citations
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
