// swiftlint:disable file_length
import Foundation

typealias WatchSyncRevision = UInt64

enum WatchSyncRevisionMapCodec {
    static func decode(_ encoded: [String: WatchSyncRevision]) -> [UUID: WatchSyncRevision] {
        var decoded: [UUID: WatchSyncRevision] = [:]
        for (key, revision) in encoded {
            guard let id = UUID(uuidString: key) else { continue }
            decoded[id] = max(decoded[id] ?? 0, revision)
        }
        return decoded
    }

    static func encode(_ revisions: [UUID: WatchSyncRevision]) -> [String: WatchSyncRevision] {
        var encoded: [String: WatchSyncRevision] = [:]
        for (id, revision) in revisions {
            encoded[id.uuidString] = revision
        }
        return encoded
    }

    static func merge(
        _ revisions: [UUID: WatchSyncRevision],
        into destination: inout [UUID: WatchSyncRevision]
    ) {
        for (id, revision) in revisions {
            destination[id] = max(destination[id] ?? 0, revision)
        }
    }
}

struct WatchMutationDeliveryCoverage: Codable, Equatable, Sendable {
    var createRevision: WatchSyncRevision?
    var titleRevision: WatchSyncRevision?
    var configurationRevision: WatchSyncRevision?
    var messageRevisions: [UUID: WatchSyncRevision] = [:]
}

enum WatchSyncIdentity {
    static let legacySourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let legacyPeerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
}

/// Canonicalizes conversation collections at sync protocol boundaries.
///
/// Duplicate phone conversation IDs choose the greatest `updatedAt`. Duplicate Watch IDs choose
/// the greatest `watchRevision`, then `updatedAt`. Exact ties choose the lexicographically greatest
/// stable encoding, so the winner is independent of input order. Within a Watch conversation, the
/// last value for a duplicate message ID wins while its first position is retained.
enum WatchConversationCanonicalizer {
    static func phoneConversations(
        _ conversations: some Sequence<Conversation>
    ) -> [Conversation] {
        var byID: [UUID: Conversation] = [:]
        for conversation in conversations {
            if let existing = byID[conversation.id] {
                if prefersPhoneConversation(conversation, over: existing) {
                    byID[conversation.id] = conversation
                }
            } else {
                byID[conversation.id] = conversation
            }
        }
        return byID.values.sorted(by: phoneConversationSort)
    }

    static func watchConversation(_ conversation: WatchConversation) -> WatchConversation {
        var canonical = conversation
        var messages: [WatchMessage] = []
        var indexByID: [UUID: Int] = [:]
        for message in conversation.messages {
            if let index = indexByID[message.id] {
                messages[index] = message
            } else {
                indexByID[message.id] = messages.count
                messages.append(message)
            }
        }
        canonical.messages = messages
        return canonical
    }

    static func watchConversations(
        _ conversations: some Sequence<WatchConversation>
    ) -> [WatchConversation] {
        var byID: [UUID: WatchConversation] = [:]
        for value in conversations {
            let conversation = watchConversation(value)
            if let existing = byID[conversation.id] {
                if prefersWatchConversation(conversation, over: existing) {
                    byID[conversation.id] = conversation
                }
            } else {
                byID[conversation.id] = conversation
            }
        }
        return byID.values.sorted(by: watchConversationSort)
    }

    static func uniqueIDs(_ ids: some Sequence<UUID>) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    static func requestConfigurations(
        _ configurations: some Sequence<WatchConversationRequestConfiguration>
    ) -> [WatchConversationRequestConfiguration] {
        var order: [UUID] = []
        var byID: [UUID: WatchConversationRequestConfiguration] = [:]
        for configuration in configurations {
            if let existing = byID[configuration.id] {
                if stableEncoding(existing).lexicographicallyPrecedes(stableEncoding(configuration)) {
                    byID[configuration.id] = configuration
                }
            } else {
                order.append(configuration.id)
                byID[configuration.id] = configuration
            }
        }
        return order.compactMap { byID[$0] }
    }

