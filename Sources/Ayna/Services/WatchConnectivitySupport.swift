// swiftlint:disable file_length
//
//  WatchConnectivitySupport.swift
//  ayna
//
//  Thread-safe identity fencing shared by iOS and watchOS WCSession delegates.
//

import Combine
import CoreFoundation
import CryptoKit
import Foundation

struct WatchMutationReply: Sendable {
    let status: String
    let conversationID: UUID
    let operationID: UUID
    let acknowledgedRevision: WatchSyncRevision?

    static func retry(for mutation: WatchConversationMutation) -> Self {
        Self(
            status: "retry",
            conversationID: mutation.conversationID,
            operationID: mutation.operationID,
            acknowledgedRevision: nil
        )
    }

    static func unsupported(for mutation: WatchConversationMutation) -> Self {
        Self(
            status: "unsupported",
            conversationID: mutation.conversationID,
            operationID: mutation.operationID,
            acknowledgedRevision: nil
        )
    }

    static func acknowledged(
        _ mutation: WatchConversationMutation,
        revision: WatchSyncRevision
    ) -> Self {
        Self(
            status: "acknowledged",
            conversationID: mutation.conversationID,
            operationID: mutation.operationID,
            acknowledgedRevision: revision
        )
    }

    var message: [String: Any] {
        var result: [String: Any] = [
            "type": "watchConversationMutationAck",
            "status": status,
            "conversationId": conversationID.uuidString,
            "operationId": operationID.uuidString
        ]
        if let acknowledgedRevision {
            result["acknowledgedRevision"] = NSNumber(value: acknowledgedRevision)
        }
        return result
    }
}

private struct WatchLegacyTitleDelivery: Codable {
    var title: String
    var revision: WatchSyncRevision?
}

private struct WatchLegacyTitleSequenceEntry: Codable, Equatable {
    var title: String
    var revision: WatchSyncRevision
}

enum WatchLegacyComponentIdentity {
    static func create(conversationID: UUID, revision: WatchSyncRevision) -> String {
        "create:\(conversationID.uuidString):\(revision)"
    }

    static func message(messageID: UUID, revision: WatchSyncRevision) -> String {
        "message:\(messageID.uuidString):\(revision)"
    }

    static func title(conversationID: UUID, revision: WatchSyncRevision) -> String {
        "title:\(conversationID.uuidString):\(revision)"
    }

    static func requiredComponentIDs(for mutation: WatchConversationMutation) -> Set<String> {
        guard !mutation.fields.contains(.delete) else { return [] }
        var componentIDs: Set<String> = []
        if mutation.fields.contains(.create) {
            componentIDs.insert(create(
                conversationID: mutation.conversationID,
                revision: mutation.createRevision ?? mutation.revision
            ))
        }
        if mutation.fields.contains(.messages) {
            for message in mutation.messageChanges {
                componentIDs.insert(self.message(
                    messageID: message.id,
                    revision: mutation.messageChangeRevisions[message.id] ?? mutation.revision
                ))
            }
        }
        if mutation.fields.contains(.create) || mutation.fields.contains(.title) {
            componentIDs.insert(title(
                conversationID: mutation.conversationID,
                revision: mutation.titleRevision ?? mutation.createRevision ?? mutation.revision
            ))
        }
        return componentIDs
    }
}

enum WatchLegacyTransferCompletionResolver {
    static func pendingMutation(
        originalOperationID: UUID,
        componentID: String,
        pendingMutations: [WatchConversationMutation]
    ) -> WatchConversationMutation? {
        let matches = pendingMutations.filter {
            WatchLegacyComponentIdentity.requiredComponentIDs(for: $0).contains(componentID)
        }
        return matches.first { $0.operationID == originalOperationID } ?? matches.max {
            if $0.revision != $1.revision {
                return $0.revision < $1.revision
            }
            return $0.operationID.uuidString < $1.operationID.uuidString
        }
    }
}

private struct WatchLegacyDeliveryTrackerState: Codable {
    var createdConversationIDs: Set<UUID> = []
    var messageRevisions: [UUID: [UUID: WatchSyncRevision]] = [:]
    var titleDeliveries: [UUID: WatchLegacyTitleDelivery] = [:]
    var titleSequences: [UUID: [WatchLegacyTitleSequenceEntry]] = [:]
    var configurationRevisions: [UUID: WatchSyncRevision] = [:]
    var awaitingEchoComponentIDs: Set<String> = []
    var awaitingEchoAttempts: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case createdConversationIDs
        case messageRevisions
        case titleDeliveries
        case titleSequences
        case titles
        case configurationRevisions
        case awaitingEchoComponentIDs
        case awaitingEchoAttempts
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdConversationIDs = try container.decodeIfPresent(
            Set<UUID>.self,
            forKey: .createdConversationIDs
        ) ?? []
        messageRevisions = try container.decodeIfPresent(
            [UUID: [UUID: WatchSyncRevision]].self,
            forKey: .messageRevisions
        ) ?? [:]
        configurationRevisions = try container.decodeIfPresent(
            [UUID: WatchSyncRevision].self,
            forKey: .configurationRevisions
        ) ?? [:]
        awaitingEchoComponentIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .awaitingEchoComponentIDs
        ) ?? []
        awaitingEchoAttempts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .awaitingEchoAttempts
        ) ?? [:]
        titleSequences = try container.decodeIfPresent(
            [UUID: [WatchLegacyTitleSequenceEntry]].self,
            forKey: .titleSequences
        ) ?? [:]

        if let deliveries = try container.decodeIfPresent(
            [UUID: WatchLegacyTitleDelivery].self,
            forKey: .titleDeliveries
        ) {
            titleDeliveries = deliveries
        } else {
            let legacyTitles = try container.decodeIfPresent(
                [UUID: String].self,
                forKey: .titles
            ) ?? [:]
            titleDeliveries = legacyTitles.mapValues {
                WatchLegacyTitleDelivery(title: $0, revision: nil)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createdConversationIDs, forKey: .createdConversationIDs)
        try container.encode(messageRevisions, forKey: .messageRevisions)
        try container.encode(titleDeliveries, forKey: .titleDeliveries)
        try container.encode(titleSequences, forKey: .titleSequences)
        try container.encode(configurationRevisions, forKey: .configurationRevisions)
        try container.encode(awaitingEchoComponentIDs, forKey: .awaitingEchoComponentIDs)
        try container.encode(awaitingEchoAttempts, forKey: .awaitingEchoAttempts)
    }
}

struct WatchLegacyMessageSendSelection: Sendable {
    let messages: [WatchMessage]
    let awaitingEchoComponentIDs: Set<String>
}

@MainActor
final class WatchLegacyDeliveryTracker {
    private static let maximumAwaitingEchoAttempts = 3

    private let userDefaults: UserDefaults
    private let persistenceKey: String
    private var state: WatchLegacyDeliveryTrackerState

    init(
        userDefaults: UserDefaults = .standard,
        persistenceKey: String = "com.sertacozercan.ayna.watch.legacyDeliveryState"
    ) {
        self.userDefaults = userDefaults
        self.persistenceKey = persistenceKey
        if let data = userDefaults.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(WatchLegacyDeliveryTrackerState.self, from: data)
        {
            state = decoded
        } else {
            state = WatchLegacyDeliveryTrackerState()
        }
    }

    func reset() {
        state = WatchLegacyDeliveryTrackerState()
        persist()
    }

    func needsCreate(conversationID: UUID) -> Bool {
        !state.createdConversationIDs.contains(conversationID)
    }

    func pendingMessages(from mutation: WatchConversationMutation) -> [WatchMessage] {
        let revisions = state.messageRevisions[mutation.conversationID] ?? [:]
        return mutation.messageChanges.filter { message in
            let revision = mutation.messageChangeRevisions[message.id] ?? mutation.revision
            return revision > revisions[message.id, default: 0]
        }
    }

    func pendingMessageBatch(
        from mutation: WatchConversationMutation,
        maximumCount: Int
    ) -> [WatchMessage] {
        pendingMessageSendSelection(
            from: mutation,
            maximumCount: maximumCount
        ).messages
    }

    func pendingMessageSendSelection(
        from mutation: WatchConversationMutation,
        maximumCount: Int
    ) -> WatchLegacyMessageSendSelection {
        guard maximumCount > 0 else {
            return WatchLegacyMessageSendSelection(
                messages: [],
                awaitingEchoComponentIDs: []
            )
        }
        let revisions = state.messageRevisions[mutation.conversationID] ?? [:]
        let candidates = mutation.messageChanges.compactMap { message -> (WatchMessage, String)? in
            let revision = mutation.messageChangeRevisions[message.id] ?? mutation.revision
            guard revision > revisions[message.id, default: 0] else { return nil }
            return (
                message,
                WatchLegacyComponentIdentity.message(messageID: message.id, revision: revision)
            )
        }
        let awaitingBefore = state.awaitingEchoComponentIDs
        let echoState = advanceAwaitingEcho(candidates.map(\.1))
        let neverSent = candidates.filter {
            !awaitingBefore.contains($0.1) && !echoState.deferred.contains($0.1)
        }.map(\.0)
        let expiredRetransmissions = candidates.filter {
            echoState.expired.contains($0.1)
        }.map(\.0)
        let availableCapacity = max(0, maximumCount - echoState.deferred.count)
        return WatchLegacyMessageSendSelection(
            messages: Array((neverSent + expiredRetransmissions).prefix(availableCapacity)),
            awaitingEchoComponentIDs: echoState.deferred
        )
    }

    func needsTitle(
        conversationID: UUID,
        title: String,
        revision: WatchSyncRevision
    ) -> Bool {
        guard let delivery = state.titleDeliveries[conversationID],
              let deliveredRevision = delivery.revision
        else {
            return true
        }
        if revision != deliveredRevision {
            return revision > deliveredRevision
        }
        return delivery.title != title
    }

    func recordTitleMutation(_ mutation: WatchConversationMutation) {
        guard mutation.fields.contains(.create) || mutation.fields.contains(.title) else { return }
        let revision = mutation.titleRevision ?? mutation.createRevision ?? mutation.revision
        guard recordTitleSequence(
            conversationID: mutation.conversationID,
            title: mutation.conversation.title,
            revision: revision
        ) else {
            return
        }
        persist()
    }

    func reconcile(
        _ mutation: WatchConversationMutation,
        echoedConversations: [WatchConversation]
    ) -> WatchLegacyEchoReconciliation {
        let titleRevision = mutation.titleRevision ?? mutation.createRevision ?? mutation.revision
        return WatchLegacyEchoReconciler.reconcile(
            mutation,
            echoedConversations: echoedConversations
        ) { [self] echo in
            guard titleEchoRequiresFreshEvidence(
                conversationID: mutation.conversationID,
                title: mutation.conversation.title,
                revision: titleRevision
            ) else {
                return true
            }
            if echo.watchRevision > 0 {
                return echo.watchRevision >= titleRevision
            }
            return echo.updatedAt > mutation.conversation.updatedAt
        }
    }

    func configurationIsRepresented(
        by mutation: WatchConversationMutation,
        createWillBeSent: Bool
    ) -> Bool {
        guard mutation.fields.contains(.configuration) else { return true }
        let revision = max(mutation.createRevision ?? 0, mutation.configurationRevision ?? 0)
        return revision <= state.configurationRevisions[mutation.conversationID, default: 0] || createWillBeSent
    }

    func advanceAwaitingEcho(
        _ componentIDs: [String]
    ) -> (deferred: Set<String>, expired: Set<String>) {
        var deferred: Set<String> = []
        var expired: Set<String> = []
        var stateChanged = false
        for componentID in Set(componentIDs) where state.awaitingEchoComponentIDs.contains(componentID) {
            let attempts = state.awaitingEchoAttempts[componentID, default: 0]
            if attempts >= Self.maximumAwaitingEchoAttempts {
                state.awaitingEchoComponentIDs.remove(componentID)
                state.awaitingEchoAttempts.removeValue(forKey: componentID)
                expired.insert(componentID)
            } else {
                state.awaitingEchoAttempts[componentID] = attempts + 1
                deferred.insert(componentID)
            }
            stateChanged = true
        }
        if stateChanged {
            persist()
        }
        return (deferred, expired)
    }

