//
//  WatchConversationStore.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS) || WATCH_STORE_HOST_TESTING

    import Combine
    import Foundation

    /// Durable local conversation state for Apple Watch.
    ///
    /// Committed conversations, Watch-originated mutations, and in-progress draft overlays
    /// are persisted before any mutation is handed to WatchConnectivity. Draft overlays are
    /// deliberately local until `finishDraft(conversationID:)` promotes them to a mutation.
    @MainActor
    // swiftlint:disable:next type_body_length
    final class WatchConversationStore: ObservableObject {
        enum DraftPromotionOutcome: Equatable {
            case promoted(WatchConversation)
            case noDraft
            case discardedEmptyDraft
            case persistenceFailed
        }

        static let shared = WatchConversationStore()

        @Published private(set) var conversations: [WatchConversation] = []
        @Published var selectedConversationId: UUID? {
            didSet {
                guard selectedConversationId != oldValue, let selectedConversationId else { return }
                recordCurrentBodyAccess(for: selectedConversationId)
            }
        }

        private struct PersistedState: Codable {
            var sourceID: UUID?
            var peerID: UUID?
            var lastSnapshotRevision: WatchSyncRevision
            var conversations: [WatchConversation]
            var pendingMutations: [WatchConversationMutation]
            var pendingDrafts: [WatchConversationDraft]
            var legacyDeliveryCoverage: [UUID: WatchMutationDeliveryCoverage]?
            var bodyRecency: [UUID: UInt64]?
            var bodyRecencySequence: UInt64?
            var lastAccessedConversationID: UUID?
        }

        private struct RuntimeState {
            var sourceID: UUID?
            var peerID: UUID
            var lastSnapshotRevision: WatchSyncRevision
            var committedConversations: [WatchConversation]
            var pendingMutations: [WatchConversationMutation]
            var pendingDrafts: [UUID: WatchConversationDraft]
            var legacyDeliveryCoverage: [UUID: WatchMutationDeliveryCoverage]
            var bodyRecency: [UUID: UInt64]
            var bodyRecencySequence: UInt64
            var lastAccessedConversationID: UUID?
        }

        private struct BodyCacheState: Equatable {
            var conversations: [WatchConversation]
            var recency: [UUID: UInt64]
            var recencySequence: UInt64
            var lastAccessedConversationID: UUID?
        }

        private struct PageCycleManifestAccumulator {
            private var sourceID: UUID?
            private var cycleID: UUID?
            private var expectedCursor: WatchSyncPageCycleCursor?
            private var conversationIDs: [UUID] = []
            private var conversationIDSet: Set<UUID> = []

            func snapshotForApplication(
                _ snapshot: WatchSyncSnapshot,
                metadata: WatchSyncPageCycleMetadata
            ) -> WatchSyncSnapshot {
                guard metadata.isValid(for: snapshot), accepts(metadata) else { return snapshot }

                var accumulatedIDs = conversationIDs
                var accumulatedIDSet = conversationIDSet
                if startsNewCycle(metadata) {
                    accumulatedIDs = []
                    accumulatedIDSet = []
                }
                for conversationID in snapshot.authoritativeConversationIDs
                    where accumulatedIDSet.insert(conversationID).inserted
                {
                    accumulatedIDs.append(conversationID)
                }

                guard metadata.nextCursor == nil,
                      accumulatedIDs.count == metadata.manifest.totalCount
                else {
                    return snapshot
                }

                var authoritativeSnapshot = snapshot
                authoritativeSnapshot.authoritativeConversationIDs = accumulatedIDs
                authoritativeSnapshot.authoritativeConversationIDsAreComplete = true
                return authoritativeSnapshot
            }

            mutating func recordDurablePage(
                _ snapshot: WatchSyncSnapshot,
                metadata: WatchSyncPageCycleMetadata,
                outcome: WatchSyncSnapshotApplyOutcome
            ) {
                guard outcome.isDurable,
                      metadata.isValid(for: snapshot),
                      accepts(metadata)
                else {
                    return
                }

                if startsNewCycle(metadata) {
                    sourceID = metadata.sourceID
                    cycleID = metadata.cycleID
                    conversationIDs = []
                    conversationIDSet = []
                }
                for conversationID in snapshot.authoritativeConversationIDs
                    where conversationIDSet.insert(conversationID).inserted
                {
                    conversationIDs.append(conversationID)
                }
                expectedCursor = metadata.nextCursor
                if expectedCursor == nil {
                    reset()
                }
            }

            mutating func reset() {
                sourceID = nil
                cycleID = nil
                expectedCursor = nil
                conversationIDs = []
                conversationIDSet = []
            }

            private func accepts(_ metadata: WatchSyncPageCycleMetadata) -> Bool {
                if startsNewCycle(metadata) {
                    return metadata.cursor == .initial
                }
                return metadata.cursor == expectedCursor
            }

            private func startsNewCycle(_ metadata: WatchSyncPageCycleMetadata) -> Bool {
                sourceID != metadata.sourceID || cycleID != metadata.cycleID
            }
        }

        private static let defaultPersistenceKey = "com.sertacozercan.ayna.watch.conversations"
        private static let defaultMaximumCachedConversationBodies = 20

        private let userDefaults: UserDefaults
        private let persistenceKey: String
        private let maximumCachedConversationBodies: Int
        private let now: () -> Date
        private let persistenceWriter: (Data) -> Bool
        private let mutationEnqueuer: (WatchConversationMutation) -> Void

        private(set) var peerID: UUID
        private var sourceID: UUID?
        private var lastSnapshotRevision: WatchSyncRevision = 0
        private var committedConversations: [WatchConversation] = []
        private var pendingMutations: [WatchConversationMutation] = []
        private var pendingDrafts: [UUID: WatchConversationDraft] = [:]
        private var legacyDeliveryCoverage: [UUID: WatchMutationDeliveryCoverage] = [:]
        private var bodyRecency: [UUID: UInt64] = [:]
        private var bodyRecencySequence: UInt64 = 0
        private var lastAccessedConversationID: UUID?
        private var pageCycleManifestAccumulator = PageCycleManifestAccumulator()

        init(
            userDefaults: UserDefaults = .standard,
            persistenceKey: String = WatchConversationStore.defaultPersistenceKey,
            maximumCachedConversationBodies: Int = WatchConversationStore.defaultMaximumCachedConversationBodies,
            peerID: UUID? = nil,
            now: @escaping () -> Date = Date.init,
            persistenceWriter: ((Data) -> Bool)? = nil,
            mutationEnqueuer: ((WatchConversationMutation) -> Void)? = nil
        ) {
            self.userDefaults = userDefaults
            self.persistenceKey = persistenceKey
            self.maximumCachedConversationBodies = max(0, maximumCachedConversationBodies)
            self.peerID = peerID ?? UUID()
            self.now = now
            self.persistenceWriter = persistenceWriter ?? { data in
                userDefaults.set(data, forKey: persistenceKey)
                return true
            }
            self.mutationEnqueuer = mutationEnqueuer ?? { mutation in
                #if os(watchOS)
                    WatchConnectivityService.shared.enqueueMutation(mutation)
                #else
                    _ = mutation
                #endif
            }
            initializeFromDisk()
        }

        /// Coalesced durable mutations ready for WatchConnectivity transport.
        var pendingMutationsForSync: [WatchConversationMutation] {
            WatchConversationMutation.coalesced(pendingMutations)
        }

        /// Loads all durable Watch sync state immediately, independent of WCSession state.
        func initializeFromDisk() {
            guard let data = userDefaults.data(forKey: persistenceKey) else {
                rebuildPublishedConversations()
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ No persisted conversations found"
                )
                return
            }

            let decoder = JSONDecoder()
            do {
                if let persisted = try? decoder.decode(PersistedState.self, from: data) {
                    sourceID = persisted.sourceID
                    if let persistedPeerID = persisted.peerID {
                        peerID = persistedPeerID
                    }
                    lastSnapshotRevision = persisted.lastSnapshotRevision
                    committedConversations = deduplicated(persisted.conversations)
                    pendingMutations = WatchConversationMutation.coalesced(persisted.pendingMutations)
                    pendingDrafts = Dictionary(
                        persisted.pendingDrafts.map { ($0.id, $0) },
                        uniquingKeysWith: { _, new in new }
                    )
                    legacyDeliveryCoverage = persisted.legacyDeliveryCoverage ?? [:]
                    bodyRecency = persisted.bodyRecency ?? [:]
                    bodyRecencySequence = max(
                        persisted.bodyRecencySequence ?? 0,
                        bodyRecency.values.max() ?? 0
                    )
                    lastAccessedConversationID = persisted.lastAccessedConversationID
                    recoverInterruptedDrafts()
                } else {
                    // Backward compatibility with the original conversations-only payload.
                    committedConversations = try deduplicated(
                        decoder.decode([WatchConversation].self, from: data)
                    )
                    lastSnapshotRevision = 0
                    pendingMutations = []
                    pendingDrafts = [:]
                    legacyDeliveryCoverage = [:]
                    bodyRecency = [:]
                    bodyRecencySequence = 0
                    lastAccessedConversationID = nil
                }
                compactLoadedBodyCache()
                rebuildPublishedConversations()
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .info,
                    message: "⌚ Loaded durable Watch conversation state",
                    metadata: [
                        "conversations": "\(committedConversations.count)",
                        "mutations": "\(pendingMutations.count)",
                        "drafts": "\(pendingDrafts.count)",
                        "snapshotRevision": "\(lastSnapshotRevision)"
                    ]
                )
            } catch {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .error,
                    message: "⌚ Failed to load conversations from disk",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }

        /// Reconciles one explicit page-cycle snapshot and promotes the accumulated manifest
        /// to authoritative only on the final durable page.
        @discardableResult
        func applySyncSnapshot(
            _ snapshot: WatchSyncSnapshot,
            pageCycleMetadata: WatchSyncPageCycleMetadata
        ) -> WatchSyncSnapshotApplyOutcome {
            let snapshotForApplication = pageCycleManifestAccumulator.snapshotForApplication(
                snapshot,
                metadata: pageCycleMetadata
            )
            let outcome = applySyncSnapshot(snapshotForApplication)
            pageCycleManifestAccumulator.recordDurablePage(
                snapshot,
                metadata: pageCycleMetadata,
                outcome: outcome
            )
            return outcome
        }

        func resetPageCycleManifest() {
            pageCycleManifestAccumulator.reset()
        }

        /// Reconciles a phone-authoritative snapshot under durable local mutations and drafts.
        @discardableResult
        func applySyncSnapshot(_ snapshot: WatchSyncSnapshot) -> WatchSyncSnapshotApplyOutcome {
            let previousState = captureRuntimeState()
            let baseState = WatchSyncLocalState(
                sourceID: sourceID,
                peerID: peerID,
                lastSnapshotRevision: lastSnapshotRevision,
                conversations: committedConversations,
                pendingMutations: pendingMutations,
                pendingDrafts: [:],
                localDeliveryCoverage: legacyDeliveryCoverage
            )
            let visibleState = WatchSyncLocalState(
                sourceID: sourceID,
                peerID: peerID,
                lastSnapshotRevision: lastSnapshotRevision,
                conversations: committedConversations,
                pendingMutations: pendingMutations,
                pendingDrafts: pendingDrafts,
                localDeliveryCoverage: legacyDeliveryCoverage
            )
            let baseReconciliation = WatchSnapshotReconciler.reconcile(snapshot, with: baseState)
            let visibleReconciliation = WatchSnapshotReconciler.reconcile(snapshot, with: visibleState)

            switch visibleReconciliation.disposition {
            case .applied:
                break
            case .ignoredStale:
                if sourceID == snapshot.sourceID, lastSnapshotRevision == snapshot.revision {
                    return .alreadyDurable
                }
                return .ignoredStale
            case .ignoredUnsupportedSchema:
                return .ignoredUnsupportedSchema
            }

            sourceID = visibleReconciliation.state.sourceID
            lastSnapshotRevision = visibleReconciliation.state.lastSnapshotRevision
            committedConversations = deduplicated(baseReconciliation.state.conversations)
            pendingMutations = visibleReconciliation.state.pendingMutations
            recordSnapshotBodyRecency(snapshot)

            pendingDrafts = visibleReconciliation.state.pendingDrafts.mapValues { draft in
                WatchConversationDraft(
                    conversation: canonicalized(draft.conversation),
                    ownedMessageIDs: draft.ownedMessageIDs,
                    deferredMutationFields: draft.deferredMutationFields
                )
            }
            guard persistOrRestore(previousState) else { return .persistenceFailed }
            rebuildPublishedConversations()

            DiagnosticsLogger.log(
                .watchConnectivity,
                level: .info,
                message: "⌚ Applied Watch sync snapshot",
                metadata: [
                    "conversations": "\(conversations.count)",
                    "mutations": "\(pendingMutations.count)",
                    "drafts": "\(pendingDrafts.count)",
                    "snapshotRevision": "\(lastSnapshotRevision)"
                ]
            )
            return .applied
        }

        /// Removes all queued mutations at or below the phone-acknowledged revision.
        @discardableResult
        func acknowledgeWatchRevision(
            conversationID: UUID,
            revision: WatchSyncRevision
        ) -> Bool {
            let previousState = captureRuntimeState()
            pendingMutations.removeAll {
                $0.conversationID == conversationID && $0.revision <= revision
            }
            if let coverage = legacyDeliveryCoverage[conversationID] {
                let maximumCoveredRevision = [
                    coverage.createRevision,
                    coverage.titleRevision,
                    coverage.configurationRevision,
                    coverage.messageRevisions.values.max()
                ].compactMap(\.self).max() ?? 0
                if revision >= maximumCoveredRevision {
                    legacyDeliveryCoverage.removeValue(forKey: conversationID)
                }
            }
            if let index = committedConversations.firstIndex(where: { $0.id == conversationID }) {
                committedConversations[index].watchRevision = max(
                    committedConversations[index].watchRevision,
                    revision
                )
            }
            if var draft = pendingDrafts[conversationID] {
                draft.conversation.watchRevision = max(draft.conversation.watchRevision, revision)
                pendingDrafts[conversationID] = draft
            }
            guard persistOrRestore(previousState) else { return false }
            rebuildPublishedConversations()
            return true
        }

        // MARK: - Conversation operations

        func conversation(for id: UUID) -> WatchConversation? {
            guard let conversation = conversations.first(where: { $0.id == id }) else { return nil }
            recordCurrentBodyAccess(for: id)
            return conversation
        }

        @discardableResult
        func createConversation(
            title: String = "New Chat",
            model: String,
            resolvedSystemPrompt: String? = nil
        ) -> WatchConversation? {
            let previousState = captureRuntimeState()
            let timestamp = now()
            let conversation = WatchConversation(
                id: UUID(),
                title: title,
                model: model,
                updatedAt: timestamp,
                createdAt: timestamp,
                resolvedSystemPrompt: resolvedSystemPrompt,
                watchRevision: 1
            )
            upsertCommitted(conversation)
            guard queueMutation(for: conversation, fields: [.create], restoring: previousState) else {
                return nil
            }
            return conversation
        }

        @discardableResult
        func addMessage(_ message: WatchMessage, to conversationID: UUID) -> Bool {
            guard var committed = committedConversation(for: conversationID) else { return false }
            let previousState = captureRuntimeState()

            let timestamp = now()
            guard let revision = nextRevision(after: committed.watchRevision) else {
                var deferred = pendingDrafts[conversationID]?.conversation ?? committed
                deferred.messages.append(message)
                deferred.updatedAt = timestamp
                deferred.watchRevision = .max
                let ownedMessageIDs = pendingDrafts[conversationID]?.ownedMessageIDs
                    .union([message.id]) ?? [message.id]
                return refuseMutationPreservingDraft(
                    deferred,
                    fields: [.messages],
                    ownedMessageIDs: ownedMessageIDs,
                    restoring: previousState
                )
            }
            committed.messages.append(message)
            committed.updatedAt = timestamp
            committed.watchRevision = revision
            upsertCommitted(committed)

            var mutationConversation = committed
            if var draft = pendingDrafts[conversationID] {
                draft.conversation.messages.append(message)
                draft.conversation.updatedAt = timestamp
                draft.conversation.watchRevision = committed.watchRevision
                draft.conversation = canonicalized(draft.conversation)
                draft.ownedMessageIDs.remove(message.id)
                pendingDrafts[conversationID] = draft
                mutationConversation = draft.conversation
            }
            return queueMutation(
                for: mutationConversation,
                fields: [.messages],
                messageChanges: [message],
                restoring: previousState
            )
        }

        @discardableResult
        func renameConversation(_ conversationID: UUID, newTitle: String) -> Bool {
            guard var committed = committedConversation(for: conversationID), committed.title != newTitle else {
                return false
            }
            let previousState = captureRuntimeState()

            let timestamp = now()
            guard let revision = nextRevision(after: committed.watchRevision) else {
                var deferred = pendingDrafts[conversationID]?.conversation ?? committed
                deferred.title = newTitle
                deferred.updatedAt = timestamp
                deferred.watchRevision = .max
                return refuseMutationPreservingDraft(
                    deferred,
                    fields: [.title],
                    restoring: previousState
                )
            }
            committed.title = newTitle
            committed.updatedAt = timestamp
            committed.watchRevision = revision
            upsertCommitted(committed)

            var mutationConversation = committed
            if var draft = pendingDrafts[conversationID] {
                draft.conversation.title = newTitle
                draft.conversation.updatedAt = committed.updatedAt
                draft.conversation.watchRevision = committed.watchRevision
                pendingDrafts[conversationID] = draft
                mutationConversation = draft.conversation
            }
            return queueMutation(
                for: mutationConversation,
                fields: [.title],
                restoring: previousState
            )
        }

        @discardableResult
        func updateModel(_ model: String, for conversationID: UUID) -> Bool {
            guard var committed = committedConversation(for: conversationID), committed.model != model else {
                return false
            }
            let previousState = captureRuntimeState()

            let timestamp = now()
            guard let revision = nextRevision(after: committed.watchRevision) else {
                var deferred = pendingDrafts[conversationID]?.conversation ?? committed
                deferred.model = model
                deferred.updatedAt = timestamp
                deferred.watchRevision = .max
                return refuseMutationPreservingDraft(
                    deferred,
                    fields: [.configuration],
                    restoring: previousState
                )
            }
            committed.model = model
            committed.updatedAt = timestamp
            committed.watchRevision = revision
            upsertCommitted(committed)

            var mutationConversation = committed
            if var draft = pendingDrafts[conversationID] {
                draft.conversation.model = model
                draft.conversation.updatedAt = committed.updatedAt
                draft.conversation.watchRevision = committed.watchRevision
                pendingDrafts[conversationID] = draft
                mutationConversation = draft.conversation
            }
            return queueMutation(
                for: mutationConversation,
                fields: [.configuration],
                restoring: previousState
            )
        }

        @discardableResult
        func deleteConversation(_ conversationID: UUID) -> Bool {
            guard var deleted = conversation(for: conversationID) else { return false }
            let previousState = captureRuntimeState()

            let committedRevision = committedConversation(for: conversationID)?.watchRevision ?? 0
            let currentRevision = max(deleted.watchRevision, committedRevision)
            let timestamp = now()
            guard let revision = nextRevision(after: currentRevision) else {
                deleted.watchRevision = .max
                deleted.updatedAt = timestamp
                return refuseMutationPreservingDraft(
                    deleted,
                    fields: [.delete],
                    restoring: previousState
                )
            }
            deleted.watchRevision = revision
            deleted.updatedAt = timestamp
            committedConversations.removeAll { $0.id == conversationID }
            pendingDrafts.removeValue(forKey: conversationID)
            guard queueMutation(for: deleted, fields: [.delete], restoring: previousState) else {
                return false
            }

            DiagnosticsLogger.log(
                .watchConnectivity,
                level: .info,
                message: "⌚ Deleted conversation locally",
                metadata: ["conversationId": conversationID.uuidString]
            )
            return true
        }

        // MARK: - Draft overlays

        /// Persists a full local draft overlay without creating a transport mutation.
        @discardableResult
        func syncDraft(_ conversation: WatchConversation) -> Bool {
            guard let committed = committedConversation(for: conversation.id),
                  !hasPendingDelete(for: conversation.id)
            else {
                return false
            }
            let previousState = captureRuntimeState()

            var draft = canonicalized(conversation)
            draft.watchRevision = max(draft.watchRevision, committed.watchRevision)
            draft.updatedAt = max(draft.updatedAt, now())
            let committedMessagesByID = committed.messages.reduce(into: [UUID: WatchMessage]()) {
                $0[$1.id] = $1
            }
            let newOwnedMessageIDs = Set(
                draft.messages.lazy
                    .filter { committedMessagesByID[$0.id] != $0 }
                    .map(\.id)
            )
            let existingDraft = pendingDrafts[draft.id]
            let ownedMessageIDs = existingDraft?.ownedMessageIDs
                .union(newOwnedMessageIDs) ?? newOwnedMessageIDs
            pendingDrafts[draft.id] = WatchConversationDraft(
                conversation: draft,
                ownedMessageIDs: ownedMessageIDs,
                deferredMutationFields: existingDraft?.deferredMutationFields
            )
            guard persistOrRestore(previousState) else { return false }
            rebuildPublishedConversations()
            return true
        }

        /// Promotes a persisted draft to one coalesced message mutation.
        @discardableResult
        func finishDraft(conversationID: UUID) -> DraftPromotionOutcome {
            guard let draft = pendingDrafts[conversationID],
                  let committed = committedConversation(for: conversationID)
            else {
                return .noDraft
            }
            let previousState = captureRuntimeState()
            let currentRevision = max(draft.conversation.watchRevision, committed.watchRevision)
            guard let revision = nextRevision(after: currentRevision) else {
                logRevisionExhaustion(conversationID: conversationID, fields: draft.deferredFields.union(.messages))
                return .persistenceFailed
            }
            pendingDrafts.removeValue(forKey: conversationID)

            let messageChanges = draft.conversation.messages.filter {
                draft.ownedMessageIDs.contains($0.id)
            }
            guard !messageChanges.isEmpty else {
                guard persistOrRestore(previousState) else {
                    return .persistenceFailed
                }
                rebuildPublishedConversations()
                return .discardedEmptyDraft
            }

            var finished = committed
            finished.messages = mergeOwnedMessages(
                remote: committed.messages,
                ownedChanges: messageChanges
            )
            finished.watchRevision = revision
            finished.updatedAt = max(draft.conversation.updatedAt, now())
            upsertCommitted(finished)
            guard queueMutation(
                for: finished,
                fields: [.messages],
                messageChanges: messageChanges,
                restoring: previousState
            ) else {
                return .persistenceFailed
            }
            return .promoted(finished)
        }

        /// Removes a persisted draft and restores the committed conversation.
        @discardableResult
        func discardDraft(conversationID: UUID) -> Bool {
            guard pendingDrafts[conversationID] != nil else { return false }
            let previousState = captureRuntimeState()
            pendingDrafts.removeValue(forKey: conversationID)
            guard persistOrRestore(previousState) else { return false }
            rebuildPublishedConversations()
            return true
        }

        // MARK: - Compatibility helpers

        /// Compatibility path for legacy application-context payloads.
        func updateConversations(_ newConversations: [WatchConversation]) {
            let sourceID = lastSnapshotRevision == .max
                ? UUID()
                : (self.sourceID ?? WatchSyncIdentity.legacySourceID)
            let revision = lastSnapshotRevision == .max ? 1 : lastSnapshotRevision + 1
            applySyncSnapshot(
                WatchSyncSnapshot(
                    sourceID: sourceID,
                    revision: revision,
                    conversations: newConversations,
                    authoritativeConversationIDs: newConversations.map(\.id),
                    authoritativeConversationIDsAreComplete: false
                )
            )
        }

        /// Treats direct replacement as an in-progress local draft.
        @discardableResult
        func replaceConversation(_ conversation: WatchConversation, persist _: Bool = true) -> Bool {
            guard committedConversation(for: conversation.id) != nil else { return false }
            return syncDraft(conversation)
        }

        /// Treats streaming content changes as draft-only state.
        @discardableResult
        func updateLastMessage(in conversationID: UUID, content: String) -> Bool {
            guard var conversation = conversation(for: conversationID),
                  let lastIndex = conversation.messages.indices.last,
                  conversation.messages[lastIndex].content != content
            else {
                return false
            }
            conversation.messages[lastIndex].content = content
            return syncDraft(conversation)
        }

        @discardableResult
        func persistCurrentState() -> Bool {
            let persisted = persistState()
            if persisted {
                rebuildPublishedConversations()
            }
            return persisted
        }

        @discardableResult
        func markLegacyComponentsDelivered(
            _ components: [WatchLegacyEchoComponent],
            for mutation: WatchConversationMutation
        ) -> Bool {
            let recordableComponents = components.filter(\.shouldRecordInStoreCoverage)
            guard !recordableComponents.isEmpty else { return true }
            let previousState = captureRuntimeState()

            var coverage = legacyDeliveryCoverage[mutation.conversationID]
                ?? WatchMutationDeliveryCoverage()
            for component in recordableComponents {
                switch component {
                case .create:
                    break
                case let .title(revision):
                    coverage.titleRevision = max(coverage.titleRevision ?? 0, revision)
                case let .configuration(revision):
                    coverage.configurationRevision = max(
                        coverage.configurationRevision ?? 0,
                        revision
                    )
                case let .message(messageID, revision):
                    coverage.messageRevisions[messageID] = max(
                        coverage.messageRevisions[messageID, default: 0],
                        revision
                    )
                }
            }
            legacyDeliveryCoverage[mutation.conversationID] = coverage
            guard persistOrRestore(previousState) else { return false }
            rebuildPublishedConversations()
            return true
        }

        func durableLegacyDeliveryCoverage(
            for conversationID: UUID
        ) -> WatchMutationDeliveryCoverage? {
            legacyDeliveryCoverage[conversationID]
        }

        @discardableResult
        func clearLegacyDeliveryCoverage() -> Bool {
            guard !legacyDeliveryCoverage.isEmpty else { return true }
            legacyDeliveryCoverage.removeAll()
            let persisted = persistState()
            rebuildPublishedConversations()
            return persisted
        }

        func previewText(for conversation: WatchConversation) -> String {
            guard let lastMessage = conversation.messages.last else { return "No messages" }
            let preview = lastMessage.content.prefix(50)
            return preview.count < lastMessage.content.count ? "\(preview)..." : String(preview)
        }

        // MARK: - Private state management

        private func queueMutation(
            for conversation: WatchConversation,
            fields: WatchConversationMutationFields,
            messageChanges: [WatchMessage] = [],
            restoring previousState: RuntimeState
        ) -> Bool {
            let mutation = WatchConversationMutation(
                peerID: peerID,
                revision: conversation.watchRevision,
                conversation: conversation,
                fields: fields,
                messageChanges: messageChanges
            )
            pendingMutations = WatchConversationMutation.coalesced(pendingMutations + [mutation])
            guard let queued = pendingMutations.first(where: { $0.conversationID == conversation.id }) else {
                restoreRuntimeState(previousState)
                return false
            }
            guard persistOrRestore(previousState) else { return false }

            rebuildPublishedConversations()
            mutationEnqueuer(queued)
            return true
        }

        private func captureRuntimeState() -> RuntimeState {
            RuntimeState(
                sourceID: sourceID,
                peerID: peerID,
                lastSnapshotRevision: lastSnapshotRevision,
                committedConversations: committedConversations,
                pendingMutations: pendingMutations,
                pendingDrafts: pendingDrafts,
                legacyDeliveryCoverage: legacyDeliveryCoverage,
                bodyRecency: bodyRecency,
                bodyRecencySequence: bodyRecencySequence,
                lastAccessedConversationID: lastAccessedConversationID
            )
        }

        private func restoreRuntimeState(_ state: RuntimeState) {
            sourceID = state.sourceID
            peerID = state.peerID
            lastSnapshotRevision = state.lastSnapshotRevision
            committedConversations = state.committedConversations
            pendingMutations = state.pendingMutations
            pendingDrafts = state.pendingDrafts
            legacyDeliveryCoverage = state.legacyDeliveryCoverage
            bodyRecency = state.bodyRecency
            bodyRecencySequence = state.bodyRecencySequence
            lastAccessedConversationID = state.lastAccessedConversationID
        }

        @discardableResult
        private func persistOrRestore(_ previousState: RuntimeState) -> Bool {
            guard persistState() else {
                restoreRuntimeState(previousState)
                return false
            }
            return true
        }

        @discardableResult
        private func persistState() -> Bool {
            let bodyCacheState = boundedBodyCacheState()
            let state = PersistedState(
                sourceID: sourceID,
                peerID: peerID,
                lastSnapshotRevision: lastSnapshotRevision,
                conversations: bodyCacheState.conversations,
                pendingMutations: WatchConversationMutation.coalesced(pendingMutations),
                pendingDrafts: pendingDrafts.values.sorted {
                    conversationSort($0.conversation, $1.conversation)
                },
                legacyDeliveryCoverage: legacyDeliveryCoverage,
                bodyRecency: bodyCacheState.recency,
                bodyRecencySequence: bodyCacheState.recencySequence,
                lastAccessedConversationID: bodyCacheState.lastAccessedConversationID
            )

            do {
                let data = try JSONEncoder().encode(state)
                guard persistenceWriter(data) else {
                    DiagnosticsLogger.log(
                        .watchConnectivity,
                        level: .error,
                        message: "⌚ Watch conversation state writer rejected persistence"
                    )
                    return false
                }
                applyBodyCacheState(bodyCacheState)
                return true
            } catch {
                DiagnosticsLogger.log(
                    .watchConnectivity,
                    level: .error,
                    message: "⌚ Failed to persist Watch conversation state",
                    metadata: ["error": error.localizedDescription]
                )
                return false
            }
        }

        private func compactLoadedBodyCache() {
            let bounded = boundedBodyCacheState()
            let current = BodyCacheState(
                conversations: committedConversations.sorted(by: conversationSort),
                recency: bodyRecency,
                recencySequence: bodyRecencySequence,
                lastAccessedConversationID: lastAccessedConversationID
            )
            guard bounded != current else { return }
            _ = persistState()
        }

        private func boundedBodyCacheState() -> BodyCacheState {
            let canonicalConversations = deduplicated(committedConversations)
            let cachedIDs = Set(canonicalConversations.map(\.id))
            var recency = bodyRecency.filter { cachedIDs.contains($0.key) }
            var recencySequence = max(bodyRecencySequence, recency.values.max() ?? 0)

            for conversation in canonicalConversations.sorted(by: conversationSort).reversed()
                where recency[conversation.id] == nil
            {
                Self.appendBodyRecency(
                    for: conversation.id,
                    to: &recency,
                    sequence: &recencySequence
                )
            }

            var protectedIDs = Set(pendingMutations.map(\.conversationID))
            protectedIDs.formUnion(pendingDrafts.keys)
            protectedIDs.formUnion(legacyDeliveryCoverage.keys)
            if let selectedConversationId {
                protectedIDs.insert(selectedConversationId)
            }
            if let lastAccessedConversationID {
                protectedIDs.insert(lastAccessedConversationID)
            }
            protectedIDs.formIntersection(cachedIDs)

            let ordinaryCapacity = max(0, maximumCachedConversationBodies - protectedIDs.count)
            let ordinaryCandidates = canonicalConversations
                .filter { !protectedIDs.contains($0.id) }
                .sorted { lhs, rhs in
                    let lhsRecency = recency[lhs.id] ?? 0
                    let rhsRecency = recency[rhs.id] ?? 0
                    if lhsRecency != rhsRecency {
                        return lhsRecency > rhsRecency
                    }
                    return conversationSort(lhs, rhs)
                }
            var retainedIDs = protectedIDs
            retainedIDs.formUnion(ordinaryCandidates.prefix(ordinaryCapacity).map(\.id))

            let retainedConversations = canonicalConversations.filter { retainedIDs.contains($0.id) }
            recency = recency.filter { retainedIDs.contains($0.key) }
            let retainedLastAccessedID = lastAccessedConversationID.flatMap {
                retainedIDs.contains($0) ? $0 : nil
            }
            return BodyCacheState(
                conversations: retainedConversations,
                recency: recency,
                recencySequence: recencySequence,
                lastAccessedConversationID: retainedLastAccessedID
            )
        }

        private func applyBodyCacheState(_ state: BodyCacheState) {
            committedConversations = state.conversations
            bodyRecency = state.recency
            bodyRecencySequence = state.recencySequence
            lastAccessedConversationID = state.lastAccessedConversationID
        }

        private func recordSnapshotBodyRecency(_ snapshot: WatchSyncSnapshot) {
            let cachedIDs = Set(committedConversations.map(\.id))
            for conversation in snapshot.conversations.sorted(by: conversationSort).reversed()
                where cachedIDs.contains(conversation.id)
            {
                recordBodyAccess(for: conversation.id)
            }
        }

        private func recordBodyAccess(for conversationID: UUID, asCurrent: Bool = false) {
            Self.appendBodyRecency(
                for: conversationID,
                to: &bodyRecency,
                sequence: &bodyRecencySequence
            )
            if asCurrent {
                lastAccessedConversationID = conversationID
            }
        }

        private func recordCurrentBodyAccess(for conversationID: UUID) {
            guard lastAccessedConversationID != conversationID else { return }
            let previousConversationIDs = committedConversations.map(\.id)
            recordBodyAccess(for: conversationID, asCurrent: true)
            guard persistState(), committedConversations.map(\.id) != previousConversationIDs else { return }
            rebuildPublishedConversations()
        }

        private static func appendBodyRecency(
            for conversationID: UUID,
            to recency: inout [UUID: UInt64],
            sequence: inout UInt64
        ) {
            if sequence == .max {
                normalizeBodyRecency(&recency, sequence: &sequence)
            }
            sequence += 1
            recency[conversationID] = sequence
        }

        private static func normalizeBodyRecency(
            _ recency: inout [UUID: UInt64],
            sequence: inout UInt64
        ) {
            let orderedIDs = recency.keys.sorted { lhs, rhs in
                let lhsRecency = recency[lhs] ?? 0
                let rhsRecency = recency[rhs] ?? 0
                if lhsRecency != rhsRecency {
                    return lhsRecency < rhsRecency
                }
                return lhs.uuidString < rhs.uuidString
            }
            recency.removeAll(keepingCapacity: true)
            for (offset, conversationID) in orderedIDs.enumerated() {
                recency[conversationID] = UInt64(offset + 1)
            }
            sequence = UInt64(orderedIDs.count)
        }

        private func rebuildPublishedConversations() {
            var visible = dictionaryByID(committedConversations)

            for mutation in pendingMutations where mutation.fields.contains(.delete) {
                visible.removeValue(forKey: mutation.conversationID)
            }
            for (id, draft) in pendingDrafts {
                if draft.deferredFields.contains(.delete) {
                    visible.removeValue(forKey: id)
                } else if !hasPendingTransportDelete(for: id) {
                    visible[id] = draft.conversation
                }
            }

            publishConversations(visible.values.sorted(by: conversationSort))
        }

        private func publishConversations(_ conversations: [WatchConversation]) {
            self.conversations = conversations
            clearInvalidSelection()
        }

        private func committedConversation(for id: UUID) -> WatchConversation? {
            committedConversations.first { $0.id == id }
        }

        private func upsertCommitted(_ conversation: WatchConversation) {
            let canonical = canonicalized(conversation)
            if let index = committedConversations.firstIndex(where: { $0.id == canonical.id }) {
                committedConversations[index] = canonical
            } else {
                committedConversations.append(canonical)
            }
            committedConversations.sort(by: conversationSort)
            recordBodyAccess(for: canonical.id)
        }

        private func hasPendingDelete(for conversationID: UUID) -> Bool {
            hasPendingTransportDelete(for: conversationID)
                || pendingDrafts[conversationID]?.deferredFields.contains(.delete) == true
        }

        private func hasPendingTransportDelete(for conversationID: UUID) -> Bool {
            pendingMutations.contains {
                $0.conversationID == conversationID && $0.fields.contains(.delete)
            }
        }

        private func recoverInterruptedDrafts() {
            guard !pendingDrafts.isEmpty else { return }
            let previousState = captureRuntimeState()

            for draft in Array(pendingDrafts.values) {
                guard let committed = committedConversation(for: draft.id),
                      !hasPendingTransportDelete(for: draft.id)
                else {
                    pendingDrafts.removeValue(forKey: draft.id)
                    continue
                }

                let recoveredMessages = draft.conversation.messages.filter {
                    draft.ownedMessageIDs.contains($0.id) && isMeaningfulDraftMessage($0)
                }
                let currentRevision = max(
                    draft.conversation.watchRevision,
                    committed.watchRevision
                )
                guard let revision = nextRevision(after: currentRevision) else {
                    if recoveredMessages.isEmpty, draft.deferredFields.isEmpty {
                        pendingDrafts.removeValue(forKey: draft.id)
                    } else {
                        logRevisionExhaustion(
                            conversationID: draft.id,
                            fields: draft.deferredFields.union(
                                recoveredMessages.isEmpty ? [] : .messages
                            )
                        )
                    }
                    continue
                }

                pendingDrafts.removeValue(forKey: draft.id)
                guard !recoveredMessages.isEmpty else { continue }

                var recovered = committed
                recovered.messages = mergeOwnedMessages(
                    remote: committed.messages,
                    ownedChanges: recoveredMessages
                )
                recovered.watchRevision = revision
                recovered.updatedAt = max(draft.conversation.updatedAt, now())
                upsertCommitted(recovered)
                let mutation = WatchConversationMutation(
                    peerID: peerID,
                    revision: recovered.watchRevision,
                    conversation: recovered,
                    fields: [.messages],
                    messageChanges: recoveredMessages
                )
                pendingMutations = WatchConversationMutation.coalesced(pendingMutations + [mutation])
            }

            _ = persistOrRestore(previousState)
        }

        private func isMeaningfulDraftMessage(_ message: WatchMessage) -> Bool {
            !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !(message.citations?.isEmpty ?? true) ||
                !(message.toolCalls?.isEmpty ?? true) ||
                message.role == Message.Role.tool.rawValue
        }

        private func mergeOwnedMessages(
            remote: [WatchMessage],
            ownedChanges: [WatchMessage]
        ) -> [WatchMessage] {
            var result: [WatchMessage] = []
            var indexByID: [UUID: Int] = [:]
            for message in remote {
                if let index = indexByID[message.id] {
                    result[index] = message
                } else {
                    indexByID[message.id] = result.count
                    result.append(message)
                }
            }
            for message in ownedChanges {
                if let index = indexByID[message.id] {
                    result[index] = message
                } else {
                    indexByID[message.id] = result.count
                    result.append(message)
                }
            }
            return result
        }

        private func nextRevision(after revision: WatchSyncRevision) -> WatchSyncRevision? {
            guard revision < .max else { return nil }
            return revision + 1
        }

        private func refuseMutationPreservingDraft(
            _ conversation: WatchConversation,
            fields: WatchConversationMutationFields,
            ownedMessageIDs: Set<UUID> = [],
            restoring previousState: RuntimeState
        ) -> Bool {
            let existingDraft = pendingDrafts[conversation.id]
            pendingDrafts[conversation.id] = WatchConversationDraft(
                conversation: canonicalized(conversation),
                ownedMessageIDs: existingDraft?.ownedMessageIDs.union(ownedMessageIDs)
                    ?? ownedMessageIDs,
                deferredMutationFields: existingDraft?.deferredFields.union(fields) ?? fields
            )
            guard persistOrRestore(previousState) else { return false }
            rebuildPublishedConversations()
            logRevisionExhaustion(conversationID: conversation.id, fields: fields)
            return false
        }

        private func logRevisionExhaustion(
            conversationID: UUID,
            fields: WatchConversationMutationFields
        ) {
            DiagnosticsLogger.log(
                .watchConnectivity,
                level: .error,
                message: "⌚ Refused Watch mutation because its revision is exhausted",
                metadata: [
                    "conversationId": conversationID.uuidString,
                    "fields": "\(fields.rawValue)"
                ]
            )
        }

        private func clearInvalidSelection() {
            guard let selectedConversationId,
                  !conversations.contains(where: { $0.id == selectedConversationId })
            else {
                return
            }
            self.selectedConversationId = nil
        }

        private func dictionaryByID(
            _ source: some Sequence<WatchConversation>
        ) -> [UUID: WatchConversation] {
            var result: [UUID: WatchConversation] = [:]
            for value in source {
                let conversation = canonicalized(value)
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

        private func canonicalized(_ conversation: WatchConversation) -> WatchConversation {
            WatchConversationCanonicalizer.watchConversation(conversation)
        }

        private func preferredState(
            _ candidate: WatchConversation,
            over existing: WatchConversation
        ) -> Bool {
            if candidate.watchRevision != existing.watchRevision {
                return candidate.watchRevision > existing.watchRevision
            }
            return conversationSort(candidate, existing)
        }

        private func deduplicated(_ source: [WatchConversation]) -> [WatchConversation] {
            WatchConversationCanonicalizer.watchConversations(source)
        }

        private func conversationSort(_ lhs: WatchConversation, _ rhs: WatchConversation) -> Bool {
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

#endif