    private static func prefersPhoneConversation(
        _ candidate: Conversation,
        over existing: Conversation
    ) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return stableEncoding(existing).lexicographicallyPrecedes(stableEncoding(candidate))
    }

    private static func prefersWatchConversation(
        _ candidate: WatchConversation,
        over existing: WatchConversation
    ) -> Bool {
        if candidate.watchRevision != existing.watchRevision {
            return candidate.watchRevision > existing.watchRevision
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return stableEncoding(existing).lexicographicallyPrecedes(stableEncoding(candidate))
    }

    private static func stableEncoding(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func phoneConversationSort(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func watchConversationSort(
        _ lhs: WatchConversation,
        _ rhs: WatchConversation
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct WatchSyncPageCycleCursor: Codable, Equatable, Hashable, Sendable {
    let pageIndex: Int
    let manifestOffset: Int
    let configurationOffset: Int
    let tombstoneOffset: Int
    /// True when every configuration consumed before this cursor was delivered losslessly.
    let precedingConfigurationsAreLossless: Bool

    init(
        pageIndex: Int,
        manifestOffset: Int,
        configurationOffset: Int,
        tombstoneOffset: Int,
        precedingConfigurationsAreLossless: Bool = true
    ) {
        self.pageIndex = pageIndex
        self.manifestOffset = manifestOffset
        self.configurationOffset = configurationOffset
        self.tombstoneOffset = tombstoneOffset
        self.precedingConfigurationsAreLossless = precedingConfigurationsAreLossless
    }

    private enum CodingKeys: String, CodingKey {
        case pageIndex
        case manifestOffset
        case configurationOffset
        case tombstoneOffset
        case precedingConfigurationsAreLossless
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        manifestOffset = try container.decode(Int.self, forKey: .manifestOffset)
        configurationOffset = try container.decode(Int.self, forKey: .configurationOffset)
        tombstoneOffset = try container.decode(Int.self, forKey: .tombstoneOffset)
        precedingConfigurationsAreLossless = try container.decodeIfPresent(
            Bool.self,
            forKey: .precedingConfigurationsAreLossless
        ) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(manifestOffset, forKey: .manifestOffset)
        try container.encode(configurationOffset, forKey: .configurationOffset)
        try container.encode(tombstoneOffset, forKey: .tombstoneOffset)
        try container.encode(
            precedingConfigurationsAreLossless,
            forKey: .precedingConfigurationsAreLossless
        )
    }

    var isValid: Bool {
        pageIndex >= 0 && manifestOffset >= 0 && configurationOffset >= 0 && tombstoneOffset >= 0
    }

    static let initial = Self(
        pageIndex: 0,
        manifestOffset: 0,
        configurationOffset: 0,
        tombstoneOffset: 0
    )
}

struct WatchSyncPageSection: Codable, Equatable, Sendable {
    let offset: Int
    /// Number of records present in the payload.
    let itemCount: Int
    let totalCount: Int
    /// Number of source records consumed to prevent a deferred record from pinning the cursor.
    let cursorAdvanceCount: Int
    /// True when a delivered configuration intentionally clears an unavailable prompt.
    let containsUnavailablePromptGate: Bool

    init(
        offset: Int,
        itemCount: Int,
        totalCount: Int,
        cursorAdvanceCount: Int? = nil,
        containsUnavailablePromptGate: Bool = false
    ) {
        self.offset = offset
        self.itemCount = itemCount
        self.totalCount = totalCount
        self.cursorAdvanceCount = cursorAdvanceCount ?? itemCount
        self.containsUnavailablePromptGate = containsUnavailablePromptGate
    }

    private enum CodingKeys: String, CodingKey {
        case offset
        case itemCount
        case totalCount
        case cursorAdvanceCount
        case containsUnavailablePromptGate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = try container.decode(Int.self, forKey: .offset)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
        cursorAdvanceCount = try container.decodeIfPresent(
            Int.self,
            forKey: .cursorAdvanceCount
        ) ?? itemCount
        containsUnavailablePromptGate = try container.decodeIfPresent(
            Bool.self,
            forKey: .containsUnavailablePromptGate
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offset, forKey: .offset)
        try container.encode(itemCount, forKey: .itemCount)
        try container.encode(totalCount, forKey: .totalCount)
        try container.encode(cursorAdvanceCount, forKey: .cursorAdvanceCount)
        try container.encode(
            containsUnavailablePromptGate,
            forKey: .containsUnavailablePromptGate
        )
    }

    var isValid: Bool {
        offset >= 0 && itemCount >= 0 && totalCount >= 0 && cursorAdvanceCount >= itemCount
            && offset <= totalCount && cursorAdvanceCount <= totalCount - offset
    }

    var isLossless: Bool {
        itemCount == cursorAdvanceCount && !containsUnavailablePromptGate
    }

    var nextOffset: Int? {
        guard isValid, offset < totalCount, cursorAdvanceCount > 0 else { return nil }
        let next = offset + cursorAdvanceCount
        return next < totalCount ? next : nil
    }
}

struct WatchSyncPageCycleMetadata: Codable, Equatable, Sendable {
    let cycleID: UUID
    let sourceID: UUID
    let snapshotRevision: WatchSyncRevision
    let cursor: WatchSyncPageCycleCursor
    let manifest: WatchSyncPageSection
    let configurations: WatchSyncPageSection
    let tombstones: WatchSyncPageSection
    let modelMetadataCycleIsAuthoritative: Bool

    init(
        cycleID: UUID,
        sourceID: UUID,
        snapshotRevision: WatchSyncRevision,
        cursor: WatchSyncPageCycleCursor,
        manifest: WatchSyncPageSection,
        configurations: WatchSyncPageSection,
        tombstones: WatchSyncPageSection,
        modelMetadataCycleIsAuthoritative: Bool = false
    ) {
        self.cycleID = cycleID
        self.sourceID = sourceID
        self.snapshotRevision = snapshotRevision
        self.cursor = cursor
        self.manifest = manifest
        self.configurations = configurations
        self.tombstones = tombstones
        self.modelMetadataCycleIsAuthoritative = modelMetadataCycleIsAuthoritative
            && cursor.precedingConfigurationsAreLossless
            && configurations.isLossless
    }

    private enum CodingKeys: String, CodingKey {
        case cycleID
        case sourceID
        case snapshotRevision
        case cursor
        case manifest
        case configurations
        case tombstones
        case modelMetadataCycleIsAuthoritative
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycleID = try container.decode(UUID.self, forKey: .cycleID)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        snapshotRevision = try container.decode(WatchSyncRevision.self, forKey: .snapshotRevision)
        cursor = try container.decode(WatchSyncPageCycleCursor.self, forKey: .cursor)
        manifest = try container.decode(WatchSyncPageSection.self, forKey: .manifest)
        configurations = try container.decode(WatchSyncPageSection.self, forKey: .configurations)
        tombstones = try container.decode(WatchSyncPageSection.self, forKey: .tombstones)
        let decodedModelMetadataCycleIsAuthoritative = try container.decodeIfPresent(
            Bool.self,
            forKey: .modelMetadataCycleIsAuthoritative
        ) ?? false
        modelMetadataCycleIsAuthoritative = decodedModelMetadataCycleIsAuthoritative
            && cursor.precedingConfigurationsAreLossless
            && configurations.isLossless
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cycleID, forKey: .cycleID)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(snapshotRevision, forKey: .snapshotRevision)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(configurations, forKey: .configurations)
        try container.encode(tombstones, forKey: .tombstones)
        try container.encode(
            modelMetadataCycleIsAuthoritative,
            forKey: .modelMetadataCycleIsAuthoritative
        )
    }

    var isValid: Bool {
        let sections = [manifest, configurations, tombstones]
        return cursor.isValid && sections.allSatisfy(\.isValid)
            && sections.allSatisfy { $0.offset >= $0.totalCount || $0.cursorAdvanceCount > 0 }
            && cursor.manifestOffset == manifest.offset
            && cursor.configurationOffset == configurations.offset
            && cursor.tombstoneOffset == tombstones.offset
    }

    func isValid(for snapshot: WatchSyncSnapshot) -> Bool {
        guard isValid,
              sourceID == snapshot.sourceID,
              snapshotRevision == snapshot.revision,
              WatchSyncRevision(exactly: cursor.pageIndex) == snapshot.paginationCursor
        else {
            return false
        }
        return manifest.itemCount == snapshot.authoritativeConversationIDs.count
            && configurations.itemCount == snapshot.conversationConfigurations.count
            && tombstones.itemCount == snapshot.tombstones.count
    }

    var nextCursor: WatchSyncPageCycleCursor? {
        guard isValid else { return nil }
        let manifestOffset = manifest.nextOffset
        let configurationOffset = configurations.nextOffset
        let tombstoneOffset = tombstones.nextOffset
        guard manifestOffset != nil || configurationOffset != nil || tombstoneOffset != nil else {
            return nil
        }
        let (nextPageIndex, overflow) = cursor.pageIndex.addingReportingOverflow(1)
        guard !overflow else { return nil }
        return WatchSyncPageCycleCursor(
            pageIndex: nextPageIndex,
            manifestOffset: manifestOffset ?? manifest.totalCount,
            configurationOffset: configurationOffset ?? configurations.totalCount,
            tombstoneOffset: tombstoneOffset ?? tombstones.totalCount,
            precedingConfigurationsAreLossless: cursor.precedingConfigurationsAreLossless
                && configurations.isLossless
        )
    }
}

struct WatchSyncPageCycleRequest: Codable, Equatable, Sendable {
    let cycleID: UUID
    let cursor: WatchSyncPageCycleCursor
}

enum WatchSyncRequestIdentity: Equatable, Sendable {
    case freshCycle
    case pageCycle(WatchSyncPageCycleRequest)

    var pageCycleRequest: WatchSyncPageCycleRequest? {
        guard case let .pageCycle(request) = self else { return nil }
        return request
    }
}

struct WatchSyncPageCyclePayload: Equatable, Sendable {
    let snapshot: WatchSyncSnapshot
    let data: Data
    let metadata: WatchSyncPageCycleMetadata
}

enum WatchMutationRetryBackoff {
    static func seconds(forAttempt attempt: Int) -> TimeInterval {
        let boundedAttempt = min(max(0, attempt), 4)
        return min(60, 5 * pow(2, Double(boundedAttempt)))
    }
}

@MainActor
final class WatchMutationProcessingQueue {
    private var tail = Task { @MainActor in }

    func enqueue<Output: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Output
    ) async -> Output {
        let predecessor = tail
        let task = Task { @MainActor in
            await predecessor.value
            return await operation()
        }
        tail = Task { @MainActor in
            _ = await task.value
        }
        return await task.value
    }
}

struct WatchConversationTombstone: Codable, Equatable, Identifiable, Sendable {
    let conversationID: UUID
    var revision: WatchSyncRevision

    var id: UUID {
        conversationID
    }

    var watchRevision: WatchSyncRevision {
        get { revision }
        set { revision = newValue }
    }

    init(conversationID: UUID, revision: WatchSyncRevision) {
        self.conversationID = conversationID
        self.revision = revision
    }

    init(conversationID: UUID, watchRevision: WatchSyncRevision) {
        self.init(conversationID: conversationID, revision: watchRevision)
    }
}

struct WatchConversationMutationFields: OptionSet, Codable, Equatable, Hashable, Sendable {
    let rawValue: UInt8

    static let create = Self(rawValue: 1 << 0)
    static let title = Self(rawValue: 1 << 1)
    static let messages = Self(rawValue: 1 << 2)
    static let delete = Self(rawValue: 1 << 3)
    static let configuration = Self(rawValue: 1 << 4)

    static let fullState: Self = [.create, .title, .messages, .configuration]
}

typealias WatchConversationMutationFlags = WatchConversationMutationFields

/// A durable Watch-originated mutation. Every envelope carries a full bounded state so
/// queued operations can be safely coalesced while the flags retain mutation intent.
struct WatchConversationMutation: Codable, Equatable, Identifiable, Sendable {
    typealias Fields = WatchConversationMutationFields

    let operationID: UUID
    var peerID: UUID
    var revision: WatchSyncRevision
    var conversation: WatchConversation
    var fields: WatchConversationMutationFields
    var createRevision: WatchSyncRevision?
    var titleRevision: WatchSyncRevision?
    var configurationRevision: WatchSyncRevision?
    var messageChanges: [WatchMessage]
    var messageChangeRevisions: [UUID: WatchSyncRevision]

    var id: UUID {
        operationID
    }

    var conversationID: UUID {
        conversation.id
    }

    var fieldFlags: WatchConversationMutationFields {
        get { fields }
        set { fields = newValue }
    }

    func messageChanges(
        after acknowledgedRevision: WatchSyncRevision,
        coverage: WatchMutationDeliveryCoverage? = nil
    ) -> [WatchMessage] {
        messageChanges.filter {
            (messageChangeRevisions[$0.id] ?? revision) > max(
                acknowledgedRevision,
                coverage?.messageRevisions[$0.id] ?? 0
            )
        }
    }

    func changesCreate(
        after acknowledgedRevision: WatchSyncRevision,
        coverage: WatchMutationDeliveryCoverage? = nil
    ) -> Bool {
        (createRevision ?? 0) > max(
            acknowledgedRevision,
            coverage?.createRevision ?? 0
        )
    }

    func changesTitle(
        after acknowledgedRevision: WatchSyncRevision,
        coverage: WatchMutationDeliveryCoverage? = nil
    ) -> Bool {
        let localRevision = Swift.max(createRevision ?? 0, titleRevision ?? 0)
        let coveredRevision = Swift.max(
            coverage?.createRevision ?? 0,
            coverage?.titleRevision ?? 0
        )
        let requiredRevision = Swift.max(acknowledgedRevision, coveredRevision)
        return localRevision > requiredRevision
    }

    func changesConfiguration(
        after acknowledgedRevision: WatchSyncRevision,
        coverage: WatchMutationDeliveryCoverage? = nil
    ) -> Bool {
        let localRevision = Swift.max(createRevision ?? 0, configurationRevision ?? 0)
        let coveredRevision = Swift.max(
            coverage?.createRevision ?? 0,
            coverage?.configurationRevision ?? 0
        )
        let requiredRevision = Swift.max(acknowledgedRevision, coveredRevision)
        return localRevision > requiredRevision
    }

    private enum CodingKeys: String, CodingKey {
        case operationID
        case peerID
        case revision
        case conversation
        case fields
        case createRevision
        case titleRevision
        case configurationRevision
        case messageChanges
        case messageChangeRevisions
    }

    init(
        operationID: UUID = UUID(),
        peerID: UUID = WatchSyncIdentity.legacyPeerID,
        revision: WatchSyncRevision,
        conversation: WatchConversation,
        fields: WatchConversationMutationFields,
        createRevision: WatchSyncRevision? = nil,
        titleRevision: WatchSyncRevision? = nil,
        configurationRevision: WatchSyncRevision? = nil,
        messageChanges: [WatchMessage] = [],
        messageChangeRevisions: [UUID: WatchSyncRevision]? = nil
    ) {
        self.operationID = operationID
        self.peerID = peerID
        self.revision = revision
        var state = conversation
        state.watchRevision = revision
        state.messages = []
        self.conversation = state
        self.fields = fields
        self.createRevision = createRevision ?? (fields.contains(.create) ? revision : nil)
        self.titleRevision = titleRevision ?? (fields.contains(.title) ? revision : nil)
        self.configurationRevision = configurationRevision
            ?? (fields.contains(.configuration) ? revision : nil)
        self.messageChanges = messageChanges
        self.messageChangeRevisions = messageChangeRevisions
            ?? Dictionary(
                messageChanges.map { ($0.id, revision) },
                uniquingKeysWith: { _, new in new }
            )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decode(UUID.self, forKey: .operationID)
        peerID = try container.decodeIfPresent(UUID.self, forKey: .peerID)
            ?? WatchSyncIdentity.legacyPeerID
        revision = try container.decode(WatchSyncRevision.self, forKey: .revision)
        conversation = try container.decode(WatchConversation.self, forKey: .conversation)
        fields = try container.decode(WatchConversationMutationFields.self, forKey: .fields)
        createRevision = try container.decodeIfPresent(WatchSyncRevision.self, forKey: .createRevision)
            ?? (fields.contains(.create) ? revision : nil)
        titleRevision = try container.decodeIfPresent(WatchSyncRevision.self, forKey: .titleRevision)
            ?? (fields.contains(.title) ? revision : nil)
        configurationRevision = try container.decodeIfPresent(
            WatchSyncRevision.self,
            forKey: .configurationRevision
        ) ?? (fields.contains(.configuration) ? revision : nil)
        let decodedMessageChanges = try container.decodeIfPresent([WatchMessage].self, forKey: .messageChanges)
            ?? (fields.contains(.messages) ? conversation.messages : [])
        messageChanges = decodedMessageChanges
        let encodedRevisions = try container.decodeIfPresent(
            [String: WatchSyncRevision].self,
            forKey: .messageChangeRevisions
        ) ?? [:]
        let normalizedRevisions = WatchSyncRevisionMapCodec.decode(encodedRevisions)
        var decodedRevisionMap: [UUID: WatchSyncRevision] = [:]
        for message in decodedMessageChanges {
            decodedRevisionMap[message.id] = normalizedRevisions[message.id] ?? revision
        }
        messageChangeRevisions = decodedRevisionMap
        conversation.watchRevision = revision
        conversation.messages = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(peerID, forKey: .peerID)
        try container.encode(revision, forKey: .revision)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(fields, forKey: .fields)
        try container.encodeIfPresent(createRevision, forKey: .createRevision)
        try container.encodeIfPresent(titleRevision, forKey: .titleRevision)
        try container.encodeIfPresent(configurationRevision, forKey: .configurationRevision)
        try container.encode(messageChanges, forKey: .messageChanges)
        try container.encode(
            WatchSyncRevisionMapCodec.encode(messageChangeRevisions),
            forKey: .messageChangeRevisions
        )
    }

    func coalescing(with other: Self) -> Self? {
        guard conversationID == other.conversationID else { return nil }

        let preferred: Self = if revision != other.revision {
            revision > other.revision ? self : other
        } else {
            operationID.uuidString >= other.operationID.uuidString ? self : other
        }

        let combinedFields = fields.union(other.fields)
        let combinedChanges = preferred.fields.contains(.delete)
            ? (messages: [], revisions: [:])
            : Self.mergedMessageChanges(
                older: preferred.operationID == operationID ? other : self,
                newer: preferred
            )

        return Self(
            operationID: preferred.operationID,
            peerID: preferred.peerID,
            revision: max(revision, other.revision),
            conversation: preferred.conversation,
            fields: preferred.fields.contains(.delete) ? [.delete] : combinedFields,
            createRevision: Self.maximum(createRevision, other.createRevision),
            titleRevision: Self.maximum(titleRevision, other.titleRevision),
            configurationRevision: Self.maximum(configurationRevision, other.configurationRevision),
            messageChanges: combinedChanges.messages,
            messageChangeRevisions: combinedChanges.revisions
        )
    }

    static func coalesced(_ mutations: [Self]) -> [Self] {
        var byConversation: [UUID: Self] = [:]
        for mutation in mutations {
            if let existing = byConversation[mutation.conversationID] {
                byConversation[mutation.conversationID] = existing.coalescing(with: mutation)
            } else {
                byConversation[mutation.conversationID] = mutation
            }
        }
        return byConversation.values.sorted {
            if $0.revision != $1.revision {
                return $0.revision < $1.revision
            }
            return $0.conversationID.uuidString < $1.conversationID.uuidString
        }
    }

    private static func mergedMessageChanges(
        older: Self,
        newer: Self
    ) -> (messages: [WatchMessage], revisions: [UUID: WatchSyncRevision]) {
        var orderedIDs: [UUID] = []
        var byID: [UUID: WatchMessage] = [:]
        var revisions: [UUID: WatchSyncRevision] = [:]
        for mutation in [older, newer] {
            for message in mutation.messageChanges {
                let revision = mutation.messageChangeRevisions[message.id] ?? mutation.revision
                if byID[message.id] == nil {
                    orderedIDs.append(message.id)
                }
                if revision >= revisions[message.id, default: 0] {
                    byID[message.id] = message
                    revisions[message.id] = revision
                }
            }
        }
        return (orderedIDs.compactMap { byID[$0] }, revisions)
    }

    private static func maximum(
        _ lhs: WatchSyncRevision?,
        _ rhs: WatchSyncRevision?
    ) -> WatchSyncRevision? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (value?, nil), let (nil, value?): value
        case (nil, nil): nil
        }
    }
}