    func recordTransferCompletion(componentID: String, succeeded: Bool) {
        guard !componentID.isEmpty else { return }
        let changed: Bool
        if succeeded {
            let inserted = state.awaitingEchoComponentIDs.insert(componentID).inserted
            let attemptsChanged = state.awaitingEchoAttempts.updateValue(0, forKey: componentID) != 0
            changed = inserted || attemptsChanged
        } else {
            let removed = state.awaitingEchoComponentIDs.remove(componentID) != nil
            let removedAttempts = state.awaitingEchoAttempts.removeValue(forKey: componentID) != nil
            changed = removed || removedAttempts
        }
        if changed {
            persist()
        }
    }

    func isAwaitingEcho(componentID: String) -> Bool {
        state.awaitingEchoComponentIDs.contains(componentID)
    }

    func confirm(_ userInfo: [String: Any]) {
        guard let conversationID = (userInfo[WatchMessageKeys.conversationId] as? String)
            .flatMap(UUID.init(uuidString:)),
            let kind = userInfo[WatchMessageKeys.legacyComponentKind] as? String
        else {
            return
        }
        let clearedAwaitingEcho = legacyComponentID(from: userInfo).map {
            let removed = state.awaitingEchoComponentIDs.remove($0) != nil
            let removedAttempts = state.awaitingEchoAttempts.removeValue(forKey: $0) != nil
            return removed || removedAttempts
        } ?? false

        switch kind {
        case WatchMessageKeys.legacyComponentCreate:
            state.createdConversationIDs.insert(conversationID)
            if let revision = WatchSyncValueDecoder.revision(
                userInfo[WatchMessageKeys.configurationRevision]
            ) {
                state.configurationRevisions[conversationID] = max(
                    state.configurationRevisions[conversationID, default: 0],
                    revision
                )
            }
        case WatchMessageKeys.legacyComponentMessage:
            guard let messageID = (userInfo[WatchMessageKeys.messageId] as? String)
                .flatMap(UUID.init(uuidString:)),
                let revision = WatchSyncValueDecoder.revision(userInfo[WatchMessageKeys.mutationRevision])
            else {
                if clearedAwaitingEcho {
                    persist()
                }
                return
            }
            var revisions = state.messageRevisions[conversationID] ?? [:]
            revisions[messageID] = max(revisions[messageID, default: 0], revision)
            state.messageRevisions[conversationID] = revisions
        case WatchMessageKeys.legacyComponentTitle:
            guard let title = userInfo[WatchMessageKeys.title] as? String else { return }
            let revision = WatchSyncValueDecoder.revision(userInfo[WatchMessageKeys.mutationRevision])
            if let deliveredRevision = state.titleDeliveries[conversationID]?.revision {
                guard let revision, revision >= deliveredRevision else {
                    if clearedAwaitingEcho {
                        persist()
                    }
                    return
                }
            }
            if let revision {
                _ = recordTitleSequence(
                    conversationID: conversationID,
                    title: title,
                    revision: revision
                )
            }
            state.titleDeliveries[conversationID] = WatchLegacyTitleDelivery(
                title: title,
                revision: revision
            )
        default:
            if clearedAwaitingEcho {
                persist()
            }
            return
        }
        persist()
    }

    private func legacyComponentID(from userInfo: [String: Any]) -> String? {
        if let componentID = userInfo[WatchMessageKeys.legacyComponentId] as? String {
            return componentID
        }
        guard let kind = userInfo[WatchMessageKeys.legacyComponentKind] as? String,
              let revision = WatchSyncValueDecoder.revision(userInfo[WatchMessageKeys.mutationRevision])
        else {
            return nil
        }
        switch kind {
        case WatchMessageKeys.legacyComponentCreate:
            guard let conversationID = (userInfo[WatchMessageKeys.conversationId] as? String)
                .flatMap(UUID.init(uuidString:))
            else {
                return nil
            }
            return WatchLegacyComponentIdentity.create(
                conversationID: conversationID,
                revision: revision
            )
        case WatchMessageKeys.legacyComponentMessage:
            guard let messageID = (userInfo[WatchMessageKeys.messageId] as? String)
                .flatMap(UUID.init(uuidString:))
            else {
                return nil
            }
            return WatchLegacyComponentIdentity.message(
                messageID: messageID,
                revision: revision
            )
        case WatchMessageKeys.legacyComponentTitle:
            guard let conversationID = (userInfo[WatchMessageKeys.conversationId] as? String)
                .flatMap(UUID.init(uuidString:))
            else {
                return nil
            }
            return WatchLegacyComponentIdentity.title(
                conversationID: conversationID,
                revision: revision
            )
        default:
            return nil
        }
    }

    private func recordTitleSequence(
        conversationID: UUID,
        title: String,
        revision: WatchSyncRevision
    ) -> Bool {
        var sequence = state.titleSequences[conversationID] ?? []
        if let index = sequence.firstIndex(where: { $0.revision == revision }) {
            guard sequence[index].title != title else { return false }
            sequence[index].title = title
        } else {
            sequence.append(WatchLegacyTitleSequenceEntry(title: title, revision: revision))
        }
        sequence.sort { $0.revision < $1.revision }
        state.titleSequences[conversationID] = sequence
        return true
    }

    private func titleEchoRequiresFreshEvidence(
        conversationID: UUID,
        title: String,
        revision: WatchSyncRevision
    ) -> Bool {
        var sequence = state.titleSequences[conversationID] ?? []
        if let delivery = state.titleDeliveries[conversationID] {
            let deliveredEntry = WatchLegacyTitleSequenceEntry(
                title: delivery.title,
                revision: delivery.revision ?? 0
            )
            if !sequence.contains(deliveredEntry) {
                sequence.append(deliveredEntry)
            }
        }
        sequence.sort { $0.revision < $1.revision }

        guard let previousMatchingRevision = sequence.last(where: {
            $0.revision < revision && $0.title == title
        })?.revision else {
            return false
        }
        return sequence.contains {
            $0.revision > previousMatchingRevision
                && $0.revision < revision
                && $0.title != title
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: persistenceKey)
    }
}

enum WatchLegacyEchoComponent: Equatable, Hashable, Sendable {
    case create(revision: WatchSyncRevision)
    case title(revision: WatchSyncRevision)
    case configuration(revision: WatchSyncRevision)
    case message(id: UUID, revision: WatchSyncRevision)

    var shouldRecordInStoreCoverage: Bool {
        // Store create coverage also suppresses title and configuration replay. Keep those
        // components independent until the complete representable mutation is acknowledged.
        if case .create = self {
            return false
        }
        return true
    }

    func deliveryUserInfo(for mutation: WatchConversationMutation) -> [String: Any] {
        var userInfo: [String: Any] = [
            WatchMessageKeys.conversationId: mutation.conversationID.uuidString,
            WatchMessageKeys.operationId: mutation.operationID.uuidString,
            WatchMessageKeys.peerId: mutation.peerID.uuidString
        ]
        switch self {
        case let .create(revision):
            userInfo[WatchMessageKeys.legacyComponentKind] = WatchMessageKeys.legacyComponentCreate
            userInfo[WatchMessageKeys.mutationRevision] = NSNumber(value: revision)
        case let .title(revision):
            userInfo[WatchMessageKeys.legacyComponentKind] = WatchMessageKeys.legacyComponentTitle
            userInfo[WatchMessageKeys.mutationRevision] = NSNumber(value: revision)
            userInfo[WatchMessageKeys.title] = mutation.conversation.title
        case let .configuration(revision):
            userInfo[WatchMessageKeys.legacyComponentKind] = WatchMessageKeys.legacyComponentCreate
            userInfo[WatchMessageKeys.configurationRevision] = NSNumber(value: revision)
        case let .message(id, revision):
            userInfo[WatchMessageKeys.legacyComponentKind] = WatchMessageKeys.legacyComponentMessage
            userInfo[WatchMessageKeys.messageId] = id.uuidString
            userInfo[WatchMessageKeys.mutationRevision] = NSNumber(value: revision)
        }
        return userInfo
    }
}

enum WatchLegacyConversationMerger {
    static func mergeCreate(
        _ watchConversation: WatchConversation,
        into existingConversation: Conversation?
    ) -> Conversation {
        let created = watchConversation.toConversation()
        guard var existingConversation else { return created }

        existingConversation.title = created.title
        existingConversation.model = created.model
        existingConversation.systemPromptMode = created.systemPromptMode
        existingConversation.temperature = created.temperature
        existingConversation.createdAt = created.createdAt
        existingConversation.updatedAt = max(existingConversation.updatedAt, created.updatedAt)

        var existingMessageIDs = Set(existingConversation.messages.map(\.id))
        for message in created.messages where existingMessageIDs.insert(message.id).inserted {
            existingConversation.messages.append(message)
        }
        return existingConversation
    }
}

struct WatchLegacyEchoReconciliation: Equatable, Sendable {
    let matchedComponents: [WatchLegacyEchoComponent]
    let unsupportedFields: WatchConversationMutationFields
    let canAcknowledgeMutation: Bool
}

enum WatchLegacyEchoReconciler {
    static func reconcile(
        _ mutation: WatchConversationMutation,
        echoedConversations: [WatchConversation],
        titleEchoIsCurrent: (WatchConversation) -> Bool = { _ in true }
    ) -> WatchLegacyEchoReconciliation {
        let requiredComponents = requiredComponents(for: mutation)
        let unsupportedFields = unsupportedFields(for: mutation)
        guard let echo = echoedConversations.first(where: {
            $0.id == mutation.conversationID
        }) else {
            return WatchLegacyEchoReconciliation(
                matchedComponents: [],
                unsupportedFields: unsupportedFields,
                canAcknowledgeMutation: false
            )
        }

        var matchedComponents: [WatchLegacyEchoComponent] = []
        if mutation.fields.contains(.create),
           configurationMatches(mutation.conversation, echo)
        {
            matchedComponents.append(.create(
                revision: mutation.createRevision ?? mutation.revision
            ))
        }
        if mutation.fields.contains(.create) || mutation.fields.contains(.title),
           echo.title == mutation.conversation.title,
           titleEchoIsCurrent(echo)
        {
            matchedComponents.append(.title(
                revision: mutation.titleRevision ?? mutation.createRevision ?? mutation.revision
            ))
        }
        if mutation.fields.contains(.create), configurationMatches(mutation.conversation, echo) {
            matchedComponents.append(.configuration(
                revision: mutation.configurationRevision ?? mutation.createRevision ?? mutation.revision
            ))
        }
        if mutation.fields.contains(.messages) {
            let echoedMessages = Dictionary(
                echo.messages.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            for message in mutation.messageChanges where echoedMessages[message.id] == message {
                matchedComponents.append(.message(
                    id: message.id,
                    revision: mutation.messageChangeRevisions[message.id] ?? mutation.revision
                ))
            }
        }

        return WatchLegacyEchoReconciliation(
            matchedComponents: matchedComponents,
            unsupportedFields: unsupportedFields,
            canAcknowledgeMutation: unsupportedFields.isEmpty
                && !requiredComponents.isEmpty
                && matchedComponents == requiredComponents
        )
    }

    static func canAcknowledge(
        _ mutation: WatchConversationMutation,
        currentMatches: [WatchLegacyEchoComponent],
        durableCoverage: WatchMutationDeliveryCoverage?
    ) -> Bool {
        let requiredComponents = requiredComponents(for: mutation)
        guard unsupportedFields(for: mutation).isEmpty,
              !requiredComponents.isEmpty
        else {
            return false
        }

        let currentMatches = Set(currentMatches)
        guard !currentMatches.isEmpty else { return false }
        return requiredComponents.allSatisfy { component in
            switch component {
            case .create:
                currentMatches.contains(component)
                    || isCovered(component, by: durableCoverage)
            case .title, .configuration, .message:
                isCovered(component, by: durableCoverage)
            }
        }
    }

    private static func requiredComponents(
        for mutation: WatchConversationMutation
    ) -> [WatchLegacyEchoComponent] {
        var components: [WatchLegacyEchoComponent] = []
        if mutation.fields.contains(.create) {
            components.append(.create(revision: mutation.createRevision ?? mutation.revision))
        }
        if mutation.fields.contains(.create) || mutation.fields.contains(.title) {
            components.append(.title(
                revision: mutation.titleRevision ?? mutation.createRevision ?? mutation.revision
            ))
        }
        if mutation.fields.contains(.create) {
            components.append(.configuration(
                revision: mutation.configurationRevision ?? mutation.createRevision ?? mutation.revision
            ))
        }
        if mutation.fields.contains(.messages) {
            components.append(contentsOf: mutation.messageChanges.map { message in
                .message(
                    id: message.id,
                    revision: mutation.messageChangeRevisions[message.id] ?? mutation.revision
                )
            })
        }
        return components
    }

    private static func unsupportedFields(
        for mutation: WatchConversationMutation
    ) -> WatchConversationMutationFields {
        var fields: WatchConversationMutationFields = []
        if mutation.fields.contains(.delete) {
            fields.insert(.delete)
        }
        if mutation.fields.contains(.configuration), !mutation.fields.contains(.create) {
            fields.insert(.configuration)
        }
        return fields
    }

    private static func isCovered(
        _ component: WatchLegacyEchoComponent,
        by coverage: WatchMutationDeliveryCoverage?
    ) -> Bool {
        guard let coverage else { return false }
        switch component {
        case let .create(revision):
            return coverage.createRevision ?? 0 >= revision
        case let .title(revision):
            return coverage.titleRevision ?? 0 >= revision
        case let .configuration(revision):
            return coverage.configurationRevision ?? 0 >= revision
        case let .message(id, revision):
            return coverage.messageRevisions[id, default: 0] >= revision
        }
    }

    private static func configurationMatches(
        _ mutation: WatchConversation,
        _ echo: WatchConversation
    ) -> Bool {
        mutation.model == echo.model
            && mutation.temperature == echo.temperature
            && mutation.resolvedSystemPrompt == echo.resolvedSystemPrompt
    }
}

struct WatchMemoryFactsPayload: Equatable, Sendable {
    let data: Data?
    let preservesAcrossFallbacks: Bool
}

struct WatchApplicationContextAttempt {
    let snapshotBytes: Int
    let facts: Data?
    let modelLimit: Int?
    let maximumDefaultSystemPromptCharacters: Int

    static func fallbacks(memoryFacts: WatchMemoryFactsPayload) -> [Self] {
        let fallbackFacts = memoryFacts.preservesAcrossFallbacks ? memoryFacts.data : nil
        return [
            Self(
                snapshotBytes: 32000,
                facts: memoryFacts.data,
                modelLimit: nil,
                maximumDefaultSystemPromptCharacters: 4000
            ),
            Self(
                snapshotBytes: 24000,
                facts: fallbackFacts,
                modelLimit: nil,
                maximumDefaultSystemPromptCharacters: 4000
            ),
            Self(
                snapshotBytes: 12000,
                facts: fallbackFacts,
                modelLimit: 20,
                maximumDefaultSystemPromptCharacters: 2000
            ),
            Self(
                snapshotBytes: 4000,
                facts: fallbackFacts,
                modelLimit: 5,
                maximumDefaultSystemPromptCharacters: 0
            )
        ]
    }
}

enum WatchPayloadStringLimiter {
    static func limit(_ value: String, maximumCharacters: Int) -> String {
        String(value.prefix(max(0, maximumCharacters)))
    }

    static func losslessRepresentation(
        _ value: String,
        maximumCharacters: Int
    ) -> String? {
        if value.isEmpty {
            return ""
        }
        guard maximumCharacters > 0, value.count <= maximumCharacters else {
            return nil
        }
        return value
    }
}

enum WatchContextKeys {
    static let syncSnapshot = "syncSnapshot"
    static let syncPageCycle = "syncPageCycle"
    static let conversations = "conversations"
    static let selectedModel = "selectedModel"
    static let availableModels = "availableModels"
    static let customModels = "customModels"
    static let defaultProvider = "defaultProvider"
    static let modelProviders = "modelProviders"
    static let modelEndpoints = "modelEndpoints"
    static let modelEndpointTypes = "modelEndpointTypes"
    static let modelUsesGitHubOAuth = "modelUsesGitHubOAuth"
    static let modelAPIKeys = "modelAPIKeys"
    static let removedModelDigests = "removedModelDigests"
    static let removedModelProviderDigests = "removedModelProviderDigests"
    static let removedModelEndpointDigests = "removedModelEndpointDigests"
    static let removedModelEndpointTypeDigests = "removedModelEndpointTypeDigests"
    static let removedModelGitHubOAuthDigests = "removedModelGitHubOAuthDigests"
    static let removedModelAPIKeyDigests = "removedModelAPIKeyDigests"
    static let modelMetadataEpoch = "modelMetadataEpoch"
    static let modelMetadataComplete = "modelMetadataComplete"
    static let githubAccessToken = "githubAccessToken"
    static let tavilyAPIKey = "tavilyAPIKey"
    static let tavilyEnabled = "tavilyEnabled"
    static let webFetchEnabled = "webFetchEnabled"
    static let memoryEnabled = "memoryEnabled"
    static let memoryFacts = "memoryFacts"
    static let defaultSystemPrompt = "defaultSystemPrompt"
    static let lastSyncDate = "lastSyncDate"
}

enum WatchMessageKeys {
    static let type = "type"
    static let conversation = "conversation"
    static let mutation = "mutation"
    static let newMessage = "newMessage"
    static let conversationId = "conversationId"
    static let title = "title"
    static let acknowledgedRevision = "acknowledgedRevision"
    static let operationId = "operationId"
    static let peerId = "peerId"
    static let status = "status"
    static let schemaVersion = "schemaVersion"
    static let mutationRevision = "mutationRevision"
    static let configurationRevision = "configurationRevision"
    static let legacyComponentId = "legacyComponentId"
    static let legacyComponentKind = "legacyComponentKind"
    static let messageId = "messageId"
    static let pageCycleRequest = "pageCycleRequest"

    static let typeMutation = "watchConversationMutation"
    static let typeMutationFile = "watchConversationMutationFile"
    static let typeMutationAck = "watchConversationMutationAck"
    static let typeNewMessage = "newMessage"
    static let typeNewConversation = "newConversation"
    static let typeRequestSync = "requestSync"
    static let typeTitleUpdate = "titleUpdate"

    static let legacyComponentCreate = "create"
    static let legacyComponentMessage = "message"
    static let legacyComponentTitle = "title"
}

enum WatchSyncMetadataCodec {
    static func encodeRevisionMap(_ map: [UUID: WatchSyncRevision]) -> Data? {
        let stringMap = WatchSyncRevisionMapCodec.encode(map)
        return try? JSONEncoder().encode(stringMap)
    }

    static func decodeRevisionMap(_ data: Data?) -> [UUID: WatchSyncRevision] {
        guard let data,
              let stringMap = try? JSONDecoder().decode([String: WatchSyncRevision].self, from: data)
        else {
            return [:]
        }
        return WatchSyncRevisionMapCodec.decode(stringMap)
    }

    static func encodePeerRevisionMaps(
        _ maps: [UUID: [UUID: WatchSyncRevision]]
    ) -> Data? {
        var stringMaps: [String: [String: WatchSyncRevision]] = [:]
        for (peerID, revisions) in maps {
            stringMaps[peerID.uuidString] = WatchSyncRevisionMapCodec.encode(revisions)
        }
        return try? JSONEncoder().encode(stringMaps)
    }

    static func decodePeerRevisionMaps(
        _ data: Data?
    ) -> [UUID: [UUID: WatchSyncRevision]] {
        guard let data,
              let stringMaps = try? JSONDecoder().decode(
                  [String: [String: WatchSyncRevision]].self,
                  from: data
              )
        else {
            return [:]
        }
        var decodedMaps: [UUID: [UUID: WatchSyncRevision]] = [:]
        for (peerID, revisions) in stringMaps {
            guard let peerUUID = UUID(uuidString: peerID) else { continue }
            var merged = decodedMaps[peerUUID] ?? [:]
            WatchSyncRevisionMapCodec.merge(
                WatchSyncRevisionMapCodec.decode(revisions),
                into: &merged
            )
            decodedMaps[peerUUID] = merged
        }
        return decodedMaps
    }
}

@MainActor
enum WatchPhonePublicationBarrier {
    static func prepare(
        pendingOperationCount: @escaping @MainActor () -> Int,
        reconcile: @escaping @MainActor () -> Void
    ) -> Bool {
        reconcile()
        return pendingOperationCount() == 0
    }
}

@MainActor
enum WatchLegacyPersistenceBarrier {
    static func perform<Changes: Publisher>(
        pendingOperationCount: @escaping @MainActor () -> Int,
        changes: Changes,
        reconcile: @escaping @MainActor () -> Void,
        apply: @escaping @MainActor () async -> Void
    ) async where Changes.Output == Int, Changes.Failure == Never {
        while true {
            if pendingOperationCount() > 0 {
                for await _ in changes.values where pendingOperationCount() == 0 {
                    break
                }
            }

            reconcile()
            guard pendingOperationCount() > 0 else {
                await apply()
                return
            }
        }
    }
}

struct WatchSyncSourceMetadata: Equatable, Sendable {
    let sourceID: UUID
    let snapshotRevision: WatchSyncRevision

    static func resolve(
        persistedSourceID: String?,
        persistedSnapshotRevision: Any?,
        replacementSourceID: UUID
    ) -> Self {
        guard let persistedSourceID,
              let sourceID = UUID(uuidString: persistedSourceID),
              let snapshotRevision = WatchSyncValueDecoder.revision(persistedSnapshotRevision)
        else {
            return Self(sourceID: replacementSourceID, snapshotRevision: 0)
        }
        return Self(sourceID: sourceID, snapshotRevision: snapshotRevision)
    }
}

enum WatchSyncPersistenceKeys {
    static let sourceID = "com.sertacozercan.ayna.watchSync.sourceID"
    static let snapshotRevision = "com.sertacozercan.ayna.watchSync.snapshotRevision"
    static let acknowledgedWatchRevisions = "com.sertacozercan.ayna.watchSync.acknowledgedWatchRevisions"
    static let acknowledgedWatchRevisionsByPeer =
        "com.sertacozercan.ayna.watchSync.acknowledgedWatchRevisionsByPeer"
    static let activeWatchPeerID = "com.sertacozercan.ayna.watchSync.activeWatchPeerID"
    static let tombstoneRevisions = "com.sertacozercan.ayna.watchSync.tombstoneRevisions"
    static let authoritativeConversationIDs = "com.sertacozercan.ayna.watchSync.authoritativeConversationIDs"
    static let modelRemovalTracker = "com.sertacozercan.ayna.watchSync.modelRemovalTracker"
    static let appliedModelMetadataEpoch = "com.sertacozercan.ayna.watchSync.appliedModelMetadataEpoch"
    static let legacyPlaceholderConversationIDs =
        "com.sertacozercan.ayna.watchSync.legacyPlaceholderConversationIDs"
    static let defaultSystemPrompt = "com.sertacozercan.ayna.watchSync.defaultSystemPrompt"
}

enum WatchApplicationContextSizer {
    static let maximumSafeBytes = 60000