struct PhoneWatchSyncState: Equatable, Sendable {
    var peerID: UUID?
    var conversations: [Conversation]
    var acknowledgedWatchRevisions: [UUID: WatchSyncRevision]
    var tombstoneRevisions: [UUID: WatchSyncRevision]

    init(
        peerID: UUID? = WatchSyncIdentity.legacyPeerID,
        conversations: [Conversation] = [],
        acknowledgedWatchRevisions: [UUID: WatchSyncRevision] = [:],
        tombstoneRevisions: [UUID: WatchSyncRevision] = [:]
    ) {
        self.peerID = peerID
        self.conversations = WatchConversationCanonicalizer.phoneConversations(conversations)
        self.acknowledgedWatchRevisions = acknowledgedWatchRevisions
        self.tombstoneRevisions = tombstoneRevisions
    }
}

typealias PhoneWatchMutationState = PhoneWatchSyncState

enum PhoneWatchMutationDisposition: Equatable, Sendable {
    case applied
    case deleted
    case rejectedStale
    case rejectedDeletedTombstone
    case rejectedMissingCreate
}

struct PhoneWatchMutationReduction: Equatable, Sendable {
    var state: PhoneWatchSyncState
    let disposition: PhoneWatchMutationDisposition

    var wasApplied: Bool {
        disposition == .applied || disposition == .deleted
    }
}

enum PhoneWatchMutationReducer {
    static func reduce(
        _ state: PhoneWatchSyncState,
        mutation: WatchConversationMutation,
        tombstoneRevision: WatchSyncRevision? = nil
    ) -> PhoneWatchMutationReduction {
        var canonicalState = state
        canonicalState.conversations = WatchConversationCanonicalizer.phoneConversations(state.conversations)
        var next = canonicalState
        if next.peerID != mutation.peerID {
            next.peerID = mutation.peerID
            next.acknowledgedWatchRevisions = [:]
        }
        let conversationID = mutation.conversationID
        let acknowledged = next.acknowledgedWatchRevisions[conversationID] ?? 0

        guard mutation.revision > acknowledged else {
            return PhoneWatchMutationReduction(state: canonicalState, disposition: .rejectedStale)
        }

        if let tombstoneRevision = next.tombstoneRevisions[conversationID] {
            next.acknowledgedWatchRevisions[conversationID] = mutation.revision
            next.tombstoneRevisions[conversationID] = tombstoneRevision
            next.conversations.removeAll { $0.id == conversationID }
            return PhoneWatchMutationReduction(
                state: next,
                disposition: .rejectedDeletedTombstone
            )
        }

        if mutation.fields.contains(.delete) {
            next.conversations.removeAll { $0.id == conversationID }
            next.acknowledgedWatchRevisions[conversationID] = mutation.revision
            next.tombstoneRevisions[conversationID] = tombstoneRevision ?? mutation.revision
            return PhoneWatchMutationReduction(state: next, disposition: .deleted)
        }

        if let index = next.conversations.firstIndex(where: { $0.id == conversationID }) {
            next.conversations[index] = merge(
                phone: next.conversations[index],
                mutation: mutation,
                acknowledgedRevision: acknowledged
            )
        } else if mutation.changesCreate(after: acknowledged) {
            var created = mutation.conversation.toConversation()
            created.messages = mergeMessages(
                phone: [],
                watch: mutation.messageChanges(after: acknowledged)
            )
            next.conversations.append(created)
        } else {
            next.acknowledgedWatchRevisions[conversationID] = mutation.revision
            return PhoneWatchMutationReduction(state: next, disposition: .rejectedMissingCreate)
        }

        next.acknowledgedWatchRevisions[conversationID] = mutation.revision
        next.conversations.sort(by: conversationSort)
        return PhoneWatchMutationReduction(state: next, disposition: .applied)
    }

    static func reduce(
        _ state: PhoneWatchSyncState,
        mutations: [WatchConversationMutation]
    ) -> PhoneWatchSyncState {
        WatchConversationMutation.coalesced(mutations).reduce(state) { current, mutation in
            reduce(current, mutation: mutation).state
        }
    }

    private static func merge(
        phone: Conversation,
        mutation: WatchConversationMutation,
        acknowledgedRevision: WatchSyncRevision
    ) -> Conversation {
        let watch = mutation.conversation
        var merged = phone

        if mutation.changesTitle(after: acknowledgedRevision) {
            merged.title = watch.title
        }
        if mutation.fields.contains(.create) || mutation.fields.contains(.messages) {
            merged.messages = mergeMessages(
                phone: phone.messages,
                watch: mutation.messageChanges(after: acknowledgedRevision)
            )
        }

        if mutation.changesConfiguration(after: acknowledgedRevision) {
            merged.model = watch.model
            merged.temperature = watch.temperature
        }
        merged.updatedAt = max(phone.updatedAt, watch.updatedAt)
        return merged
    }

    private static func mergeMessages(phone: [Message], watch: [WatchMessage]) -> [Message] {
        var result: [Message] = []
        var indexByID: [UUID: Int] = [:]

        for message in phone where indexByID[message.id] == nil {
            indexByID[message.id] = result.count
            result.append(message)
        }

        for watchMessage in watch {
            let converted = watchMessage.toMessage()
            if let index = indexByID[watchMessage.id] {
                result[index] = converted
            } else {
                indexByID[watchMessage.id] = result.count
                result.append(converted)
            }
        }
        return result
    }