    static func size(_ context: [String: Any]) -> Int {
        guard PropertyListSerialization.propertyList(context, isValidFor: .binary) else { return .max }
        return (try? PropertyListSerialization.data(
            fromPropertyList: context,
            format: .binary,
            options: 0
        ).count) ?? .max
    }

    static func isWithinSafeLimit(_ context: [String: Any]) -> Bool {
        size(context) <= maximumSafeBytes
    }
}

struct WatchPeerCapabilityState: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case reset
        case advertisedMaximumSchema(Int?)
        case receivedMutation
    }

    private(set) var supportsCurrentSchema = false

    mutating func apply(_ event: Event) {
        switch event {
        case .reset:
            supportsCurrentSchema = false
        case let .advertisedMaximumSchema(schemaVersion):
            supportsCurrentSchema = schemaVersion.map {
                $0 >= WatchSyncSnapshot.currentSchemaVersion
            } ?? false
        case .receivedMutation:
            break
        }
    }
}

enum WatchSyncCapability {
    static func advertisedMaximumSchemaVersion(_ value: Any?) -> Int? {
        guard let decoded = WatchSyncValueDecoder.revision(value),
              decoded > 0,
              let schemaVersion = Int(exactly: decoded)
        else {
            return nil
        }
        return schemaVersion
    }

    static func supportsCurrentSchema(_ advertisedMaximumSchema: Any?) -> Bool {
        guard let advertisedMaximumSchemaVersion = advertisedMaximumSchemaVersion(
            advertisedMaximumSchema
        ) else {
            return false
        }
        return advertisedMaximumSchemaVersion >= WatchSyncSnapshot.currentSchemaVersion
    }
}

enum WatchMutationIngressRejection: Equatable, Sendable {
    case malformedSchema
    case unsupportedSchema(Int)
    case emptyFieldMask
    case unknownFieldMask(UInt8)
}

enum WatchMutationIngressValidation: Equatable, Sendable {
    case accepted(schemaVersion: Int)
    case rejected(WatchMutationIngressRejection)
}

enum WatchMutationIngressValidator {
    private static let supportedFieldMask = WatchConversationMutationFields.fullState
        .union(.delete)
        .rawValue

    static func validate(
        schemaVersion value: Any?,
        fields: WatchConversationMutationFields
    ) -> WatchMutationIngressValidation {
        guard let schemaVersion = WatchSyncCapability.advertisedMaximumSchemaVersion(value) else {
            return .rejected(.malformedSchema)
        }
        guard WatchSyncSnapshot.supportsSchemaVersion(schemaVersion) else {
            return .rejected(.unsupportedSchema(schemaVersion))
        }
        guard !fields.isEmpty else {
            return .rejected(.emptyFieldMask)
        }
        let unknownFieldMask = fields.rawValue & ~supportedFieldMask
        guard unknownFieldMask == 0 else {
            return .rejected(.unknownFieldMask(unknownFieldMask))
        }
        return .accepted(schemaVersion: schemaVersion)
    }
}

enum WatchSyncValueDecoder {
    static func revision(_ value: Any?) -> WatchSyncRevision? {
        guard let number = value as? NSNumber else {
            return value as? WatchSyncRevision
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }

        if let decimal = number as? NSDecimalNumber {
            return revision(from: decimal)
        }

        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            let signed = number.int64Value
            return signed >= 0 ? WatchSyncRevision(signed) : nil
        case "C", "S", "I", "L", "Q":
            return number.uint64Value
        case "f", "d":
            return WatchSyncRevision(exactly: number.doubleValue)
        default:
            return nil
        }
    }

    private static func revision(from decimal: NSDecimalNumber) -> WatchSyncRevision? {
        guard decimal != .notANumber else { return nil }
        let zero = NSDecimalNumber(value: 0)
        let maximum = NSDecimalNumber(string: String(WatchSyncRevision.max))
        guard decimal.compare(zero) != .orderedAscending,
              decimal.compare(maximum) != .orderedDescending
        else {
            return nil
        }

        let behavior = NSDecimalNumberHandler(
            roundingMode: .down,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        guard decimal.rounding(accordingToBehavior: behavior).compare(decimal) == .orderedSame else {
            return nil
        }

        let revision = decimal.uint64Value
        guard NSDecimalNumber(value: revision).compare(decimal) == .orderedSame else { return nil }
        return revision
    }
}

#if os(iOS) || os(watchOS)
    import WatchConnectivity
#endif

@MainActor
enum WatchLegacyMutationSender {
    private static let maximumMessageComponentsPerBatch =
        WatchSyncPayloadConfiguration.default.maximumMessagesPerConversation

    static func prepare(
        _ mutation: WatchConversationMutation,
        tracker: WatchLegacyDeliveryTracker
    ) throws -> WatchLegacySendResult {
        guard !mutation.fields.contains(.delete) else {
            return WatchLegacySendResult(userInfos: [], fullyRepresented: false)
        }

        var userInfos: [[String: Any]] = []
        let createWillBeSent = mutation.fields.contains(.create) &&
            tracker.needsCreate(conversationID: mutation.conversationID)
        if createWillBeSent {
            var conversation = mutation.conversation
            conversation.messages = []
            let revision = mutation.createRevision ?? mutation.revision
            let componentID = WatchLegacyComponentIdentity.create(
                conversationID: mutation.conversationID,
                revision: revision
            )
            try userInfos.append([
                WatchMessageKeys.type: WatchMessageKeys.typeNewConversation,
                WatchMessageKeys.conversation: JSONEncoder().encode(conversation),
                WatchMessageKeys.conversationId: mutation.conversationID.uuidString,
                WatchMessageKeys.peerId: mutation.peerID.uuidString,
                WatchMessageKeys.mutationRevision: NSNumber(value: revision),
                WatchMessageKeys.configurationRevision: NSNumber(
                    value: mutation.configurationRevision ?? mutation.createRevision ?? revision
                ),
                WatchMessageKeys.operationId: mutation.operationID.uuidString,
                WatchMessageKeys.legacyComponentId: componentID,
                WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentCreate
            ])
        }

        var awaitingEchoComponentIDs: Set<String> = []
        if mutation.fields.contains(.messages) {
            let selection = tracker.pendingMessageSendSelection(
                from: mutation,
                maximumCount: maximumMessageComponentsPerBatch
            )
            awaitingEchoComponentIDs.formUnion(selection.awaitingEchoComponentIDs)
            for messageChange in selection.messages {
                let revision = mutation.messageChangeRevisions[messageChange.id] ?? mutation.revision
                let componentID = WatchLegacyComponentIdentity.message(
                    messageID: messageChange.id,
                    revision: revision
                )
                try userInfos.append([
                    WatchMessageKeys.type: WatchMessageKeys.typeNewMessage,
                    WatchMessageKeys.newMessage: JSONEncoder().encode(messageChange),
                    WatchMessageKeys.conversationId: mutation.conversationID.uuidString,
                    WatchMessageKeys.peerId: mutation.peerID.uuidString,
                    WatchMessageKeys.mutationRevision: NSNumber(value: revision),
                    WatchMessageKeys.messageId: messageChange.id.uuidString,
                    WatchMessageKeys.operationId: mutation.operationID.uuidString,
                    WatchMessageKeys.legacyComponentId: componentID,
                    WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentMessage
                ])
            }
        }

        let titleRevision = mutation.titleRevision ?? mutation.createRevision ?? mutation.revision
        if mutation.fields.contains(.create) || mutation.fields.contains(.title),
           tracker.needsTitle(
               conversationID: mutation.conversationID,
               title: mutation.conversation.title,
               revision: titleRevision
           )
        {
            let componentID = WatchLegacyComponentIdentity.title(
                conversationID: mutation.conversationID,
                revision: titleRevision
            )
            userInfos.append([
                WatchMessageKeys.type: WatchMessageKeys.typeTitleUpdate,
                WatchMessageKeys.conversationId: mutation.conversationID.uuidString,
                WatchMessageKeys.title: mutation.conversation.title,
                WatchMessageKeys.peerId: mutation.peerID.uuidString,
                WatchMessageKeys.mutationRevision: NSNumber(value: titleRevision),
                WatchMessageKeys.operationId: mutation.operationID.uuidString,
                WatchMessageKeys.legacyComponentId: componentID,
                WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentTitle
            ])
        }

        let userInfoComponentIDs = userInfos.compactMap {
            $0[WatchMessageKeys.legacyComponentId] as? String
        }
        let userInfoEchoState = tracker.advanceAwaitingEcho(userInfoComponentIDs)
        awaitingEchoComponentIDs.formUnion(userInfoEchoState.deferred)
        userInfos.removeAll { userInfo in
            guard let componentID = userInfo[WatchMessageKeys.legacyComponentId] as? String else {
                return false
            }
            return awaitingEchoComponentIDs.contains(componentID)
        }
        let fullyRepresented = tracker.configurationIsRepresented(
            by: mutation,
            createWillBeSent: createWillBeSent
        )
        return WatchLegacySendResult(
            userInfos: userInfos,
            awaitingEchoComponentIDs: awaitingEchoComponentIDs,
            fullyRepresented: fullyRepresented
        )
    }
}

@MainActor
final class WatchRecentAcknowledgementTracker {
    private let limit: Int
    private(set) var ids: [UUID] = []

    init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    func record(_ id: UUID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > limit {
            ids.removeLast(ids.count - limit)
        }
    }
}

@MainActor
enum WatchConversationSyncObserver {
    static func observe(
        conversationManager: ConversationManager,
        onSync: @escaping @MainActor ([Conversation]) -> Void
    ) -> Set<AnyCancellable> {
        var cancellables = Set<AnyCancellable>()

        conversationManager.$conversations
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak conversationManager] _ in
                guard let conversationManager else { return }
                onSync(conversationManager.durableConversationsForSync())
            }
            .store(in: &cancellables)

        conversationManager.$durableConversationRevision
            .removeDuplicates()
            .dropFirst()
            .sink { [weak conversationManager] _ in
                guard let conversationManager else { return }
                onSync(conversationManager.durableConversationsForSync())
            }
            .store(in: &cancellables)

        conversationManager.$pendingDestructivePersistenceOperations
            .removeDuplicates()
            .filter { $0 == 0 }
            .sink { [weak conversationManager] _ in
                Task { @MainActor in
                    guard let conversationManager else { return }
                    onSync(conversationManager.durableConversationsForSync())
                }
            }
            .store(in: &cancellables)

        conversationManager.$isConversationStateAuthoritative
            .removeDuplicates()
            .filter(\.self)
            .sink { [weak conversationManager] _ in
                Task { @MainActor in
                    guard let conversationManager else { return }
                    onSync(conversationManager.durableConversationsForSync())
                }
            }
            .store(in: &cancellables)

        AIService.shared.objectWillChange
            .merge(with: TavilyService.shared.objectWillChange)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak conversationManager] _ in
                guard let conversationManager else { return }
                onSync(conversationManager.durableConversationsForSync())
            }
            .store(in: &cancellables)

        GitHubOAuthService.shared.$isAuthenticated
            .map { _ in () }
            .merge(with: GitHubOAuthService.shared.$tokenExpiresAt.map { _ in () })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak conversationManager] _ in
                guard let conversationManager else { return }
                onSync(conversationManager.durableConversationsForSync())
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .globalSystemPromptDidChange
        )
        .merge(with: NotificationCenter.default.publisher(for: .watchSyncContextDidChange))
        .debounce(for: .seconds(1), scheduler: RunLoop.main)
        .sink { [weak conversationManager] _ in
            guard let conversationManager else { return }
            onSync(conversationManager.durableConversationsForSync())
        }
        .store(in: &cancellables)

        return cancellables
    }
}

struct WatchModelSyncPublication: Equatable, Sendable {
    let availableModels: [String]
    let metadataModels: [String]

    var metadataModelIDs: Set<String> {
        Set(metadataModels)
    }

    func metadataValues<Value>(from values: [String: Value]) -> [String: Value] {
        let includedModels = metadataModelIDs
        return values.filter { includedModels.contains($0.key) }
    }
}

enum WatchModelSyncSelection {
    static func publication(
        selectedModel: String,
        availableModels: [String],
        authoritativeState: PhoneWatchSyncState,
        snapshot: WatchSyncSnapshot,
        limit: Int?
    ) -> WatchModelSyncPublication {
        makePublication(
            availableModels: selectableModels(
                selectedModel: selectedModel,
                availableModels: availableModels,
                limit: limit
            ),
            metadataModels: models(
                selectedModel: selectedModel,
                availableModels: availableModels,
                authoritativeState: authoritativeState,
                snapshot: snapshot,
                limit: limit
            )
        )
    }

    static func models(
        selectedModel: String,
        availableModels: [String],
        authoritativeState: PhoneWatchSyncState,
        snapshot: WatchSyncSnapshot,
        limit: Int?
    ) -> [String] {
        var authoritativeModelsByID: [UUID: String] = [:]
        for conversation in authoritativeState.conversations {
            authoritativeModelsByID[conversation.id] = conversation.model
        }

        var representedRecords = snapshot.conversations.map { ($0.id, $0.model) }
        representedRecords.append(contentsOf: snapshot.conversationConfigurations.map {
            ($0.id, $0.model)
        })
        var seenConversationIDs: Set<UUID> = []
        let referencedModels = representedRecords.compactMap { record -> String? in
            let (conversationID, boundedModel) = record
            guard seenConversationIDs.insert(conversationID).inserted else { return nil }
            return authoritativeModelsByID[conversationID] ?? boundedModel
        }

        return models(
            selectedModel: selectedModel,
            availableModels: availableModels,
            referencedModels: referencedModels,
            limit: limit
        )
    }

    static func selectableModels(
        selectedModel: String,
        availableModels: [String],
        limit: Int?
    ) -> [String] {
        let configured = Set(availableModels.filter { !$0.isEmpty })
        return models(
            selectedModel: configured.contains(selectedModel) ? selectedModel : "",
            availableModels: availableModels,
            referencedModels: [],
            limit: limit
        )
    }

    static func publication(
        selectedModel: String,
        availableModels: [String],
        referencedModels: [String],
        limit: Int?
    ) -> WatchModelSyncPublication {
        makePublication(
            availableModels: selectableModels(
                selectedModel: selectedModel,
                availableModels: availableModels,
                limit: limit
            ),
            metadataModels: models(
                selectedModel: selectedModel,
                availableModels: availableModels,
                referencedModels: referencedModels,
                limit: limit
            )
        )
    }

    private static func makePublication(
        availableModels: [String],
        metadataModels: [String]
    ) -> WatchModelSyncPublication {
        var metadataModels = metadataModels
        var metadataModelIDs = Set(metadataModels)
        metadataModels.append(contentsOf: availableModels.filter {
            metadataModelIDs.insert($0).inserted
        })
        return WatchModelSyncPublication(
            availableModels: availableModels,
            metadataModels: metadataModels
        )
    }

    static func models(
        selectedModel: String,
        availableModels: [String],
        referencedModels: [String],
        limit: Int?
    ) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for model in [selectedModel] + referencedModels + availableModels
            where !model.isEmpty && seen.insert(model).inserted
        {
            result.append(model)
        }
        guard let limit else { return result }
        let requiredCount = Set(([selectedModel] + referencedModels).filter { !$0.isEmpty }).count
        return Array(result.prefix(max(limit, requiredCount)))
    }
}

enum WatchDefaultSystemPromptPersistence {
    static func load(from userDefaults: UserDefaults = .standard) -> String? {
        userDefaults.string(forKey: WatchSyncPersistenceKeys.defaultSystemPrompt)
    }

    static func store(
        _ value: String?,
        in userDefaults: UserDefaults = .standard
    ) {
        if let value {
            userDefaults.set(value, forKey: WatchSyncPersistenceKeys.defaultSystemPrompt)
        } else {
            userDefaults.removeObject(forKey: WatchSyncPersistenceKeys.defaultSystemPrompt)
        }
    }
}

enum WatchDefaultSystemPromptReducer {
    static func value(current: String?, incoming: Any?) -> String? {
        guard let incoming = incoming as? String else { return current }
        return incoming.isEmpty ? nil : incoming
    }
}