    private static func conversationSort(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

typealias WatchPhoneMutationReducer = PhoneWatchMutationReducer

struct WatchSyncLocalState: Equatable, Sendable {
    var sourceID: UUID?
    var peerID: UUID
    var lastSnapshotRevision: WatchSyncRevision
    var conversations: [WatchConversation]
    var pendingMutations: [WatchConversationMutation]
    var pendingDrafts: [UUID: WatchConversationDraft]
    var localDeliveryCoverage: [UUID: WatchMutationDeliveryCoverage]

    init(
        sourceID: UUID? = nil,
        peerID: UUID = WatchSyncIdentity.legacyPeerID,
        lastSnapshotRevision: WatchSyncRevision = 0,
        conversations: [WatchConversation] = [],
        pendingMutations: [WatchConversationMutation] = [],
        pendingDrafts: [UUID: WatchConversationDraft] = [:],
        localDeliveryCoverage: [UUID: WatchMutationDeliveryCoverage] = [:]
    ) {
        self.sourceID = sourceID
        self.peerID = peerID
        self.lastSnapshotRevision = lastSnapshotRevision
        self.conversations = WatchConversationCanonicalizer.watchConversations(conversations)
        self.pendingMutations = pendingMutations
        self.pendingDrafts = pendingDrafts
        self.localDeliveryCoverage = localDeliveryCoverage
    }
}

struct WatchConversationDraft: Codable, Equatable, Identifiable, Sendable {
    var conversation: WatchConversation
    var ownedMessageIDs: Set<UUID>
    /// Mutation intent retained locally when the conversation revision cannot advance.
    /// Optional for backward-compatible decoding of drafts persisted before overflow handling.
    var deferredMutationFields: WatchConversationMutationFields?

    init(
        conversation: WatchConversation,
        ownedMessageIDs: Set<UUID>,
        deferredMutationFields: WatchConversationMutationFields? = nil
    ) {
        self.conversation = conversation
        self.ownedMessageIDs = ownedMessageIDs
        self.deferredMutationFields = deferredMutationFields
    }

    var id: UUID {
        conversation.id
    }

    var deferredFields: WatchConversationMutationFields {
        deferredMutationFields ?? []
    }
}

typealias WatchSnapshotState = WatchSyncLocalState

enum WatchSnapshotReconciliationDisposition: Equatable, Sendable {
    case applied
    case ignoredStale
    case ignoredUnsupportedSchema
}

struct WatchSnapshotReconciliation: Equatable, Sendable {
    var state: WatchSyncLocalState
    let disposition: WatchSnapshotReconciliationDisposition
}

enum WatchSnapshotReconciler {
    static func reconcile(
        _ snapshot: WatchSyncSnapshot,
        with state: WatchSyncLocalState
    ) -> WatchSnapshotReconciliation {
        var canonicalState = state
        canonicalState.conversations = WatchConversationCanonicalizer.watchConversations(state.conversations)
        guard WatchSyncSnapshot.supportsSchemaVersion(snapshot.schemaVersion) else {
            return WatchSnapshotReconciliation(state: canonicalState, disposition: .ignoredUnsupportedSchema)
        }

        let sourceChanged = canonicalState.sourceID.map { $0 != snapshot.sourceID } ?? false
        guard sourceChanged || snapshot.revision > canonicalState.lastSnapshotRevision else {
            return WatchSnapshotReconciliation(state: canonicalState, disposition: .ignoredStale)
        }

        let acknowledgements = snapshot.acknowledgedPeerID == canonicalState.peerID
            ? snapshot.acknowledgedWatchRevisions
            : [:]

        let tombstones = tombstoneDictionary(snapshot.tombstones)
        let manifest = Set(snapshot.authoritativeConversationIDs).subtracting(tombstones.keys)
        let cachedConversations = dictionaryByID(canonicalState.conversations)
        let original = if sourceChanged, snapshot.authoritativeConversationIDsAreComplete {
            cachedConversations.filter { manifest.contains($0.key) }
        } else {
            cachedConversations
        }
        let remote = dictionaryByID(snapshot.conversations.filter {
            tombstones[$0.id] == nil &&
                (!snapshot.authoritativeConversationIDsAreComplete || manifest.contains($0.id))
        })

        var reconciled: [UUID: WatchConversation] = snapshot.authoritativeConversationIDsAreComplete
            ? [:]
            : original.filter { tombstones[$0.key] == nil }
        if !snapshot.authoritativeConversationIDsAreComplete {
            for (conversationID, var retained) in reconciled {
                retained.watchRevision = max(
                    retained.watchRevision,
                    acknowledgements[conversationID] ?? 0
                )
                reconciled[conversationID] = retained
            }
        }
        for conversationID in manifest {
            if let body = remote[conversationID] {
                reconciled[conversationID] = body
            } else if var retained = original[conversationID] {
                retained.watchRevision = max(
                    retained.watchRevision,
                    acknowledgements[conversationID] ?? 0
                )
                reconciled[conversationID] = retained
            }
        }
        for (conversationID, body) in remote {
            reconciled[conversationID] = body
        }
        for configuration in snapshot.conversationConfigurations
            where tombstones[configuration.id] == nil
        {
            guard var retained = reconciled[configuration.id] else { continue }
            configuration.apply(to: &retained)
            reconciled[configuration.id] = retained
        }

        let remaining = canonicalState.pendingMutations.filter { mutation in
            guard tombstones[mutation.conversationID] == nil else { return false }
            let acknowledgement = max(
                acknowledgements[mutation.conversationID] ?? 0,
                0
            )
            return mutation.revision > acknowledgement
        }
        let pendingMutations = WatchConversationMutation.coalesced(remaining)
        let pendingDeleteIDs = Set(
            pendingMutations
                .filter { $0.fields.contains(.delete) }
                .map(\.conversationID)
        )

        for mutation in pendingMutations {
            replay(
                mutation,
                acknowledgedRevision: acknowledgements[mutation.conversationID] ?? 0,
                coverage: canonicalState.localDeliveryCoverage[mutation.conversationID],
                into: &reconciled
            )
        }

        let pendingMutationIDs = Set(pendingMutations.map(\.conversationID))
        var remainingDrafts = canonicalState.pendingDrafts.filter { conversationID, _ in
            tombstones[conversationID] == nil &&
                (!snapshot.authoritativeConversationIDsAreComplete ||
                    manifest.contains(conversationID) ||
                    pendingMutationIDs.contains(conversationID))
        }
        for (conversationID, draft) in remainingDrafts where !pendingDeleteIDs.contains(conversationID) {
            if draft.deferredFields.contains(.delete) {
                reconciled.removeValue(forKey: conversationID)
                continue
            }

            var remoteConversation = reconciled[conversationID] ?? draft.conversation
            if draft.deferredFields.contains(.title) {
                remoteConversation.title = draft.conversation.title
            }
            if draft.deferredFields.contains(.configuration) {
                remoteConversation.model = draft.conversation.model
                remoteConversation.temperature = draft.conversation.temperature
            }
            remoteConversation.messages = mergeWatchMessages(
                remote: remoteConversation.messages,
                local: draft.conversation.messages.filter { draft.ownedMessageIDs.contains($0.id) }
            )
            remoteConversation.updatedAt = max(remoteConversation.updatedAt, draft.conversation.updatedAt)
            remoteConversation.watchRevision = max(
                remoteConversation.watchRevision,
                draft.conversation.watchRevision
            )
            reconciled[conversationID] = remoteConversation
            remainingDrafts[conversationID] = WatchConversationDraft(
                conversation: remoteConversation,
                ownedMessageIDs: draft.ownedMessageIDs,
                deferredMutationFields: draft.deferredMutationFields
            )
        }

        let conversations = reconciled.values.sorted(by: watchConversationSort)
        let next = WatchSyncLocalState(
            sourceID: snapshot.sourceID,
            peerID: canonicalState.peerID,
            lastSnapshotRevision: snapshot.revision,
            conversations: conversations,
            pendingMutations: pendingMutations,
            pendingDrafts: remainingDrafts,
            localDeliveryCoverage: canonicalState.localDeliveryCoverage
        )
        return WatchSnapshotReconciliation(state: next, disposition: .applied)
    }

    private static func replay(
        _ mutation: WatchConversationMutation,
        acknowledgedRevision: WatchSyncRevision,
        coverage: WatchMutationDeliveryCoverage?,
        into conversations: inout [UUID: WatchConversation]
    ) {
        if mutation.fields.contains(.delete) {
            conversations.removeValue(forKey: mutation.conversationID)
            return
        }

        let applicableMessageChanges = mutation.messageChanges(
            after: acknowledgedRevision,
            coverage: coverage
        )
        let changesCreate = mutation.changesCreate(
            after: acknowledgedRevision,
            coverage: coverage
        )
        let changesTitle = mutation.changesTitle(
            after: acknowledgedRevision,
            coverage: coverage
        )
        let changesConfiguration = mutation.changesConfiguration(
            after: acknowledgedRevision,
            coverage: coverage
        )
        guard var current = conversations[mutation.conversationID] else {
            guard changesCreate || changesTitle || changesConfiguration || !applicableMessageChanges.isEmpty else {
                return
            }
            var created = mutation.conversation
            created.messages = mergeWatchMessages(remote: [], local: applicableMessageChanges)
            conversations[mutation.conversationID] = created
            return
        }

        let local = mutation.conversation
        if changesTitle {
            current.title = local.title
        }
        if mutation.fields.contains(.create) || mutation.fields.contains(.messages) {
            current.messages = mergeWatchMessages(remote: current.messages, local: applicableMessageChanges)
        }
        if changesConfiguration {
            current.model = local.model
            current.temperature = local.temperature
        }
        if changesCreate {
            current.resolvedSystemPrompt = local.resolvedSystemPrompt
        }
        current.updatedAt = max(current.updatedAt, local.updatedAt)
        current.watchRevision = max(current.watchRevision, mutation.revision)
        conversations[mutation.conversationID] = current
    }

    private static func mergeWatchMessages(
        remote: [WatchMessage],
        local: [WatchMessage]
    ) -> [WatchMessage] {
        var result: [WatchMessage] = []
        var indexByID: [UUID: Int] = [:]
        for message in remote where indexByID[message.id] == nil {
            indexByID[message.id] = result.count
            result.append(message)
        }
        for message in local {
            if let index = indexByID[message.id] {
                result[index] = message
            } else {
                indexByID[message.id] = result.count
                result.append(message)
            }
        }
        return result
    }

    private static func dictionaryByID(_ conversations: [WatchConversation]) -> [UUID: WatchConversation] {
        var result: [UUID: WatchConversation] = [:]
        for conversation in conversations {
            if let existing = result[conversation.id] {
                if preferredState(conversation, over: existing) {
                    result[conversation.id] = conversation
                }
            } else {
                result[conversation.id] = conversation
            }
        }
        return result
    }

    private static func preferredState(
        _ candidate: WatchConversation,
        over existing: WatchConversation
    ) -> Bool {
        if candidate.watchRevision != existing.watchRevision {
            return candidate.watchRevision > existing.watchRevision
        }
        return watchConversationSort(candidate, existing)
    }

    private static func tombstoneDictionary(
        _ tombstones: [WatchConversationTombstone]
    ) -> [UUID: WatchSyncRevision] {
        var result: [UUID: WatchSyncRevision] = [:]
        for tombstone in tombstones {
            result[tombstone.conversationID] = max(
                result[tombstone.conversationID] ?? 0,
                tombstone.revision
            )
        }
        return result
    }

    private static func watchConversationSort(
        _ lhs: WatchConversation,
        _ rhs: WatchConversation
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

typealias WatchSyncSnapshotReconciler = WatchSnapshotReconciler

struct WatchSyncPayloadConfiguration: Equatable, Sendable {
    var maximumConversations = 10
    var maximumMessagesPerConversation = 20
    var maximumContentCharacters = 4000
    var maximumTitleCharacters = 160
    /// Legacy sizing threshold. Model identifiers remain lossless; byte pressure removes records instead.
    var maximumModelCharacters = 160
    var maximumSystemPromptCharacters = 4000
    var maximumToolCallsPerMessage = 4
    var maximumToolMetadataBytes = 2048
    var maximumCitationsPerMessage = 8
    var maximumCitationCharacters = 512
    var maximumAcknowledgements = 64
    var maximumTombstones = 32
    var maximumManifestConversationIDs = 256
    var maximumConversationConfigurations = 64
    var byteBudget = 50000

    static let `default` = Self()

    init() {}

    init(
        byteBudget: Int,
        maximumConversations: Int = 10,
        maximumMessagesPerConversation: Int = 20,
        maximumContentCharacters: Int = 4000
    ) {
        self.byteBudget = byteBudget
        self.maximumConversations = maximumConversations
        self.maximumMessagesPerConversation = maximumMessagesPerConversation
        self.maximumContentCharacters = maximumContentCharacters
    }
}

typealias WatchSyncPayloadLimits = WatchSyncPayloadConfiguration

enum WatchSyncPayloadBuilderError: Error, Equatable {
    case invalidByteBudget(Int)
    case invalidPageCycleCursor
    case irreducibleSnapshotExceedsBudget(actualBytes: Int, budget: Int)
    case pageCycleCannotProgress
    case mutationExceedsBudget(actualBytes: Int, budget: Int)
}

/// Publishes an explicit empty default prompt when the current fallback cannot carry the full value.
///
/// The phone's durable preference is never changed. A volatile argument-domain override exists only
/// until the synchronous application-context publication finishes, then the original value is restored.
enum WatchDefaultSystemPromptPublicationGate {
    private static let argumentDomainName = "NSArgumentDomain"
    private static let preferenceKey = "globalSystemPrompt"

    private struct ActiveOverride {
        let defaults: UserDefaults
        let previousValue: Any?
        let hadPreviousValue: Bool
        let generation: UInt64
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var nextGeneration: UInt64 = 0
        var overrides: [ObjectIdentifier: ActiveOverride] = [:]
    }

    private static let state = State()

    static func maximumCharacters(for configuration: WatchSyncPayloadConfiguration) -> Int {
        switch configuration.byteBudget {
        case 32000, 24000:
            4000
        case 12000:
            2000
        case 4000:
            0
        default:
            max(0, configuration.maximumSystemPromptCharacters)
        }
    }

    static func prepareForSnapshotBuild(defaults: UserDefaults = AppPreferences.storage) {
        restoreOverride(for: ObjectIdentifier(defaults), generation: nil)
    }

    @discardableResult
    static func installIfNeeded(
        configuration: WatchSyncPayloadConfiguration,
        defaults: UserDefaults = AppPreferences.storage,
        schedulesAutomaticRestore: Bool = true
    ) -> Bool {
        guard Thread.isMainThread else { return false }
        prepareForSnapshotBuild(defaults: defaults)

        let prompt = defaults.string(forKey: preferenceKey) ?? ""
        let maximumCharacters = maximumCharacters(for: configuration)
        guard !prompt.isEmpty,
              maximumCharacters == 0 || prompt.count > maximumCharacters
        else {
            return false
        }

        let identifier = ObjectIdentifier(defaults)
        state.lock.lock()
        let nextGeneration = state.nextGeneration.addingReportingOverflow(1)
        state.nextGeneration = nextGeneration.overflow ? 1 : nextGeneration.partialValue
        var argumentDomain = defaults.volatileDomain(forName: argumentDomainName)
        let previousValue = argumentDomain[preferenceKey]
        let hadPreviousValue = previousValue != nil
        argumentDomain[preferenceKey] = ""
        defaults.setVolatileDomain(argumentDomain, forName: argumentDomainName)
        let generation = state.nextGeneration
        state.overrides[identifier] = ActiveOverride(
            defaults: defaults,
            previousValue: previousValue,
            hadPreviousValue: hadPreviousValue,
            generation: generation
        )
        state.lock.unlock()

        if schedulesAutomaticRestore {
            Task { @MainActor in
                restoreOverride(for: identifier, generation: generation)
            }
        }
        return true
    }

    private static func restoreOverride(
        for identifier: ObjectIdentifier,
        generation: UInt64?
    ) {
        state.lock.lock()
        guard let active = state.overrides[identifier],
              generation == nil || active.generation == generation
        else {
            state.lock.unlock()
            return
        }
        state.overrides.removeValue(forKey: identifier)
        var argumentDomain = active.defaults.volatileDomain(forName: argumentDomainName)
        if active.hadPreviousValue, let previousValue = active.previousValue {
            argumentDomain[preferenceKey] = previousValue
        } else {
            argumentDomain.removeValue(forKey: preferenceKey)
        }
        active.defaults.setVolatileDomain(argumentDomain, forName: argumentDomainName)
        state.lock.unlock()
    }
}

// swiftlint:disable:next type_body_length
enum WatchSyncPayloadBuilder {
    typealias Configuration = WatchSyncPayloadConfiguration

    private struct Page<Element> {
        let values: [Element]
        let isComplete: Bool
    }

    private struct SnapshotBuildResult {
        let payload: WatchSyncPayload
        let configurationCursorAdvanceCount: Int
        let unavailablePromptIDs: Set<UUID>
    }

    private struct RequestConfigurationTransportPlan {
        let values: [WatchConversationRequestConfiguration]
        let unavailablePromptIDs: Set<UUID>
        let deferredConfigurationIDs: Set<UUID>
    }

    private struct SnapshotTrimContext {
        let budget: Int
        let acknowledgementPriority: [UUID]
        let protectedAcknowledgementIDs: Set<UUID>
        let tombstonePriority: [UUID]
        let manifestValues: [UUID]
        let manifestMaximumCount: Int
        let configurationValues: [WatchConversationRequestConfiguration]
        let configurationMaximumCount: Int
        let deferredConfigurationIDs: Set<UUID>
        let unavailablePromptIDs: Set<UUID>
        let configurationIncludesBodies: Bool
        let paginationCursor: WatchSyncRevision
        let pageCycleCursor: WatchSyncPageCycleCursor?
    }

    private struct MessageRemovalCandidate {
        let conversation: Int
        let message: Int
        let timestamp: Date
        let id: String
    }

    static func build(
        conversations: [Conversation],
        sourceID: UUID = WatchSyncIdentity.legacySourceID,
        snapshotRevision: WatchSyncRevision,
        paginationCursor: WatchSyncRevision? = nil,
        acknowledgedPeerID: UUID? = WatchSyncIdentity.legacyPeerID,
        acknowledgedWatchRevisions: [UUID: WatchSyncRevision] = [:],
        prioritizedAcknowledgementIDs: [UUID] = [],
        tombstoneRevisions: [UUID: WatchSyncRevision] = [:],
        configuration: Configuration = .default,
        resolvedSystemPrompt: ((Conversation) -> String?)? = nil,
        pageCycleCursor: WatchSyncPageCycleCursor? = nil
    ) throws -> WatchSyncPayload {
        let defaults = AppPreferences.storage
        WatchDefaultSystemPromptPublicationGate.prepareForSnapshotBuild(defaults: defaults)
        let result = try buildSnapshot(
            conversations: conversations,
            sourceID: sourceID,
            snapshotRevision: snapshotRevision,
            paginationCursor: paginationCursor,
            acknowledgedPeerID: acknowledgedPeerID,
            acknowledgedWatchRevisions: acknowledgedWatchRevisions,
            prioritizedAcknowledgementIDs: prioritizedAcknowledgementIDs,
            tombstoneRevisions: tombstoneRevisions,
            configuration: configuration,
            resolvedSystemPrompt: resolvedSystemPrompt,
            pageCycleCursor: pageCycleCursor
        ).payload
        WatchDefaultSystemPromptPublicationGate.installIfNeeded(
            configuration: configuration,
            defaults: defaults
        )
        return result
    }

    // swiftlint:disable:next function_body_length function_parameter_count
    private static func buildSnapshot(
        conversations: [Conversation],
        sourceID: UUID,
        snapshotRevision: WatchSyncRevision,
        paginationCursor: WatchSyncRevision?,
        acknowledgedPeerID: UUID?,
        acknowledgedWatchRevisions: [UUID: WatchSyncRevision],
        prioritizedAcknowledgementIDs: [UUID],
        tombstoneRevisions: [UUID: WatchSyncRevision],
        configuration: Configuration,
        resolvedSystemPrompt: ((Conversation) -> String?)?,
        pageCycleCursor: WatchSyncPageCycleCursor?
    ) throws -> SnapshotBuildResult {
        guard configuration.byteBudget > 0 else {
            throw WatchSyncPayloadBuilderError.invalidByteBudget(configuration.byteBudget)
        }

        let sorted = WatchConversationCanonicalizer.phoneConversations(conversations)
        let resolvedConversations = sorted.map { conversation in
            (
                conversation: conversation,
                resolvedSystemPrompt: resolvedSystemPrompt?(conversation)
            )
        }
        let resolvedPaginationCursor = paginationCursor ?? (snapshotRevision > 0 ? snapshotRevision - 1 : 0)
        let fullConfigurations = resolvedConversations.map { resolved in
            boundedRequestConfiguration(
                resolved.conversation,
                configuration: configuration,
                resolvedSystemPrompt: resolved.resolvedSystemPrompt
            )
        }
        let transportPlan = try requestConfigurationTransportPlan(
            fullConfigurations,
            sourceID: sourceID,
            snapshotRevision: snapshotRevision,
            paginationCursor: resolvedPaginationCursor,
            acknowledgedPeerID: acknowledgedPeerID,
            configuration: configuration
        )
        let allConfigurations = transportPlan.values
        let configurationByID = Dictionary(
            allConfigurations.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let bodies = resolvedConversations
            .prefix(max(0, configuration.maximumConversations))
            .filter { !transportPlan.deferredConfigurationIDs.contains($0.conversation.id) }
            .map { resolved in
                boundedConversation(
                    resolved.conversation,
                    acknowledgedRevision: acknowledgedWatchRevisions[resolved.conversation.id] ?? 0,
                    configuration: configuration,
                    resolvedSystemPrompt: configurationByID[resolved.conversation.id]?.resolvedSystemPrompt
                )
            }
        let allManifestIDs = sorted.map(\.id)
        let manifestPage = if let pageCycleCursor {
            page(
                allManifestIDs,
                maximumCount: configuration.maximumManifestConversationIDs,
                offset: pageCycleCursor.manifestOffset
            )
        } else {
            page(
                allManifestIDs,
                maximumCount: configuration.maximumManifestConversationIDs,
                cursor: resolvedPaginationCursor
            )
        }
        let manifest = manifestPage.values
        let manifestSet = Set(allManifestIDs)
        let configurationIncludesBodies = pageCycleCursor != nil
        let deferredConfigurationIDs = try transportPlan.deferredConfigurationIDs.union(
            irreducibleConfigurationIDs(
                in: allConfigurations,
                sourceID: sourceID,
                snapshotRevision: snapshotRevision,
                paginationCursor: resolvedPaginationCursor,
                acknowledgedPeerID: acknowledgedPeerID,
                configuration: configuration,
                pageCycleCursor: pageCycleCursor
            )
        )
        let configurationPage = requestConfigurationPage(
            allConfigurations,
            bodyIDs: configurationIncludesBodies ? [] : Set(bodies.map(\.id)),
            maximumCount: configuration.maximumConversationConfigurations,
            cursor: resolvedPaginationCursor,
            offset: pageCycleCursor?.configurationOffset,
            deferredConfigurationIDs: deferredConfigurationIDs
        )
        let protectedAcknowledgementIDs = Set(prioritizedAcknowledgementIDs + manifest)
        var acknowledgementIDs: [UUID] = []
        var seenAcknowledgementIDs: Set<UUID> = []
        for id in prioritizedAcknowledgementIDs + manifest
            where acknowledgedWatchRevisions[id] != nil && seenAcknowledgementIDs.insert(id).inserted
        {
            acknowledgementIDs.append(id)
        }
        for entry in acknowledgedWatchRevisions.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key.uuidString < rhs.key.uuidString
        }) where seenAcknowledgementIDs.insert(entry.key).inserted {
            acknowledgementIDs.append(entry.key)
        }
        let boundedAcknowledgementIDs = Array(
            acknowledgementIDs.prefix(max(0, configuration.maximumAcknowledgements))
        )
        var boundedAcknowledgements: [UUID: WatchSyncRevision] = [:]
        for id in boundedAcknowledgementIDs {
            boundedAcknowledgements[id] = acknowledgedWatchRevisions[id]
        }
        let sortedTombstones = tombstoneRevisions
            .filter { !manifestSet.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key.uuidString < rhs.key.uuidString
            }
        // Legacy schema-3 publication rotates pages; explicit cycles use exact offsets.
        let tombstonePage = if let pageCycleCursor {
            page(
                sortedTombstones,
                maximumCount: configuration.maximumTombstones,
                offset: pageCycleCursor.tombstoneOffset
            )
        } else {
            rotate(
                sortedTombstones,
                limit: configuration.maximumTombstones,
                cursor: resolvedPaginationCursor
            )
        }
        let boundedTombstoneEntries = tombstonePage.values
        let boundedTombstones = Dictionary(uniqueKeysWithValues: boundedTombstoneEntries)
        var snapshot = WatchSyncSnapshot(
            snapshotRevision: snapshotRevision,
            sourceID: sourceID,
            paginationCursor: resolvedPaginationCursor,
            conversations: bodies,
            authoritativeConversationIDs: manifest,
            authoritativeConversationIDsAreComplete: manifestPage.isComplete,
            conversationConfigurations: configurationPage.values,
            conversationConfigurationsAreComplete: configurationPage.isComplete
                && transportPlan.unavailablePromptIDs.isEmpty,
            acknowledgedPeerID: acknowledgedPeerID,
            acknowledgedWatchRevisions: boundedAcknowledgements,
            tombstoneRevisions: boundedTombstones
        )
        let data = try trimAndEncode(
            &snapshot,
            context: SnapshotTrimContext(
                budget: configuration.byteBudget,
                acknowledgementPriority: boundedAcknowledgementIDs,
                protectedAcknowledgementIDs: protectedAcknowledgementIDs,
                tombstonePriority: boundedTombstoneEntries.map(\.key),
                manifestValues: allManifestIDs,
                manifestMaximumCount: configuration.maximumManifestConversationIDs,
                configurationValues: allConfigurations,
                configurationMaximumCount: configuration.maximumConversationConfigurations,
                deferredConfigurationIDs: deferredConfigurationIDs,
                unavailablePromptIDs: transportPlan.unavailablePromptIDs,
                configurationIncludesBodies: configurationIncludesBodies,
                paginationCursor: resolvedPaginationCursor,
                pageCycleCursor: pageCycleCursor
            )
        )
        let cursorAdvanceCount = pageCycleCursor.map { cursor in
            configurationCursorAdvanceCount(
                in: allConfigurations,
                delivered: snapshot.conversationConfigurations,
                deferredConfigurationIDs: deferredConfigurationIDs,
                maximumCount: configuration.maximumConversationConfigurations,
                offset: cursor.configurationOffset
            )
        } ?? snapshot.conversationConfigurations.count
        return SnapshotBuildResult(
            payload: WatchSyncPayload(snapshot: snapshot, data: data),
            configurationCursorAdvanceCount: cursorAdvanceCount,
            unavailablePromptIDs: transportPlan.unavailablePromptIDs
        )
    }

    static func build(
        state: PhoneWatchSyncState,
        sourceID: UUID = WatchSyncIdentity.legacySourceID,
        snapshotRevision: WatchSyncRevision,
        paginationCursor: WatchSyncRevision? = nil,
        prioritizedAcknowledgementIDs: [UUID] = [],
        configuration: Configuration = .default,
        resolvedSystemPrompt: ((Conversation) -> String?)? = nil,
        pageCycleCursor: WatchSyncPageCycleCursor? = nil
    ) throws -> WatchSyncPayload {
        try build(
            conversations: state.conversations,
            sourceID: sourceID,
            snapshotRevision: snapshotRevision,
            paginationCursor: paginationCursor,
            acknowledgedPeerID: state.peerID,
            acknowledgedWatchRevisions: state.acknowledgedWatchRevisions,
            prioritizedAcknowledgementIDs: prioritizedAcknowledgementIDs,
            tombstoneRevisions: state.tombstoneRevisions,
            configuration: configuration,
            resolvedSystemPrompt: resolvedSystemPrompt,
            pageCycleCursor: pageCycleCursor
        )
    }

    static func buildPageCycle(
        state: PhoneWatchSyncState,
        sourceID: UUID = WatchSyncIdentity.legacySourceID,
        snapshotRevision: WatchSyncRevision,
        cycleID: UUID,
        cursor: WatchSyncPageCycleCursor,
        prioritizedAcknowledgementIDs: [UUID] = [],
        configuration: Configuration = .default,
        resolvedSystemPrompt: ((Conversation) -> String?)? = nil
    ) throws -> WatchSyncPageCyclePayload {
        let defaults = AppPreferences.storage
        WatchDefaultSystemPromptPublicationGate.prepareForSnapshotBuild(defaults: defaults)
        guard cursor.isValid,
              let paginationCursor = WatchSyncRevision(exactly: cursor.pageIndex)
        else {
            throw WatchSyncPayloadBuilderError.invalidPageCycleCursor
        }
        var canonicalState = state
        canonicalState.conversations = WatchConversationCanonicalizer.phoneConversations(state.conversations)
        let buildResult = try buildSnapshot(
            conversations: canonicalState.conversations,
            sourceID: sourceID,
            snapshotRevision: snapshotRevision,
            paginationCursor: paginationCursor,
            acknowledgedPeerID: canonicalState.peerID,
            acknowledgedWatchRevisions: canonicalState.acknowledgedWatchRevisions,
            prioritizedAcknowledgementIDs: prioritizedAcknowledgementIDs,
            tombstoneRevisions: canonicalState.tombstoneRevisions,
            configuration: configuration,
            resolvedSystemPrompt: resolvedSystemPrompt,
            pageCycleCursor: cursor
        )
        let activeIDs = Set(canonicalState.conversations.map(\.id))
        var snapshot = buildResult.payload.snapshot
        let configurationCount = canonicalState.conversations.count
        let tombstoneCount = state.tombstoneRevisions.keys.reduce(into: 0) { count, id in
            if !activeIDs.contains(id) {
                count += 1
            }
        }
        if cursor.manifestOffset >= canonicalState.conversations.count {
            snapshot.authoritativeConversationIDs = []
            snapshot.authoritativeConversationIDsAreComplete = canonicalState.conversations.isEmpty
        }
        if cursor.configurationOffset >= configurationCount {
            snapshot.conversationConfigurations = []
            snapshot.conversationConfigurationsAreComplete = configurationCount == 0
        }
        if cursor.tombstoneOffset >= tombstoneCount {
            snapshot.tombstones = []
        }
        let data = try encode(snapshot)
        let metadata = WatchSyncPageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            snapshotRevision: snapshotRevision,
            cursor: cursor,
            manifest: WatchSyncPageSection(
                offset: cursor.manifestOffset,
                itemCount: snapshot.authoritativeConversationIDs.count,
                totalCount: canonicalState.conversations.count
            ),
            configurations: WatchSyncPageSection(
                offset: cursor.configurationOffset,
                itemCount: snapshot.conversationConfigurations.count,
                totalCount: configurationCount,
                cursorAdvanceCount: buildResult.configurationCursorAdvanceCount,
                containsUnavailablePromptGate: snapshot.conversationConfigurations.contains {
                    buildResult.unavailablePromptIDs.contains($0.id)
                }
            ),
            tombstones: WatchSyncPageSection(
                offset: cursor.tombstoneOffset,
                itemCount: snapshot.tombstones.count,
                totalCount: tombstoneCount
            )
        )
        let sections = [metadata.manifest, metadata.configurations, metadata.tombstones]
        guard sections.allSatisfy({
            $0.offset >= $0.totalCount || $0.cursorAdvanceCount > 0
        }) else {
            throw WatchSyncPayloadBuilderError.pageCycleCannotProgress
        }
        let payload = WatchSyncPageCyclePayload(
            snapshot: snapshot,
            data: data,
            metadata: metadata
        )
        WatchDefaultSystemPromptPublicationGate.installIfNeeded(
            configuration: configuration,
            defaults: defaults
        )
        return payload
    }

    static func encode(_ snapshot: WatchSyncSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    static func buildMutation(
        _ mutation: WatchConversationMutation,
        byteBudget: Int = 48000,
        configuration _: Configuration = .default
    ) throws -> WatchMutationPayload {
        guard byteBudget > 0 else {
            throw WatchSyncPayloadBuilderError.invalidByteBudget(byteBudget)
        }

        let data = try encodeMutation(mutation)
        guard data.count <= byteBudget else {
            throw WatchSyncPayloadBuilderError.mutationExceedsBudget(
                actualBytes: data.count,
                budget: byteBudget
            )
        }
        return WatchMutationPayload(mutation: mutation, data: data)
    }

    static func encodeMutation(_ mutation: WatchConversationMutation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(mutation)
    }

    private static func trimAndEncode(
        _ snapshot: inout WatchSyncSnapshot,
        context: SnapshotTrimContext
    ) throws -> Data {
        var boundedManifestCount = min(
            max(0, context.manifestMaximumCount),
            context.manifestValues.count
        )
        var boundedConfigurationCount = min(
            max(0, context.configurationMaximumCount),
            context.configurationValues.count
        )
        var data = try encode(snapshot)
        while data.count > context.budget {
            if removeOldestMessage(from: &snapshot.conversations) {
                data = try encode(snapshot)
                continue
            }
            if !snapshot.conversations.isEmpty {
                snapshot.conversations.removeLast()
                refreshRequestConfigurationPage(
                    in: &snapshot,
                    values: context.configurationValues,
                    maximumCount: boundedConfigurationCount,
                    cursor: context.paginationCursor,
                    offset: context.pageCycleCursor?.configurationOffset,
                    deferredConfigurationIDs: context.deferredConfigurationIDs,
                    unavailablePromptIDs: context.unavailablePromptIDs,
                    includeBodyConfigurations: context.configurationIncludesBodies
                )
                data = try encode(snapshot)
                continue
            }
            if removeLowestPriorityMetadata(
                from: &snapshot,
                acknowledgementPriority: context.acknowledgementPriority,
                protectedAcknowledgementIDs: context.protectedAcknowledgementIDs,
                tombstonePriority: context.tombstonePriority
            ) {
                data = try encode(snapshot)
                continue
            }
            if boundedConfigurationCount > 1 {
                boundedConfigurationCount -= 1
                refreshRequestConfigurationPage(
                    in: &snapshot,
                    values: context.configurationValues,
                    maximumCount: boundedConfigurationCount,
                    cursor: context.paginationCursor,
                    offset: context.pageCycleCursor?.configurationOffset,
                    deferredConfigurationIDs: context.deferredConfigurationIDs,
                    unavailablePromptIDs: context.unavailablePromptIDs,
                    includeBodyConfigurations: context.configurationIncludesBodies
                )
                data = try encode(snapshot)
                continue
            }
            if boundedManifestCount > 0 {
                boundedManifestCount -= 1
                let manifestPage = if let pageCycleCursor = context.pageCycleCursor {
                    page(
                        context.manifestValues,
                        maximumCount: boundedManifestCount,
                        offset: pageCycleCursor.manifestOffset
                    )
                } else {
                    page(
                        context.manifestValues,
                        maximumCount: boundedManifestCount,
                        cursor: context.paginationCursor
                    )
                }
                snapshot.authoritativeConversationIDs = manifestPage.values
                snapshot.authoritativeConversationIDsAreComplete = manifestPage.isComplete
                data = try encode(snapshot)
                continue
            }
            if boundedConfigurationCount > 0 {
                boundedConfigurationCount -= 1
                refreshRequestConfigurationPage(
                    in: &snapshot,
                    values: context.configurationValues,
                    maximumCount: boundedConfigurationCount,
                    cursor: context.paginationCursor,
                    offset: context.pageCycleCursor?.configurationOffset,
                    deferredConfigurationIDs: context.deferredConfigurationIDs,
                    unavailablePromptIDs: context.unavailablePromptIDs,
                    includeBodyConfigurations: context.configurationIncludesBodies
                )
                data = try encode(snapshot)
                continue
            }
            throw WatchSyncPayloadBuilderError.irreducibleSnapshotExceedsBudget(
                actualBytes: data.count,
                budget: context.budget
            )
        }
        return data
    }

    private static func removeLowestPriorityMetadata(
        from snapshot: inout WatchSyncSnapshot,
        acknowledgementPriority: [UUID],
        protectedAcknowledgementIDs: Set<UUID>,
        tombstonePriority: [UUID]
    ) -> Bool {
        if let acknowledgementID = acknowledgementPriority.reversed().first(where: {
            snapshot.acknowledgedWatchRevisions[$0] != nil && !protectedAcknowledgementIDs.contains($0)
        }) {
            snapshot.acknowledgedWatchRevisions.removeValue(forKey: acknowledgementID)
            return true
        }

        let presentTombstoneIDs = Set(snapshot.tombstones.map(\.conversationID))
        if let tombstoneID = tombstonePriority.dropFirst().reversed().first(where: {
            presentTombstoneIDs.contains($0)
        }) {
            snapshot.tombstones.removeAll { $0.conversationID == tombstoneID }
            return true
        }

        if let acknowledgementID = acknowledgementPriority.reversed().first(where: {
            snapshot.acknowledgedWatchRevisions[$0] != nil
        }) {
            snapshot.acknowledgedWatchRevisions.removeValue(forKey: acknowledgementID)
            return true
        }

        if let tombstoneID = tombstonePriority.reversed().first(where: {
            presentTombstoneIDs.contains($0)
        }) {
            snapshot.tombstones.removeAll { $0.conversationID == tombstoneID }
            return true
        }

        return false
    }

    private static func removeOldestMessage(
        from conversations: inout [WatchConversation]
    ) -> Bool {
        var candidate: MessageRemovalCandidate?
        for conversationIndex in conversations.indices {
            for messageIndex in conversations[conversationIndex].messages.indices {
                let message = conversations[conversationIndex].messages[messageIndex]
                let proposed = MessageRemovalCandidate(
                    conversation: conversationIndex,
                    message: messageIndex,
                    timestamp: message.timestamp,
                    id: message.id.uuidString
                )
                if let current = candidate {
                    if proposed.timestamp < current.timestamp
                        || (proposed.timestamp == current.timestamp && proposed.id < current.id)
                    {
                        candidate = proposed
                    }
                } else {
                    candidate = proposed
                }
            }
        }
        guard let candidate else { return false }
        conversations[candidate.conversation].messages.remove(at: candidate.message)
        return true
    }

    private static func page<Element>(
        _ values: [Element],
        maximumCount: Int,
        cursor: WatchSyncRevision
    ) -> Page<Element> {
        guard !values.isEmpty else {
            return Page(values: [], isComplete: true)
        }

        let boundedMaximum = max(0, maximumCount)
        guard boundedMaximum < values.count else {
            return Page(values: values, isComplete: true)
        }
        guard boundedMaximum > 0 else {
            return Page(values: [], isComplete: false)
        }

        let pageCount = ((values.count - 1) / boundedMaximum) + 1
        let pageIndex = Int(cursor % WatchSyncRevision(pageCount))
        let start = pageIndex * boundedMaximum
        let end = min(values.count, start + boundedMaximum)
        return Page(values: Array(values[start ..< end]), isComplete: false)
    }

    private static func page<Element>(
        _ values: [Element],
        maximumCount: Int,
        offset: Int
    ) -> Page<Element> {
        guard !values.isEmpty else {
            return Page(values: [], isComplete: true)
        }

        let boundedOffset = max(0, offset)
        let boundedMaximum = max(0, maximumCount)
        guard boundedOffset < values.count else {
            return Page(values: [], isComplete: false)
        }
        guard boundedMaximum > 0 else {
            return Page(values: [], isComplete: false)
        }

        let end = min(values.count, boundedOffset + boundedMaximum)
        let isComplete = boundedOffset == 0 && end == values.count
        return Page(values: Array(values[boundedOffset ..< end]), isComplete: isComplete)
    }

    private static func rotate<T>(_ values: [T], limit: Int, cursor: WatchSyncRevision) -> Page<T> {
        let selected = page(values, maximumCount: limit, cursor: cursor)
        guard !selected.isComplete, selected.values.count > 1 else { return selected }
        let pageCount = ((values.count - 1) / limit) + 1
        let cycle = cursor / WatchSyncRevision(pageCount)
        let offset = Int(cycle % WatchSyncRevision(selected.values.count))
        guard offset > 0 else { return selected }
        let rotated = Array(selected.values[offset...]) + Array(selected.values[..<offset])
        return Page(values: rotated, isComplete: false)
    }

    private static func requestConfigurationTransportPlan(
        _ values: [WatchConversationRequestConfiguration],
        sourceID: UUID,
        snapshotRevision: WatchSyncRevision,
        paginationCursor: WatchSyncRevision,
        acknowledgedPeerID: UUID?,
        configuration: Configuration
    ) throws -> RequestConfigurationTransportPlan {
        var transportedValues: [WatchConversationRequestConfiguration] = []
        var unavailablePromptIDs: Set<UUID> = []
        var deferredConfigurationIDs: Set<UUID> = []

        for value in values {
            guard value.resolvedSystemPrompt != nil,
                  try !configurationFits(
                      value,
                      sourceID: sourceID,
                      snapshotRevision: snapshotRevision,
                      paginationCursor: paginationCursor,
                      acknowledgedPeerID: acknowledgedPeerID,
                      byteBudget: configuration.byteBudget
                  )
            else {
                transportedValues.append(value)
                continue
            }

            var availabilityGate = value
            availabilityGate.resolvedSystemPrompt = nil
            if try configurationFits(
                availabilityGate,
                sourceID: sourceID,
                snapshotRevision: snapshotRevision,
                paginationCursor: paginationCursor,
                acknowledgedPeerID: acknowledgedPeerID,
                byteBudget: configuration.byteBudget
            ) {
                transportedValues.append(availabilityGate)
                unavailablePromptIDs.insert(value.id)
            } else {
                transportedValues.append(value)
                deferredConfigurationIDs.insert(value.id)
            }
        }

        return RequestConfigurationTransportPlan(
            values: transportedValues,
            unavailablePromptIDs: unavailablePromptIDs,
            deferredConfigurationIDs: deferredConfigurationIDs
        )
    }

    private static func configurationFits(
        _ candidate: WatchConversationRequestConfiguration,
        sourceID: UUID,
        snapshotRevision: WatchSyncRevision,
        paginationCursor: WatchSyncRevision,
        acknowledgedPeerID: UUID?,
        byteBudget: Int
    ) throws -> Bool {
        let minimalSnapshot = WatchSyncSnapshot(
            snapshotRevision: snapshotRevision,
            sourceID: sourceID,
            paginationCursor: paginationCursor,
            conversations: [],
            authoritativeConversationIDs: [],
            authoritativeConversationIDsAreComplete: false,
            conversationConfigurations: [candidate],
            conversationConfigurationsAreComplete: false,
            acknowledgedPeerID: acknowledgedPeerID,
            acknowledgedWatchRevisions: [:],
            tombstoneRevisions: [:]
        )
        return try encode(minimalSnapshot).count <= byteBudget
    }

    private static func irreducibleConfigurationIDs(
        in values: [WatchConversationRequestConfiguration],
        sourceID: UUID,
        snapshotRevision: WatchSyncRevision,
        paginationCursor: WatchSyncRevision,
        acknowledgedPeerID: UUID?,
        configuration: Configuration,
        pageCycleCursor: WatchSyncPageCycleCursor?
    ) throws -> Set<UUID> {
        guard let pageCycleCursor else { return [] }
        let candidates = page(
            values,
            maximumCount: configuration.maximumConversationConfigurations,
            offset: pageCycleCursor.configurationOffset
        ).values
        guard !candidates.isEmpty else { return [] }

        let singleConfigurationIsComplete = pageCycleCursor.configurationOffset == 0
            && values.count == 1
        var deferredIDs: Set<UUID> = []
        for candidate in candidates {
            let minimalSnapshot = WatchSyncSnapshot(
                snapshotRevision: snapshotRevision,
                sourceID: sourceID,
                paginationCursor: paginationCursor,
                conversations: [],
                authoritativeConversationIDs: [],
                authoritativeConversationIDsAreComplete: false,
                conversationConfigurations: [candidate],
                conversationConfigurationsAreComplete: singleConfigurationIsComplete,
                acknowledgedPeerID: acknowledgedPeerID,
                acknowledgedWatchRevisions: [:],
                tombstoneRevisions: [:]
            )
            if try encode(minimalSnapshot).count > configuration.byteBudget {
                deferredIDs.insert(candidate.id)
            }
        }
        return deferredIDs
    }

    private static func configurationCursorAdvanceCount(
        in values: [WatchConversationRequestConfiguration],
        delivered: [WatchConversationRequestConfiguration],
        deferredConfigurationIDs: Set<UUID>,
        maximumCount: Int,
        offset: Int
    ) -> Int {
        let boundedMaximum = max(0, maximumCount)
        guard offset >= 0, offset < values.count, boundedMaximum > 0 else { return 0 }
        let end = min(values.count, offset + boundedMaximum)
        var sourceIndex = offset
        var deliveredIndex = 0

        while sourceIndex < end {
            let candidate = values[sourceIndex]
            if deferredConfigurationIDs.contains(candidate.id) {
                sourceIndex += 1
                continue
            }
            guard deliveredIndex < delivered.count,
                  candidate == delivered[deliveredIndex]
            else {
                break
            }
            sourceIndex += 1
            deliveredIndex += 1
        }

        guard deliveredIndex == delivered.count else { return 0 }
        return sourceIndex - offset
    }

    private static func requestConfigurationPage(
        _ values: [WatchConversationRequestConfiguration],
        bodyIDs: Set<UUID>,
        maximumCount: Int,
        cursor: WatchSyncRevision,
        offset: Int? = nil,
        deferredConfigurationIDs: Set<UUID> = []
    ) -> Page<WatchConversationRequestConfiguration> {
        let filtered = values.filter { !bodyIDs.contains($0.id) }
        let selected = if let offset {
            page(filtered, maximumCount: maximumCount, offset: offset)
        } else {
            page(filtered, maximumCount: maximumCount, cursor: cursor)
        }
        guard !deferredConfigurationIDs.isEmpty else { return selected }
        let delivered = selected.values.filter { !deferredConfigurationIDs.contains($0.id) }
        return Page(
            values: delivered,
            isComplete: selected.isComplete && delivered.count == selected.values.count
        )
    }

    private static func refreshRequestConfigurationPage(
        in snapshot: inout WatchSyncSnapshot,
        values: [WatchConversationRequestConfiguration],
        maximumCount: Int,
        cursor: WatchSyncRevision,
        offset: Int? = nil,
        deferredConfigurationIDs: Set<UUID> = [],
        unavailablePromptIDs: Set<UUID> = [],
        includeBodyConfigurations: Bool = false
    ) {
        let configurationPage = requestConfigurationPage(
            values,
            bodyIDs: includeBodyConfigurations ? [] : Set(snapshot.conversations.map(\.id)),
            maximumCount: maximumCount,
            cursor: cursor,
            offset: offset,
            deferredConfigurationIDs: deferredConfigurationIDs
        )
        snapshot.conversationConfigurations = configurationPage.values
        snapshot.conversationConfigurationsAreComplete = configurationPage.isComplete
            && unavailablePromptIDs.isEmpty
    }

    private static func boundedRequestConfiguration(
        _ conversation: Conversation,
        configuration _: Configuration,
        resolvedSystemPrompt: String?
    ) -> WatchConversationRequestConfiguration {
        WatchConversationRequestConfiguration(
            id: conversation.id,
            model: conversation.model,
            temperature: conversation.temperature,
            resolvedSystemPrompt: resolvedSystemPrompt
        )
    }

    private static func boundedConversation(
        _ conversation: Conversation,
        acknowledgedRevision: WatchSyncRevision,
        configuration: Configuration,
        resolvedSystemPrompt: String?
    ) -> WatchConversation {
        var boundedConversation = WatchConversation(
            from: conversation,
            resolvedSystemPrompt: resolvedSystemPrompt,
            watchRevision: acknowledgedRevision,
            maximumMessages: max(0, configuration.maximumMessagesPerConversation)
        )
        boundedConversation.title = bounded(
            boundedConversation.title,
            maximum: configuration.maximumTitleCharacters
        )
        boundedConversation.messages = boundedConversation.messages.map {
            boundedMessage($0, configuration: configuration)
        }
        return boundedConversation
    }

    private static func boundedMessage(
        _ message: WatchMessage,
        configuration: Configuration
    ) -> WatchMessage {
        var result = message
        result.content = bounded(message.content, maximum: configuration.maximumContentCharacters)
        result.toolCalls = message.toolCalls.map { calls in
            Array(calls.prefix(max(0, configuration.maximumToolCallsPerMessage))).compactMap {
                boundedToolCall($0, configuration: configuration)
            }
        }
        result.citations = message.citations.map { citations in
            Array(citations.prefix(max(0, configuration.maximumCitationsPerMessage))).map {
                CitationReference(
                    number: $0.number,
                    title: bounded($0.title, maximum: configuration.maximumCitationCharacters),
                    url: bounded($0.url, maximum: configuration.maximumCitationCharacters),
                    favicon: $0.favicon.map {
                        bounded($0, maximum: configuration.maximumCitationCharacters)
                    }
                )
            }
        }
        return result
    }

    private static func boundedToolCall(
        _ call: MCPToolCall,
        configuration: Configuration
    ) -> MCPToolCall? {
        let byteLimit = max(0, configuration.maximumToolMetadataBytes)
        guard byteLimit > 0 else { return nil }

        var arguments = call.arguments
        var result = call.result.map { bounded($0, maximum: byteLimit) }
        var error = call.error.map { bounded($0, maximum: byteLimit) }
        var toolName = bounded(call.toolName, maximum: min(byteLimit, 256))
        var identifier = bounded(call.id, maximum: min(byteLimit, 256))

        func makeCall() -> MCPToolCall {
            MCPToolCall(
                id: identifier,
                toolName: toolName,
                arguments: arguments,
                result: result,
                error: error,
                timestamp: call.timestamp
            )
        }

        var candidate = makeCall()
        while encodedSize(candidate) > byteLimit, let key = arguments.keys.sorted().last {
            arguments.removeValue(forKey: key)
            candidate = makeCall()
        }
        while encodedSize(candidate) > byteLimit, result?.isEmpty == false {
            result = result.map { String($0.prefix(max(0, $0.count / 2))) }
            candidate = makeCall()
        }
        while encodedSize(candidate) > byteLimit, error?.isEmpty == false {
            error = error.map { String($0.prefix(max(0, $0.count / 2))) }
            candidate = makeCall()
        }
        while encodedSize(candidate) > byteLimit, toolName.count > 1 {
            toolName = String(toolName.prefix(max(1, toolName.count / 2)))
            candidate = makeCall()
        }
        while encodedSize(candidate) > byteLimit, identifier.count > 1 {
            identifier = String(identifier.prefix(max(1, identifier.count / 2)))
            candidate = makeCall()
        }
        return encodedSize(candidate) <= byteLimit ? candidate : nil
    }

    private static func encodedSize(_ call: MCPToolCall) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(call).count) ?? .max
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        String(value.prefix(max(0, maximum)))
    }
}