enum WatchModelIdentity {
    static func digest(_ modelID: String) -> String {
        SHA256.hash(data: Data(modelID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct WatchModelMetadataValueDigests: Codable, Equatable, Sendable {
    var providers: [String: String] = [:]
    var endpoints: [String: String] = [:]
    var endpointTypes: [String: String] = [:]
    var gitHubOAuth: [String: String] = [:]
    var apiKeys: [String: String] = [:]

    static func hashing(
        providers: [String: String],
        endpoints: [String: String],
        endpointTypes: [String: String],
        gitHubOAuth: [String: Bool],
        apiKeys: [String: String]
    ) -> Self {
        Self(
            providers: digestValues(providers, value: { $0 }),
            endpoints: digestValues(endpoints, value: { $0 }),
            endpointTypes: digestValues(endpointTypes, value: { $0 }),
            gitHubOAuth: digestValues(gitHubOAuth, value: { String($0) }),
            apiKeys: digestValues(apiKeys, value: { $0 })
        )
    }

    private static func digestValues<Value>(
        _ values: [String: Value],
        value: (Value) -> String
    ) -> [String: String] {
        values.reduce(into: [:]) { result, entry in
            result[WatchModelIdentity.digest(entry.key)] = WatchModelIdentity.digest(value(entry.value))
        }
    }
}

struct WatchModelMetadataInventory: Equatable, Sendable {
    var modelIDs: [String]
    var providerModelIDs: [String]
    var endpointModelIDs: [String]
    var endpointTypeModelIDs: [String]
    var gitHubOAuthModelIDs: [String]
    var apiKeyModelIDs: [String]
    var valueDigests = WatchModelMetadataValueDigests()
}

struct WatchModelRemovalPublication: Equatable, Sendable {
    let removedModelDigests: [String]
    let removedProviderDigests: [String]
    let removedEndpointDigests: [String]
    let removedEndpointTypeDigests: [String]
    let removedGitHubOAuthDigests: [String]
    let removedAPIKeyDigests: [String]

    var isEmpty: Bool {
        removedModelDigests.isEmpty
            && removedProviderDigests.isEmpty
            && removedEndpointDigests.isEmpty
            && removedEndpointTypeDigests.isEmpty
            && removedGitHubOAuthDigests.isEmpty
            && removedAPIKeyDigests.isEmpty
    }
}

struct WatchModelRemovalTracker: Codable, Equatable, Sendable {
    static let maximumRetiredDigestCount = 256

    private struct ChangedValueDigests {
        let providers: Set<String>
        let endpoints: Set<String>
        let endpointTypes: Set<String>
        let gitHubOAuth: Set<String>
        let apiKeys: Set<String>
    }

    private(set) var epoch: UUID
    private(set) var publishedDigests: Set<String>
    private(set) var retiredDigests: Set<String>
    private(set) var publishedProviderDigests: Set<String>
    private(set) var retiredProviderDigests: Set<String>
    private(set) var publishedEndpointDigests: Set<String>
    private(set) var retiredEndpointDigests: Set<String>
    private(set) var publishedEndpointTypeDigests: Set<String>
    private(set) var retiredEndpointTypeDigests: Set<String>
    private(set) var publishedGitHubOAuthDigests: Set<String>
    private(set) var retiredGitHubOAuthDigests: Set<String>
    private(set) var publishedAPIKeyDigests: Set<String>
    private(set) var retiredAPIKeyDigests: Set<String>
    private(set) var publishedValueDigests: WatchModelMetadataValueDigests?

    init(epoch: UUID = UUID()) {
        self.epoch = epoch
        publishedDigests = []
        retiredDigests = []
        publishedProviderDigests = []
        retiredProviderDigests = []
        publishedEndpointDigests = []
        retiredEndpointDigests = []
        publishedEndpointTypeDigests = []
        retiredEndpointTypeDigests = []
        publishedGitHubOAuthDigests = []
        retiredGitHubOAuthDigests = []
        publishedAPIKeyDigests = []
        retiredAPIKeyDigests = []
        publishedValueDigests = WatchModelMetadataValueDigests()
    }

    mutating func publication(
        inventory: WatchModelMetadataInventory
    ) -> WatchModelRemovalPublication {
        let valueChanges = Self.changedValueDigests(
            from: publishedValueDigests,
            to: inventory.valueDigests
        )
        publishedValueDigests = inventory.valueDigests

        let models = Self.advance(
            currentModelIDs: inventory.modelIDs,
            published: publishedDigests,
            retired: retiredDigests
        )
        publishedDigests = models.published
        retiredDigests = models.retired

        let providers = Self.advance(
            currentModelIDs: inventory.providerModelIDs,
            published: publishedProviderDigests,
            retired: retiredProviderDigests,
            invalidated: valueChanges.providers,
            retainsCurrentTombstones: true
        )
        publishedProviderDigests = providers.published
        retiredProviderDigests = providers.retired

        let endpoints = Self.advance(
            currentModelIDs: inventory.endpointModelIDs,
            published: publishedEndpointDigests,
            retired: retiredEndpointDigests,
            invalidated: valueChanges.endpoints,
            retainsCurrentTombstones: true
        )
        publishedEndpointDigests = endpoints.published
        retiredEndpointDigests = endpoints.retired

        let endpointTypes = Self.advance(
            currentModelIDs: inventory.endpointTypeModelIDs,
            published: publishedEndpointTypeDigests,
            retired: retiredEndpointTypeDigests,
            invalidated: valueChanges.endpointTypes,
            retainsCurrentTombstones: true
        )
        publishedEndpointTypeDigests = endpointTypes.published
        retiredEndpointTypeDigests = endpointTypes.retired

        let gitHubOAuth = Self.advance(
            currentModelIDs: inventory.gitHubOAuthModelIDs,
            published: publishedGitHubOAuthDigests,
            retired: retiredGitHubOAuthDigests,
            invalidated: valueChanges.gitHubOAuth,
            retainsCurrentTombstones: true
        )
        publishedGitHubOAuthDigests = gitHubOAuth.published
        retiredGitHubOAuthDigests = gitHubOAuth.retired

        let apiKeys = Self.advance(
            currentModelIDs: inventory.apiKeyModelIDs,
            published: publishedAPIKeyDigests,
            retired: retiredAPIKeyDigests,
            invalidated: valueChanges.apiKeys,
            retainsCurrentTombstones: true
        )
        publishedAPIKeyDigests = apiKeys.published
        retiredAPIKeyDigests = apiKeys.retired

        if retiredDigestCount > Self.maximumRetiredDigestCount {
            rotateEpoch(seeding: inventory)
            return WatchModelRemovalPublication(
                removedModelDigests: [],
                removedProviderDigests: [],
                removedEndpointDigests: [],
                removedEndpointTypeDigests: [],
                removedGitHubOAuthDigests: [],
                removedAPIKeyDigests: []
            )
        }

        return WatchModelRemovalPublication(
            removedModelDigests: models.retired.sorted(),
            removedProviderDigests: providers.retired.sorted(),
            removedEndpointDigests: endpoints.retired.sorted(),
            removedEndpointTypeDigests: endpointTypes.retired.sorted(),
            removedGitHubOAuthDigests: gitHubOAuth.retired.sorted(),
            removedAPIKeyDigests: apiKeys.retired.sorted()
        )
    }

    private var retiredDigestCount: Int {
        retiredDigests.count
            + retiredProviderDigests.count
            + retiredEndpointDigests.count
            + retiredEndpointTypeDigests.count
            + retiredGitHubOAuthDigests.count
            + retiredAPIKeyDigests.count
    }

    private mutating func rotateEpoch(seeding inventory: WatchModelMetadataInventory) {
        epoch = UUID()
        publishedDigests = Self.digests(inventory.modelIDs)
        retiredDigests = []
        publishedProviderDigests = Self.digests(inventory.providerModelIDs)
        retiredProviderDigests = []
        publishedEndpointDigests = Self.digests(inventory.endpointModelIDs)
        retiredEndpointDigests = []
        publishedEndpointTypeDigests = Self.digests(inventory.endpointTypeModelIDs)
        retiredEndpointTypeDigests = []
        publishedGitHubOAuthDigests = Self.digests(inventory.gitHubOAuthModelIDs)
        retiredGitHubOAuthDigests = []
        publishedAPIKeyDigests = Self.digests(inventory.apiKeyModelIDs)
        retiredAPIKeyDigests = []
        publishedValueDigests = inventory.valueDigests
    }

    private static func digests(_ modelIDs: [String]) -> Set<String> {
        Set(modelIDs.filter { !$0.isEmpty }.map(WatchModelIdentity.digest))
    }

    private static func advance(
        currentModelIDs: [String],
        published: Set<String>,
        retired: Set<String>,
        invalidated: Set<String> = [],
        retainsCurrentTombstones: Bool = false
    ) -> (published: Set<String>, retired: Set<String>) {
        let current = digests(currentModelIDs)
        var nextRetired = retired
        nextRetired.formUnion(published.subtracting(current))
        if !retainsCurrentTombstones {
            nextRetired.subtract(current)
        }
        nextRetired.formUnion(invalidated)
        return (current, nextRetired)
    }

    private static func changedValueDigests(
        from previous: WatchModelMetadataValueDigests?,
        to current: WatchModelMetadataValueDigests
    ) -> ChangedValueDigests {
        guard let previous else {
            return ChangedValueDigests(
                providers: [],
                endpoints: [],
                endpointTypes: [],
                gitHubOAuth: [],
                apiKeys: []
            )
        }
        return ChangedValueDigests(
            providers: changedModelDigests(from: previous.providers, to: current.providers),
            endpoints: changedModelDigests(from: previous.endpoints, to: current.endpoints),
            endpointTypes: changedModelDigests(from: previous.endpointTypes, to: current.endpointTypes),
            gitHubOAuth: changedModelDigests(from: previous.gitHubOAuth, to: current.gitHubOAuth),
            apiKeys: changedModelDigests(from: previous.apiKeys, to: current.apiKeys)
        )
    }

    private static func changedModelDigests(
        from previous: [String: String],
        to current: [String: String]
    ) -> Set<String> {
        Set(current.compactMap { modelDigest, valueDigest in
            guard let previousValueDigest = previous[modelDigest],
                  previousValueDigest != valueDigest
            else {
                return nil
            }
            return modelDigest
        })
    }
}

struct WatchModelMetadataState: Equatable, Sendable {
    var selectedModel: String
    var availableModels: [String]
    var customModels: [String]
    var defaultProvider: String
    var modelProviders: [String: String]
    var modelEndpoints: [String: String]
    var modelEndpointTypes: [String: String]
    var modelUsesGitHubOAuth: [String: Bool]
    var modelAPIKeys: [String: String]

    mutating func merge(_ page: WatchModelMetadataPage) {
        applyRemovals(from: page)
        if let selectedModel = page.selectedModel {
            self.selectedModel = selectedModel
        }
        if let availableModels = page.availableModels {
            self.availableModels = mergingUnique(self.availableModels, availableModels)
        }
        if let customModels = page.customModels {
            self.customModels = mergingUnique(self.customModels, customModels)
        }
        if let defaultProvider = page.defaultProvider {
            self.defaultProvider = defaultProvider
        }
        mergeValues(page.modelProviders, into: &modelProviders)
        mergeValues(page.modelEndpoints, into: &modelEndpoints)
        mergeValues(page.modelEndpointTypes, into: &modelEndpointTypes)
        mergeValues(page.modelUsesGitHubOAuth, into: &modelUsesGitHubOAuth)
        mergeValues(page.modelAPIKeys, into: &modelAPIKeys)
    }

    mutating func replace(with page: WatchModelMetadataPage) {
        applyRemovals(from: page)
        if let selectedModel = page.selectedModel {
            self.selectedModel = selectedModel
        }
        availableModels = mergingUnique([], page.availableModels ?? [])
        customModels = mergingUnique([], page.customModels ?? [])
        if let defaultProvider = page.defaultProvider {
            self.defaultProvider = defaultProvider
        }
        modelProviders = page.modelProviders ?? [:]
        modelEndpoints = page.modelEndpoints ?? [:]
        modelEndpointTypes = page.modelEndpointTypes ?? [:]
        modelUsesGitHubOAuth = page.modelUsesGitHubOAuth ?? [:]
        modelAPIKeys = page.modelAPIKeys ?? [:]
    }

    mutating func resetModelSpecificState() {
        selectedModel = ""
        availableModels = []
        customModels = []
        modelProviders = [:]
        modelEndpoints = [:]
        modelEndpointTypes = [:]
        modelUsesGitHubOAuth = [:]
        modelAPIKeys = [:]
    }

    private mutating func applyRemovals(from page: WatchModelMetadataPage) {
        removeModels(withDigests: page.removedModelDigests)
        removeEntries(withDigests: page.removedModelProviderDigests, from: &modelProviders)
        removeEntries(withDigests: page.removedModelEndpointDigests, from: &modelEndpoints)
        removeEntries(withDigests: page.removedModelEndpointTypeDigests, from: &modelEndpointTypes)
        removeEntries(withDigests: page.removedModelGitHubOAuthDigests, from: &modelUsesGitHubOAuth)
        removeEntries(withDigests: page.removedModelAPIKeyDigests, from: &modelAPIKeys)
    }

    private func removeEntries(
        withDigests digests: [String]?,
        from values: inout [String: some Any]
    ) {
        guard let digests, !digests.isEmpty else { return }
        let removed = Set(digests)
        values = values.filter { !removed.contains(WatchModelIdentity.digest($0.key)) }
    }

    private mutating func removeModels(withDigests digests: [String]?) {
        guard let digests, !digests.isEmpty else { return }
        let removed = Set(digests)
        let isRetained: (String) -> Bool = { !removed.contains(WatchModelIdentity.digest($0)) }
        if !isRetained(selectedModel) {
            selectedModel = ""
        }
        availableModels.removeAll { !isRetained($0) }
        customModels.removeAll { !isRetained($0) }
        modelProviders = modelProviders.filter { isRetained($0.key) }
        modelEndpoints = modelEndpoints.filter { isRetained($0.key) }
        modelEndpointTypes = modelEndpointTypes.filter { isRetained($0.key) }
        modelUsesGitHubOAuth = modelUsesGitHubOAuth.filter { isRetained($0.key) }
        modelAPIKeys = modelAPIKeys.filter { isRetained($0.key) }
    }
}

struct WatchModelMetadataPage: Equatable, Sendable {
    var selectedModel: String?
    var availableModels: [String]?
    var customModels: [String]?
    var defaultProvider: String?
    var modelProviders: [String: String]?
    var modelEndpoints: [String: String]?
    var modelEndpointTypes: [String: String]?
    var modelUsesGitHubOAuth: [String: Bool]?
    var modelAPIKeys: [String: String]?
    var removedModelDigests: [String]?
    var removedModelProviderDigests: [String]?
    var removedModelEndpointDigests: [String]?
    var removedModelEndpointTypeDigests: [String]?
    var removedModelGitHubOAuthDigests: [String]?
    var removedModelAPIKeyDigests: [String]?

    init(
        selectedModel: String? = nil,
        availableModels: [String]? = nil,
        customModels: [String]? = nil,
        defaultProvider: String? = nil,
        modelProviders: [String: String]? = nil,
        modelEndpoints: [String: String]? = nil,
        modelEndpointTypes: [String: String]? = nil,
        modelUsesGitHubOAuth: [String: Bool]? = nil,
        modelAPIKeys: [String: String]? = nil,
        removedModelDigests: [String]? = nil,
        removedModelProviderDigests: [String]? = nil,
        removedModelEndpointDigests: [String]? = nil,
        removedModelEndpointTypeDigests: [String]? = nil,
        removedModelGitHubOAuthDigests: [String]? = nil,
        removedModelAPIKeyDigests: [String]? = nil
    ) {
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.customModels = customModels
        self.defaultProvider = defaultProvider
        self.modelProviders = modelProviders
        self.modelEndpoints = modelEndpoints
        self.modelEndpointTypes = modelEndpointTypes
        self.modelUsesGitHubOAuth = modelUsesGitHubOAuth
        self.modelAPIKeys = modelAPIKeys
        self.removedModelDigests = removedModelDigests
        self.removedModelProviderDigests = removedModelProviderDigests
        self.removedModelEndpointDigests = removedModelEndpointDigests
        self.removedModelEndpointTypeDigests = removedModelEndpointTypeDigests
        self.removedModelGitHubOAuthDigests = removedModelGitHubOAuthDigests
        self.removedModelAPIKeyDigests = removedModelAPIKeyDigests
    }

    init(context: [String: Any]) {
        self.init(
            selectedModel: context[WatchContextKeys.selectedModel] as? String,
            availableModels: context[WatchContextKeys.availableModels] as? [String],
            customModels: context[WatchContextKeys.customModels] as? [String],
            defaultProvider: context[WatchContextKeys.defaultProvider] as? String,
            modelProviders: context[WatchContextKeys.modelProviders] as? [String: String],
            modelEndpoints: context[WatchContextKeys.modelEndpoints] as? [String: String],
            modelEndpointTypes: context[WatchContextKeys.modelEndpointTypes] as? [String: String],
            modelUsesGitHubOAuth: context[WatchContextKeys.modelUsesGitHubOAuth] as? [String: Bool],
            modelAPIKeys: context[WatchContextKeys.modelAPIKeys] as? [String: String],
            removedModelDigests: context[WatchContextKeys.removedModelDigests] as? [String],
            removedModelProviderDigests: context[WatchContextKeys.removedModelProviderDigests] as? [String],
            removedModelEndpointDigests: context[WatchContextKeys.removedModelEndpointDigests] as? [String],
            removedModelEndpointTypeDigests: context[WatchContextKeys.removedModelEndpointTypeDigests] as? [String],
            removedModelGitHubOAuthDigests: context[WatchContextKeys.removedModelGitHubOAuthDigests] as? [String],
            removedModelAPIKeyDigests: context[WatchContextKeys.removedModelAPIKeyDigests] as? [String]
        )
    }

    mutating func merge(_ page: WatchModelMetadataPage) {
        if let selectedModel = page.selectedModel {
            self.selectedModel = selectedModel
        }
        if let availableModels = page.availableModels {
            self.availableModels = mergingUnique(self.availableModels ?? [], availableModels)
        }
        if let customModels = page.customModels {
            self.customModels = mergingUnique(self.customModels ?? [], customModels)
        }
        if let defaultProvider = page.defaultProvider {
            self.defaultProvider = defaultProvider
        }
        mergeOptionalValues(page.modelProviders, into: &modelProviders)
        mergeOptionalValues(page.modelEndpoints, into: &modelEndpoints)
        mergeOptionalValues(page.modelEndpointTypes, into: &modelEndpointTypes)
        mergeOptionalValues(page.modelUsesGitHubOAuth, into: &modelUsesGitHubOAuth)
        mergeOptionalValues(page.modelAPIKeys, into: &modelAPIKeys)
        if let removedModelDigests = page.removedModelDigests {
            self.removedModelDigests = mergingUnique(self.removedModelDigests ?? [], removedModelDigests)
        }
        if let removed = page.removedModelProviderDigests {
            removedModelProviderDigests = mergingUnique(removedModelProviderDigests ?? [], removed)
        }
        if let removed = page.removedModelEndpointDigests {
            removedModelEndpointDigests = mergingUnique(removedModelEndpointDigests ?? [], removed)
        }
        if let removed = page.removedModelEndpointTypeDigests {
            removedModelEndpointTypeDigests = mergingUnique(removedModelEndpointTypeDigests ?? [], removed)
        }
        if let removed = page.removedModelGitHubOAuthDigests {
            removedModelGitHubOAuthDigests = mergingUnique(removedModelGitHubOAuthDigests ?? [], removed)
        }
        if let removed = page.removedModelAPIKeyDigests {
            removedModelAPIKeyDigests = mergingUnique(removedModelAPIKeyDigests ?? [], removed)
        }
    }
}

enum WatchModelMetadataCompleteness {
    static func isCompletePublication(
        snapshot: WatchSyncSnapshot,
        modelLimit: Int?
    ) -> Bool {
        modelLimit == nil
            && snapshot.authoritativeConversationIDsAreComplete
            && snapshot.conversationConfigurationsAreComplete
    }

    static func isExplicitlyComplete(in context: [String: Any]) -> Bool {
        context[WatchContextKeys.modelMetadataComplete] as? Bool == true
    }

    static func legacyContextIsComplete(in context: [String: Any]) -> Bool {
        (context[WatchContextKeys.modelMetadataComplete] as? Bool) ?? true
    }
}

struct WatchModelMetadataCycleAccumulator: Sendable {
    private var activeCycleID: UUID?
    private var accumulated = WatchModelMetadataPage()

    mutating func apply(
        _ page: WatchModelMetadataPage,
        cycleID: UUID,
        completesCycle: Bool,
        isAuthoritative: Bool = true,
        to state: inout WatchModelMetadataState
    ) {
        if activeCycleID != cycleID {
            activeCycleID = cycleID
            accumulated = WatchModelMetadataPage()
        }
        accumulated.merge(page)

        if completesCycle {
            if isAuthoritative {
                state.replace(with: accumulated)
            } else {
                state.merge(accumulated)
            }
            reset()
        } else {
            state.merge(page)
        }
    }

    mutating func applyStandaloneContext(
        _ page: WatchModelMetadataPage,
        isComplete: Bool,
        to state: inout WatchModelMetadataState
    ) {
        reset()
        if isComplete {
            state.replace(with: page)
        } else {
            state.merge(page)
        }
    }

    mutating func applyCompleteContext(
        _ page: WatchModelMetadataPage,
        to state: inout WatchModelMetadataState
    ) {
        applyStandaloneContext(page, isComplete: true, to: &state)
    }

    mutating func reset() {
        activeCycleID = nil
        accumulated = WatchModelMetadataPage()
    }
}

enum WatchModelMetadataContextReducer {
    static func apply(
        _ page: WatchModelMetadataPage,
        mode: WatchContextApplicationMode,
        incomingEpoch: UUID?,
        appliedEpoch: UUID?,
        pendingEpoch: inout UUID?,
        accumulator: inout WatchModelMetadataCycleAccumulator,
        to state: inout WatchModelMetadataState
    ) -> UUID? {
        guard mode != .ignore else { return nil }

        let hasUnappliedEpoch = incomingEpoch.map { $0 != appliedEpoch } ?? false
        if hasUnappliedEpoch, pendingEpoch != incomingEpoch {
            pendingEpoch = incomingEpoch
            accumulator.reset()
        } else if !hasUnappliedEpoch {
            pendingEpoch = nil
        }

        switch mode {
        case .ignore:
            return nil
        case .provisional:
            accumulator.applyStandaloneContext(
                page,
                isComplete: false,
                to: &state
            )
        case .complete:
            accumulator.applyStandaloneContext(
                page,
                isComplete: true,
                to: &state
            )
        case let .page(cycleID, completesCycle, metadataComplete):
            accumulator.apply(
                page,
                cycleID: cycleID,
                completesCycle: completesCycle,
                isAuthoritative: metadataComplete,
                to: &state
            )
        }

        guard hasUnappliedEpoch,
              mode.treatsOmittedCredentialsAsRemoved,
              let incomingEpoch
        else {
            return nil
        }
        pendingEpoch = nil
        return incomingEpoch
    }
}

private func mergingUnique(_ existing: [String], _ incoming: [String]) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    for value in existing + incoming where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}

private func mergeValues<Value>(
    _ incoming: [String: Value]?,
    into existing: inout [String: Value]
) {
    guard let incoming else { return }
    for (key, value) in incoming {
        existing[key] = value
    }
}

private func mergeOptionalValues<Value>(
    _ incoming: [String: Value]?,
    into existing: inout [String: Value]?
) {
    guard let incoming else { return }
    var merged = existing ?? [:]
    mergeValues(incoming, into: &merged)
    existing = merged
}

enum WatchSyncSnapshotApplyOutcome: Equatable, Sendable {
    case applied
    case alreadyDurable
    case persistenceFailed
    case ignoredStale
    case ignoredUnsupportedSchema

    var isDurable: Bool {
        self == .applied || self == .alreadyDurable
    }
}

enum WatchContextApplicationMode: Equatable, Sendable {
    case ignore
    case provisional
    case complete
    case page(cycleID: UUID, completesCycle: Bool, metadataComplete: Bool)

    var appliesSnapshotSettings: Bool {
        self != .ignore
    }

    var treatsOmittedCredentialsAsRemoved: Bool {
        switch self {
        case .complete:
            true
        case let .page(_, completesCycle, metadataComplete):
            completesCycle && metadataComplete
        case .ignore, .provisional:
            false
        }
    }

    static func standalone(
        after outcome: WatchSyncSnapshotApplyOutcome,
        metadataIsComplete: Bool
    ) -> Self {
        guard outcome.isDurable else { return .ignore }
        return metadataIsComplete ? .complete : .provisional
    }

    static func legacy(metadataIsComplete: Bool) -> Self {
        metadataIsComplete ? .complete : .provisional
    }
}

struct WatchPageCycleUpdate: Equatable, Sendable {
    let pendingRequest: WatchSyncPageCycleRequest?
    let acceptedPage: Bool
    let completedCycle: Bool
    let retainedForRetry: Bool
    let requiresFreshCycle: Bool
}

struct WatchPageCycleCoordinator: Sendable {
    private var sourceID: UUID?
    private var lastSnapshotRevision: WatchSyncRevision = 0
    private var activeCycleID: UUID?
    private var expectedCursor: WatchSyncPageCycleCursor?
    private var acceptedCursors: [Int: WatchSyncPageCycleCursor] = [:]
    private var freshCycleRequestedForCycleID: UUID?

    var pendingRequest: WatchSyncPageCycleRequest? {
        guard let activeCycleID, let expectedCursor else { return nil }
        return WatchSyncPageCycleRequest(cycleID: activeCycleID, cursor: expectedCursor)
    }

    mutating func reset() {
        sourceID = nil
        lastSnapshotRevision = 0
        activeCycleID = nil
        expectedCursor = nil
        acceptedCursors = [:]
        freshCycleRequestedForCycleID = nil
    }

    mutating func receive(_ metadata: WatchSyncPageCycleMetadata) -> WatchSyncPageCycleRequest? {
        receive(metadata, after: .applied).pendingRequest
    }

    mutating func receive(
        _ metadata: WatchSyncPageCycleMetadata,
        after applyOutcome: WatchSyncSnapshotApplyOutcome
    ) -> WatchPageCycleUpdate {
        switch applyOutcome {
        case .applied, .alreadyDurable:
            receiveDurable(metadata)
        case .persistenceFailed:
            retainFailedPage(metadata)
        case .ignoredStale, .ignoredUnsupportedSchema:
            unchangedUpdate()
        }
    }

    private mutating func receiveDurable(
        _ metadata: WatchSyncPageCycleMetadata
    ) -> WatchPageCycleUpdate {
        guard metadata.isValid else { return unchangedUpdate() }
        let sourceChanged = sourceID.map { $0 != metadata.sourceID } ?? false
        guard sourceChanged || metadata.snapshotRevision > lastSnapshotRevision else {
            return unchangedUpdate()
        }
        sourceID = metadata.sourceID
        lastSnapshotRevision = metadata.snapshotRevision

        if sourceChanged || metadata.cycleID != activeCycleID {
            guard metadata.cursor == .initial else {
                return freshCycleUpdate(for: metadata)
            }
            activeCycleID = metadata.cycleID
            acceptedCursors = [metadata.cursor.pageIndex: metadata.cursor]
            expectedCursor = metadata.nextCursor
            freshCycleRequestedForCycleID = nil
            return acceptedUpdate()
        }

        if metadata.cursor == expectedCursor {
            acceptedCursors[metadata.cursor.pageIndex] = metadata.cursor
            expectedCursor = metadata.nextCursor
            return acceptedUpdate()
        }

        return unchangedUpdate()
    }

    private mutating func retainFailedPage(
        _ metadata: WatchSyncPageCycleMetadata
    ) -> WatchPageCycleUpdate {
        guard metadata.isValid else { return unchangedUpdate() }
        let sourceChanged = sourceID.map { $0 != metadata.sourceID } ?? false
        if sourceChanged || metadata.cycleID != activeCycleID {
            guard metadata.cursor == .initial else {
                return freshCycleUpdate(for: metadata)
            }
            activeCycleID = metadata.cycleID
            expectedCursor = metadata.cursor
            acceptedCursors = [:]
            freshCycleRequestedForCycleID = nil
        }
        return WatchPageCycleUpdate(
            pendingRequest: pendingRequest,
            acceptedPage: false,
            completedCycle: false,
            retainedForRetry: pendingRequest?.cursor == metadata.cursor,
            requiresFreshCycle: false
        )
    }

    private func acceptedUpdate() -> WatchPageCycleUpdate {
        WatchPageCycleUpdate(
            pendingRequest: pendingRequest,
            acceptedPage: true,
            completedCycle: expectedCursor == nil,
            retainedForRetry: false,
            requiresFreshCycle: false
        )
    }

    private mutating func freshCycleUpdate(
        for metadata: WatchSyncPageCycleMetadata
    ) -> WatchPageCycleUpdate {
        let requiresFreshCycle = freshCycleRequestedForCycleID != metadata.cycleID
        freshCycleRequestedForCycleID = metadata.cycleID
        return WatchPageCycleUpdate(
            pendingRequest: nil,
            acceptedPage: false,
            completedCycle: false,
            retainedForRetry: false,
            requiresFreshCycle: requiresFreshCycle
        )
    }

    private func unchangedUpdate() -> WatchPageCycleUpdate {
        WatchPageCycleUpdate(
            pendingRequest: pendingRequest,
            acceptedPage: false,
            completedCycle: false,
            retainedForRetry: false,
            requiresFreshCycle: false
        )
    }
}

struct WatchPhonePageCycleCoordinator: Sendable {
    private var activeCycleID: UUID?
    private var nextExpectedCursor: WatchSyncPageCycleCursor?
    private var publishedCursors: [Int: WatchSyncPageCycleCursor] = [:]
    private var authoritativePublishedCursors: Set<WatchSyncPageCycleCursor> = []
    private var modelMetadataPagesAreLossless = true

    mutating func beginCycle(id: UUID = UUID()) -> WatchSyncPageCycleCursor {
        activeCycleID = id
        nextExpectedCursor = .initial
        publishedCursors = [:]
        authoritativePublishedCursors = []
        modelMetadataPagesAreLossless = true
        return .initial
    }

    mutating func reset() {
        activeCycleID = nil
        nextExpectedCursor = nil
        publishedCursors = [:]
        authoritativePublishedCursors = []
        modelMetadataPagesAreLossless = true
    }

    func metadataForPublication(
        _ metadata: WatchSyncPageCycleMetadata,
        modelMetadataPageIsLossless: Bool
    ) -> WatchSyncPageCycleMetadata {
        let isSequentialPage = metadata.isValid
            && metadata.cycleID == activeCycleID
            && metadata.cursor == nextExpectedCursor
        let manifestIsCovered = metadata.manifest.offset + metadata.manifest.itemCount
            == metadata.manifest.totalCount
        let configurationsAreCovered = metadata.configurations.offset
            + metadata.configurations.itemCount == metadata.configurations.totalCount
        let isAuthoritativeRetry = metadata.isValid
            && metadata.cycleID == activeCycleID
            && authoritativePublishedCursors.contains(metadata.cursor)
        let cycleIsAuthoritative = (isSequentialPage || isAuthoritativeRetry)
            && metadata.nextCursor == nil
            && manifestIsCovered
            && configurationsAreCovered
            && modelMetadataPagesAreLossless
            && modelMetadataPageIsLossless
        return WatchSyncPageCycleMetadata(
            cycleID: metadata.cycleID,
            sourceID: metadata.sourceID,
            snapshotRevision: metadata.snapshotRevision,
            cursor: metadata.cursor,
            manifest: metadata.manifest,
            configurations: metadata.configurations,
            tombstones: metadata.tombstones,
            modelMetadataCycleIsAuthoritative: cycleIsAuthoritative
        )
    }

    mutating func recordPublished(
        _ metadata: WatchSyncPageCycleMetadata,
        modelMetadataPageIsLossless: Bool = true
    ) {
        guard metadata.isValid, metadata.cycleID == activeCycleID else { return }
        publishedCursors[metadata.cursor.pageIndex] = metadata.cursor
        if metadata.modelMetadataCycleIsAuthoritative,
           modelMetadataPageIsLossless
        {
            authoritativePublishedCursors.insert(metadata.cursor)
        }
        guard metadata.cursor == nextExpectedCursor else { return }
        modelMetadataPagesAreLossless = modelMetadataPagesAreLossless
            && modelMetadataPageIsLossless
        nextExpectedCursor = metadata.nextCursor
    }

    func publication(for request: WatchSyncPageCycleRequest) -> WatchSyncPageCycleCursor? {
        publicationRequest(for: request)?.cursor
    }

    func publicationRequest(
        for request: WatchSyncPageCycleRequest
    ) -> WatchSyncPageCycleRequest? {
        guard let activeCycleID else { return nil }
        let cursor: WatchSyncPageCycleCursor? = if request.cycleID != activeCycleID {
            publishedCursors[WatchSyncPageCycleCursor.initial.pageIndex]
                ?? nextExpectedCursor
                ?? .initial
        } else if let published = publishedCursors[request.cursor.pageIndex],
                  published == request.cursor
        {
            request.cursor
        } else if request.cursor == nextExpectedCursor {
            request.cursor
        } else {
            nextExpectedCursor
        }
        guard let cursor else { return nil }
        return WatchSyncPageCycleRequest(cycleID: activeCycleID, cursor: cursor)
    }
}

enum WatchPeerSyncMode: Sendable {
    case unknown
    case revisioned
    case legacy
}

final class WatchSessionCallbackIdentityFence: @unchecked Sendable {
    private struct Identity: Equatable {
        let sessionID: ObjectIdentifier
        let activation: WatchSessionActivationToken
    }

    private let lock = NSLock()
    private var identity: Identity?

    func activate(
        sessionID: ObjectIdentifier,
        activation: WatchSessionActivationToken
    ) {
        lock.lock()
        identity = Identity(sessionID: sessionID, activation: activation)
        lock.unlock()
    }

    func isCurrent(
        sessionID: ObjectIdentifier,
        activation: WatchSessionActivationToken
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identity == Identity(sessionID: sessionID, activation: activation)
    }
}

enum WatchMutationFileTransportError: Error, Equatable, LocalizedError, Sendable {
    case staleSession
    case invalidMetadata
    case unsupportedSchema(Int)
    case unreadableFile
    case nonRegularFile
    case emptyFile
    case exceedsMaximum(actualBytes: Int, maximumBytes: Int)
    case changedDuringRead(expectedBytes: Int, actualBytes: Int)
    case malformedPayload
    case metadataIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .staleSession:
            "The Watch mutation file belongs to a stale session."
        case .invalidMetadata:
            "The Watch mutation file metadata is invalid."
        case let .unsupportedSchema(schemaVersion):
            "The Watch mutation file schema \(schemaVersion) is unsupported."
        case .unreadableFile:
            "The Watch mutation file cannot be read."
        case .nonRegularFile:
            "The Watch mutation file is not a regular file."
        case .emptyFile:
            "The Watch mutation file is empty."
        case let .exceedsMaximum(actualBytes, maximumBytes):
            "The Watch mutation file is \(actualBytes) bytes; the maximum is \(maximumBytes)."
        case let .changedDuringRead(expectedBytes, actualBytes):
            "The Watch mutation file changed from \(expectedBytes) to \(actualBytes) bytes while reading."
        case .malformedPayload:
            "The Watch mutation file payload is malformed."
        case .metadataIdentityMismatch:
            "The Watch mutation file payload does not match its metadata identity."
        }
    }
}

struct WatchMutationFileReception: Equatable, Sendable {
    let mutation: WatchConversationMutation
    let schemaVersion: Int
    let byteCount: Int
}

struct WatchMutationFileCapture: Equatable, Sendable {
    fileprivate let data: Data
    fileprivate let operationID: UUID
    fileprivate let conversationID: UUID
    let schemaVersion: Int

    var byteCount: Int {
        data.count
    }
}

enum WatchMutationFileTransport {
    /// File transfer is reserved for mutations beyond the 48 KB message budget. Four MiB leaves
    /// more than 80x headroom for legitimate coalesced text/tool mutations while bounding the
    /// synchronous delegate work needed before WatchConnectivity invalidates its temporary URL.
    static let maximumBytes = 4 * 1024 * 1024

    private static let readChunkBytes = 64 * 1024

    static func receive(
        fileURL: URL,
        metadata: [String: Any],
        sessionIsCurrent: Bool
    ) throws -> WatchMutationFileReception {
        try decode(capture(
            fileURL: fileURL,
            metadata: metadata,
            sessionIsCurrent: sessionIsCurrent
        ))
    }

    static func capture(
        fileURL: URL,
        metadata: [String: Any],
        sessionIsCurrent: Bool
    ) throws -> WatchMutationFileCapture {
        guard sessionIsCurrent else {
            throw WatchMutationFileTransportError.staleSession
        }
        let metadata = try validatedMetadata(metadata)
        let data = try boundedData(from: fileURL)
        return WatchMutationFileCapture(
            data: data,
            operationID: metadata.operationID,
            conversationID: metadata.conversationID,
            schemaVersion: metadata.schemaVersion
        )
    }

    static func decode(
        _ capture: WatchMutationFileCapture
    ) throws -> WatchMutationFileReception {
        let mutation: WatchConversationMutation
        do {
            mutation = try JSONDecoder().decode(
                WatchConversationMutation.self,
                from: capture.data
            )
        } catch {
            throw WatchMutationFileTransportError.malformedPayload
        }
        guard mutation.operationID == capture.operationID,
              mutation.conversationID == capture.conversationID
        else {
            throw WatchMutationFileTransportError.metadataIdentityMismatch
        }
        return WatchMutationFileReception(
            mutation: mutation,
            schemaVersion: capture.schemaVersion,
            byteCount: capture.byteCount
        )
    }

    static func encodedData(
        for mutation: WatchConversationMutation
    ) throws -> Data {
        let data = try WatchSyncPayloadBuilder.encodeMutation(mutation)
        try validateByteCount(data.count)
        return data
    }

    private struct Metadata {
        let operationID: UUID
        let conversationID: UUID
        let schemaVersion: Int
    }

    private static func validatedMetadata(
        _ metadata: [String: Any]
    ) throws -> Metadata {
        guard metadata[WatchMessageKeys.type] as? String == WatchMessageKeys.typeMutationFile,
              let operationID = (metadata[WatchMessageKeys.operationId] as? String)
              .flatMap(UUID.init(uuidString:)),
              let conversationID = (metadata[WatchMessageKeys.conversationId] as? String)
              .flatMap(UUID.init(uuidString:)),
              let schemaVersion = WatchSyncCapability.advertisedMaximumSchemaVersion(
                  metadata[WatchMessageKeys.schemaVersion]
              )
        else {
            throw WatchMutationFileTransportError.invalidMetadata
        }
        guard WatchSyncSnapshot.supportsSchemaVersion(schemaVersion) else {
            throw WatchMutationFileTransportError.unsupportedSchema(schemaVersion)
        }
        return Metadata(
            operationID: operationID,
            conversationID: conversationID,
            schemaVersion: schemaVersion
        )
    }

    private static func boundedData(from fileURL: URL) throws -> Data {
        let resourceValues: URLResourceValues
        do {
            resourceValues = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ])
        } catch {
            throw WatchMutationFileTransportError.unreadableFile
        }
        guard resourceValues.isRegularFile == true else {
            throw WatchMutationFileTransportError.nonRegularFile
        }
        guard let expectedByteCount = resourceValues.fileSize else {
            throw WatchMutationFileTransportError.unreadableFile
        }
        try validateByteCount(expectedByteCount)

        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw WatchMutationFileTransportError.unreadableFile
        }
        defer { try? fileHandle.close() }

        var data = Data()
        data.reserveCapacity(expectedByteCount)
        do {
            while data.count <= maximumBytes {
                let remainingByteCount = maximumBytes + 1 - data.count
                guard remainingByteCount > 0,
                      let chunk = try fileHandle.read(
                          upToCount: min(readChunkBytes, remainingByteCount)
                      ),
                      !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            throw WatchMutationFileTransportError.unreadableFile
        }
        try validateByteCount(data.count)
        guard data.count == expectedByteCount else {
            throw WatchMutationFileTransportError.changedDuringRead(
                expectedBytes: expectedByteCount,
                actualBytes: data.count
            )
        }
        return data
    }

    private static func validateByteCount(_ byteCount: Int) throws {
        guard byteCount > 0 else {
            throw WatchMutationFileTransportError.emptyFile
        }
        guard byteCount <= maximumBytes else {
            throw WatchMutationFileTransportError.exceedsMaximum(
                actualBytes: byteCount,
                maximumBytes: maximumBytes
            )
        }
    }
}

#if os(watchOS)
    @MainActor
    extension WatchMutationFileTransport {
        static func hasOutstandingTransfer(
            operationID: UUID,
            session: WCSession
        ) -> Bool {
            session.outstandingFileTransfers.contains { transfer in
                (transfer.file.metadata?[WatchMessageKeys.operationId] as? String) == operationID.uuidString
            }
        }

        static func transfer(
            _ mutation: WatchConversationMutation,
            session: WCSession
        ) throws -> URL {
            let data = try encodedData(for: mutation)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ayna-watch-mutation-\(mutation.operationID.uuidString)")
                .appendingPathExtension("json")
            try data.write(to: fileURL, options: .atomic)
            session.transferFile(fileURL, metadata: [
                WatchMessageKeys.type: WatchMessageKeys.typeMutationFile,
                WatchMessageKeys.operationId: mutation.operationID.uuidString,
                WatchMessageKeys.conversationId: mutation.conversationID.uuidString,
                WatchMessageKeys.schemaVersion: NSNumber(value: WatchSyncSnapshot.currentSchemaVersion)
            ])
            return fileURL
        }
    }
#endif

enum WatchMutationMetadataMerger {
    static func merge(
        reduction: PhoneWatchMutationReduction,
        conversationID: UUID,
        acknowledgements: inout [UUID: WatchSyncRevision],
        tombstones: inout [UUID: WatchSyncRevision]
    ) {
        if let revision = reduction.state.acknowledgedWatchRevisions[conversationID] {
            acknowledgements[conversationID] = max(acknowledgements[conversationID] ?? 0, revision)
        }
        if let revision = reduction.state.tombstoneRevisions[conversationID] {
            tombstones[conversationID] = max(tombstones[conversationID] ?? 0, revision)
        }
    }
}
