#if os(watchOS) || WATCH_STORE_HOST_TESTING

    // swiftlint:disable identifier_name

    @testable import Ayna
    import Combine
    import Foundation
    import Testing

    @Suite("Watch sync conversation store native tests")
    @MainActor
    // swiftlint:disable:next type_body_length
    struct WatchSyncConversationStoreNativeTests {
        @Test
        func `Watch-created conversation uses the synced default system prompt immediately`() throws {
            let fixture = makeFixture()

            let conversation = try #require(fixture.store.createConversation(
                model: "model",
                resolvedSystemPrompt: "Synced global prompt"
            ))

            #expect(conversation.resolvedSystemPrompt == "Synced global prompt")
            #expect(conversation.effectiveHistory.first?.role == .system)
            #expect(conversation.effectiveHistory.first?.content == "Synced global prompt")
        }

        @Test
        func `Snapshot echo keeps a persisted local draft overlay`() throws {
            let fixture = makeFixture()
            let conversation = makeConversation(messages: [makeMessage(role: .user, content: "Prompt")])
            fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation]))

            var draft = conversation
            draft.messages.append(makeMessage(role: .assistant, content: "Partial", model: conversation.model))
            fixture.store.syncDraft(draft)
            fixture.store.applySyncSnapshot(snapshot(revision: 2, conversations: [conversation]))

            let visible = try #require(fixture.store.conversation(for: conversation.id))
            #expect(visible.messages.map(\.content) == ["Prompt", "Partial"])

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(reloaded.conversation(for: conversation.id)?.messages.last?.content == "Partial")
            #expect(reloaded.pendingMutationsForSync.first?.messageChanges.last?.content == "Partial")
        }

        @Test
        func `Restart discards an empty assistant draft placeholder`() throws {
            let fixture = makeFixture()
            let conversation = makeConversation(messages: [makeMessage(role: .user, content: "Prompt")])
            fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation]))

            var draft = conversation
            draft.messages.append(makeMessage(role: .assistant, content: "", model: conversation.model))
            fixture.store.syncDraft(draft)

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            let restored = try #require(reloaded.conversation(for: conversation.id))
            #expect(restored.messages.map(\.content) == ["Prompt"])
            #expect(reloaded.pendingMutationsForSync.isEmpty)
        }

        @Test
        func `Explicitly empty authoritative snapshot deletes remote-only conversations`() {
            let fixture = makeFixture()
            let conversation = makeConversation()
            fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation]))

            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [],
                    authoritativeConversationIDs: []
                )
            )

            #expect(fixture.store.conversation(for: conversation.id) == nil)
        }

        @Test
        func `Completed multi-page cycle prunes stale conversations and preserves Watch-owned work`() throws {
            let fixture = makeFixture()
            let sourceID = UUID()
            let cycleID = UUID()
            let retainedFirst = makeConversation(id: UUID())
            let retainedSecond = makeConversation(id: UUID())
            let stale = makeConversation(id: UUID())
            let initial = WatchSyncSnapshot(
                sourceID: sourceID,
                revision: 1,
                conversations: [retainedFirst, retainedSecond, stale],
                authoritativeConversationIDs: [retainedFirst.id, retainedSecond.id, stale.id]
            )
            #expect(fixture.store.applySyncSnapshot(initial) == .applied)

            let watchOwned = try #require(fixture.store.createConversation(model: "model"))
            var draft = watchOwned
            draft.messages.append(makeMessage(role: .assistant, content: "Watch draft", model: "model"))
            #expect(fixture.store.syncDraft(draft))

            let firstPage = WatchSyncSnapshot(
                sourceID: sourceID,
                revision: 2,
                paginationCursor: 0,
                conversations: [retainedFirst],
                authoritativeConversationIDs: [retainedFirst.id],
                authoritativeConversationIDsAreComplete: false
            )
            let firstMetadata = WatchSyncPageCycleMetadata(
                cycleID: cycleID,
                sourceID: sourceID,
                snapshotRevision: firstPage.revision,
                cursor: .initial,
                manifest: WatchSyncPageSection(offset: 0, itemCount: 1, totalCount: 2),
                configurations: WatchSyncPageSection(offset: 0, itemCount: 0, totalCount: 0),
                tombstones: WatchSyncPageSection(offset: 0, itemCount: 0, totalCount: 0)
            )
            let secondCursor = try #require(firstMetadata.nextCursor)
            let secondPage = WatchSyncSnapshot(
                sourceID: sourceID,
                revision: 3,
                paginationCursor: 1,
                conversations: [retainedSecond],
                authoritativeConversationIDs: [retainedSecond.id],
                authoritativeConversationIDsAreComplete: false
            )
            let secondMetadata = WatchSyncPageCycleMetadata(
                cycleID: cycleID,
                sourceID: sourceID,
                snapshotRevision: secondPage.revision,
                cursor: secondCursor,
                manifest: WatchSyncPageSection(offset: 1, itemCount: 1, totalCount: 2),
                configurations: WatchSyncPageSection(offset: 0, itemCount: 0, totalCount: 0),
                tombstones: WatchSyncPageSection(offset: 0, itemCount: 0, totalCount: 0)
            )

            #expect(fixture.store.applySyncSnapshot(
                firstPage,
                pageCycleMetadata: firstMetadata
            ) == .applied)
            #expect(fixture.store.conversation(for: stale.id) != nil)

            #expect(fixture.store.applySyncSnapshot(
                secondPage,
                pageCycleMetadata: secondMetadata
            ) == .applied)

            #expect(fixture.store.conversation(for: retainedFirst.id) != nil)
            #expect(fixture.store.conversation(for: retainedSecond.id) != nil)
            #expect(fixture.store.conversation(for: stale.id) == nil)
            #expect(fixture.store.conversation(for: watchOwned.id)?.messages.last?.content == "Watch draft")
            #expect(fixture.store.pendingMutationsForSync.contains { $0.conversationID == watchOwned.id })
        }

        @Test
        func `Rejected snapshot is not published and can be retried`() throws {
            let fixture = makeFixture()
            let conversation = makeConversation()
            fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation]))
            var publishedTitles: [[String]] = []
            let cancellable = fixture.store.$conversations.sink { conversations in
                publishedTitles.append(conversations.map(\.title))
            }
            defer { cancellable.cancel() }
            var updated = conversation
            updated.title = "Phone edit"
            updated.updatedAt = Date(timeIntervalSince1970: 30)
            fixture.allowsPersistence = false

            fixture.store.applySyncSnapshot(snapshot(revision: 2, conversations: [updated]))

            #expect(publishedTitles == [["Synced"]])
            #expect(try #require(fixture.store.conversation(for: conversation.id)).title == "Synced")

            fixture.allowsPersistence = true
            fixture.store.applySyncSnapshot(snapshot(revision: 2, conversations: [updated]))

            #expect(publishedTitles == [["Synced"], ["Phone edit"]])
            #expect(try #require(fixture.store.conversation(for: conversation.id)).title == "Phone edit")

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(try #require(reloaded.conversation(for: conversation.id)).title == "Phone edit")
        }

        @Test
        func `Failed first page remains the exact retry until its snapshot is durable`() throws {
            let fixture = makeFixture()
            let conversation = makeConversation()
            let sourceID = UUID()
            let cycleID = UUID()
            let deletedID = UUID()
            let snapshot = WatchSyncSnapshot(
                sourceID: sourceID,
                revision: 1,
                paginationCursor: 0,
                conversations: [conversation],
                authoritativeConversationIDs: [conversation.id],
                authoritativeConversationIDsAreComplete: false,
                conversationConfigurations: [
                    WatchConversationRequestConfiguration(
                        id: conversation.id,
                        model: conversation.model,
                        temperature: conversation.temperature,
                        resolvedSystemPrompt: conversation.resolvedSystemPrompt
                    )
                ],
                conversationConfigurationsAreComplete: false,
                tombstones: [WatchConversationTombstone(conversationID: deletedID, revision: 1)]
            )
            let metadata = WatchSyncPageCycleMetadata(
                cycleID: cycleID,
                sourceID: sourceID,
                snapshotRevision: snapshot.revision,
                cursor: .initial,
                manifest: WatchSyncPageSection(offset: 0, itemCount: 1, totalCount: 2),
                configurations: WatchSyncPageSection(offset: 0, itemCount: 1, totalCount: 2),
                tombstones: WatchSyncPageSection(offset: 0, itemCount: 1, totalCount: 2)
            )
            let initialRequest = WatchSyncPageCycleRequest(cycleID: cycleID, cursor: .initial)
            let nextRequest = try WatchSyncPageCycleRequest(
                cycleID: cycleID,
                cursor: #require(metadata.nextCursor)
            )
            var coordinator = WatchPageCycleCoordinator()
            fixture.allowsPersistence = false

            let failedApply = fixture.store.applySyncSnapshot(snapshot)
            let failedPage = coordinator.receive(metadata, after: failedApply)

            #expect(failedApply == .persistenceFailed)
            #expect(!failedPage.acceptedPage)
            #expect(failedPage.retainedForRetry)
            #expect(failedPage.pendingRequest == initialRequest)
            #expect(fixture.store.conversation(for: conversation.id) == nil)

            fixture.allowsPersistence = true
            let durableApply = fixture.store.applySyncSnapshot(snapshot)
            let durablePage = coordinator.receive(metadata, after: durableApply)

            #expect(durableApply == .applied)
            #expect(durablePage.acceptedPage)
            #expect(!durablePage.retainedForRetry)
            #expect(durablePage.pendingRequest == nextRequest)
            #expect(fixture.store.conversation(for: conversation.id) != nil)

            let repeatedApply = fixture.store.applySyncSnapshot(snapshot)
            let repeatedPage = coordinator.receive(metadata, after: repeatedApply)

            #expect(repeatedApply == .alreadyDurable)
            #expect(!repeatedPage.acceptedPage)
            #expect(repeatedPage.pendingRequest == nextRequest)
        }

        @Test
        func `Legacy bounded bodies preserve a revisioned source across restart and empty lists`() throws {
            let fixture = makeFixture()
            let sourceID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            let conversationA = makeConversation()
            let conversationB = makeConversation()
            let initialApply = fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    sourceID: sourceID,
                    revision: 7,
                    conversations: [conversationA, conversationB],
                    authoritativeConversationIDs: [conversationA.id, conversationB.id]
                )
            )
            var updatedA = conversationA
            updatedA.title = "Updated by phone"
            updatedA.updatedAt = Date(timeIntervalSince1970: 30)

            fixture.store.updateConversations([updatedA])

            #expect(initialApply == .applied)
            #expect(try #require(fixture.store.conversation(for: conversationA.id)).title == "Updated by phone")
            #expect(fixture.store.conversation(for: conversationB.id) == conversationB)

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(try #require(restarted.conversation(for: conversationA.id)).title == "Updated by phone")
            #expect(restarted.conversation(for: conversationB.id) == conversationB)

            restarted.updateConversations([])

            #expect(restarted.conversation(for: conversationA.id) != nil)
            #expect(restarted.conversation(for: conversationB.id) == conversationB)

            let restartedAfterEmptyList = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(restartedAfterEmptyList.conversation(for: conversationA.id) != nil)
            #expect(restartedAfterEmptyList.conversation(for: conversationB.id) == conversationB)
        }

        @Test
        func `Rotating authoritative bodies keep persisted Watch cache bounded across restart`() throws {
            let fixture = makeFixture()
            let bodies = (0 ..< 25).map { index in
                makeConversation(
                    id: UUID(),
                    messages: [makeMessage(role: .assistant, content: "Body \(index)")]
                )
            }
            let manifest = bodies.map(\.id)

            for (index, body) in bodies.enumerated() {
                let outcome = fixture.store.applySyncSnapshot(
                    WatchSyncSnapshot(
                        revision: WatchSyncRevision(index + 1),
                        conversations: [body],
                        authoritativeConversationIDs: manifest
                    )
                )
                #expect(outcome == .applied)
            }

            let persisted = try persistedFixtureState(in: fixture)
            #expect(persisted.conversations.count == 20)
            #expect(fixture.store.conversations.count == 20)

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(restarted.conversations.count == 20)
        }

        @Test
        func `Restart compacts previously unbounded persisted bodies`() throws {
            let fixture = makeFixture()
            let bodies = (0 ..< 25).map { _ in makeConversation(id: UUID()) }
            try persistFixtureState(
                peerID: UUID(),
                conversations: bodies,
                in: fixture
            )

            #expect(fixture.store.conversations.count == 20)
            #expect(try persistedFixtureState(in: fixture).conversations.count == 20)
        }

        @Test
        func `Failed restart compaction keeps the previously durable cache visible`() throws {
            let fixture = makeFixture()
            let bodies = (0 ..< 25).map { _ in makeConversation(id: UUID()) }
            try persistFixtureState(
                peerID: UUID(),
                conversations: bodies,
                in: fixture
            )
            fixture.allowsPersistence = false

            #expect(fixture.store.conversations.count == 25)
            #expect(try persistedFixtureState(in: fixture).conversations.count == 25)
        }

        @Test
        func `Bounded cache keeps a manifest-only body across persistence and restart`() throws {
            let fixture = makeFixture(maximumCachedConversationBodies: 2)
            let retained = makeConversation(id: UUID())
            var updated = makeConversation(id: UUID())
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 1,
                    conversations: [updated, retained],
                    authoritativeConversationIDs: [updated.id, retained.id]
                )
            )
            updated.title = "Updated body"

            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [updated],
                    authoritativeConversationIDs: [updated.id, retained.id]
                )
            )

            #expect(fixture.store.conversation(for: retained.id) == retained)
            #expect(try persistedFixtureState(in: fixture).conversations.count == 2)

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                maximumCachedConversationBodies: 2,
                mutationEnqueuer: { _ in }
            )
            #expect(restarted.conversation(for: retained.id) == retained)
        }

        @Test
        func `Selected conversation access is durable before the next eviction`() throws {
            let fixture = makeFixture(maximumCachedConversationBodies: 2)
            let selected = makeConversation(id: UUID())
            let evicted = makeConversation(id: UUID())
            let newest = makeConversation(id: UUID())
            let manifest = [selected.id, evicted.id, newest.id]
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 1,
                    conversations: [selected, evicted],
                    authoritativeConversationIDs: manifest
                )
            )
            fixture.store.selectedConversationId = selected.id

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                maximumCachedConversationBodies: 2,
                mutationEnqueuer: { _ in }
            )
            restarted.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [newest],
                    authoritativeConversationIDs: manifest
                )
            )

            #expect(restarted.conversation(for: selected.id) != nil)
            #expect(restarted.conversation(for: newest.id) != nil)
            #expect(restarted.conversation(for: evicted.id) == nil)
            #expect(try persistedFixtureState(in: fixture).conversations.count == 2)
        }

        @Test
        func `Current conversation read is durable before the next eviction`() {
            let fixture = makeFixture(maximumCachedConversationBodies: 2)
            let current = makeConversation(id: UUID())
            let evicted = makeConversation(id: UUID())
            let newest = makeConversation(id: UUID())
            let manifest = [current.id, evicted.id, newest.id]
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 1,
                    conversations: [current, evicted],
                    authoritativeConversationIDs: manifest
                )
            )
            _ = fixture.store.conversation(for: current.id)

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                maximumCachedConversationBodies: 2,
                mutationEnqueuer: { _ in }
            )
            restarted.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [newest],
                    authoritativeConversationIDs: manifest
                )
            )

            #expect(restarted.conversation(for: current.id) != nil)
            #expect(restarted.conversation(for: newest.id) != nil)
            #expect(restarted.conversation(for: evicted.id) == nil)
        }

        @Test
        func `Pending mutations may exceed the body target until acknowledged`() throws {
            let fixture = makeFixture(maximumCachedConversationBodies: 1)
            let first = try #require(fixture.store.createConversation(model: "model"))
            let second = try #require(fixture.store.createConversation(model: "model"))

            #expect(try persistedFixtureState(in: fixture).conversations.count == 2)

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                maximumCachedConversationBodies: 1,
                mutationEnqueuer: { _ in }
            )
            #expect(restarted.conversation(for: first.id) != nil)
            #expect(restarted.conversation(for: second.id) != nil)

            #expect(restarted.acknowledgeWatchRevision(conversationID: first.id, revision: 1))
            #expect(restarted.conversation(for: first.id) == nil)
            #expect(restarted.conversation(for: second.id) != nil)
            let compacted = try persistedFixtureState(in: fixture)
            #expect(compacted.conversations.map(\.id) == [second.id])
        }

        @Test
        func `Request draft body survives eviction restart and recovery`() throws {
            let fixture = makeFixture(maximumCachedConversationBodies: 1)
            let requestOwner = makeConversation(id: UUID())
            let newest = makeConversation(id: UUID())
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 1,
                    conversations: [requestOwner],
                    authoritativeConversationIDs: [requestOwner.id]
                )
            )
            var draft = try #require(fixture.store.conversations.first { $0.id == requestOwner.id })
            draft.messages.append(makeMessage(role: .assistant, content: "Partial response"))
            #expect(fixture.store.syncDraft(draft))

            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [newest],
                    authoritativeConversationIDs: [requestOwner.id, newest.id]
                )
            )

            #expect(fixture.store.conversation(for: requestOwner.id)?.messages.last?.content == "Partial response")
            #expect(fixture.store.conversation(for: newest.id) == nil)
            #expect(try persistedFixtureState(in: fixture).conversations.map(\.id) == [requestOwner.id])

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                maximumCachedConversationBodies: 1,
                mutationEnqueuer: { _ in }
            )
            #expect(restarted.conversation(for: requestOwner.id)?.messages.last?.content == "Partial response")
            #expect(restarted.pendingMutationsForSync.first?.conversationID == requestOwner.id)
        }

        @Test
        func `Outbox coalesces local operations and acknowledgement removes only covered revisions`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(title: "Original", model: "model-a"))
            fixture.store.addMessage(makeMessage(role: .user, content: "Prompt"), to: conversation.id)
            fixture.store.renameConversation(conversation.id, newTitle: "Renamed")
            fixture.store.updateModel("model-b", for: conversation.id)

            let pending = try #require(fixture.store.pendingMutationsForSync.first)
            #expect(fixture.store.pendingMutationsForSync.count == 1)
            #expect(pending.revision == 4)
            #expect(pending.fields.contains(.create))
            #expect(pending.fields.contains(.messages))
            #expect(pending.fields.contains(.title))
            #expect(pending.fields.contains(.configuration))
            #expect(pending.conversation.title == "Renamed")
            #expect(pending.conversation.model == "model-b")
            #expect(pending.conversation.messages.isEmpty)
            #expect(pending.messageChanges.map(\.content) == ["Prompt"])
            #expect(pending.peerID == fixture.store.peerID)

            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 3)
            #expect(fixture.store.pendingMutationsForSync.count == 1)
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 4)
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
        }

        @Test
        func `Revision exhaustion preserves a message draft across restart coalescing and acknowledgement`() throws {
            let fixture = makeFixture()
            let peerID = UUID()
            let conversationID = UUID()
            var exhausted = makeConversation(
                id: conversationID,
                messages: [makeMessage(role: .user, content: "Existing")]
            )
            exhausted.title = "Exhausted"
            exhausted.watchRevision = .max
            let existingMutation = WatchConversationMutation(
                peerID: peerID,
                revision: .max,
                conversation: exhausted,
                fields: [.title]
            )
            let coverage = WatchMutationDeliveryCoverage(titleRevision: .max)
            try persistFixtureState(
                peerID: peerID,
                conversations: [exhausted],
                pendingMutations: [existingMutation],
                legacyDeliveryCoverage: [conversationID: coverage],
                in: fixture
            )
            let candidate = makeMessage(role: .user, content: "Preserve me")

            let accepted = fixture.store.addMessage(candidate, to: conversationID)

            #expect(!accepted)
            #expect(fixture.store.peerID == peerID)
            #expect(fixture.store.pendingMutationsForSync == [existingMutation])
            #expect(fixture.store.durableLegacyDeliveryCoverage(for: conversationID) == coverage)
            #expect(fixture.store.conversation(for: conversationID)?.messages.map(\.content) == [
                "Existing",
                "Preserve me"
            ])
            #expect(fixture.enqueued.isEmpty)

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(restarted.peerID == peerID)
            #expect(restarted.pendingMutationsForSync == [existingMutation])
            #expect(restarted.conversation(for: conversationID)?.messages.map(\.content) == [
                "Existing",
                "Preserve me"
            ])

            #expect(restarted.acknowledgeWatchRevision(
                conversationID: conversationID,
                revision: .max
            ))
            #expect(restarted.pendingMutationsForSync.isEmpty)
            #expect(restarted.finishDraft(conversationID: conversationID) == .persistenceFailed)
            #expect(restarted.peerID == peerID)
            #expect(restarted.pendingMutationsForSync.isEmpty)
            #expect(restarted.conversation(for: conversationID)?.messages.map(\.content) == [
                "Existing",
                "Preserve me"
            ])
        }

        @Test
        func `Revision exhaustion preserves title configuration and delete intents locally`() throws {
            let fixture = makeFixture()
            let peerID = UUID()
            var titled = makeConversation(id: UUID())
            titled.title = "Original title"
            titled.watchRevision = .max
            var configured = makeConversation(id: UUID())
            configured.model = "old-model"
            configured.watchRevision = .max
            var deleted = makeConversation(id: UUID())
            deleted.watchRevision = .max
            try persistFixtureState(
                peerID: peerID,
                conversations: [titled, configured, deleted],
                in: fixture
            )

            let renamed = fixture.store.renameConversation(titled.id, newTitle: "Deferred title")
            let changedModel = fixture.store.updateModel("deferred-model", for: configured.id)
            let removed = fixture.store.deleteConversation(deleted.id)

            #expect(!renamed)
            #expect(!changedModel)
            #expect(!removed)
            #expect(fixture.store.peerID == peerID)
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.store.conversation(for: titled.id)?.title == "Deferred title")
            #expect(fixture.store.conversation(for: configured.id)?.model == "deferred-model")
            #expect(fixture.store.conversation(for: deleted.id) == nil)
            #expect(fixture.enqueued.isEmpty)

            let restarted = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            let acknowledgedSnapshot = WatchSyncSnapshot(
                sourceID: UUID(),
                revision: 1,
                conversations: [titled, configured, deleted],
                authoritativeConversationIDs: [titled.id, configured.id, deleted.id],
                acknowledgedPeerID: peerID,
                acknowledgedWatchRevisions: [
                    titled.id: .max,
                    configured.id: .max,
                    deleted.id: .max
                ]
            )

            #expect(restarted.applySyncSnapshot(acknowledgedSnapshot) == .applied)
            #expect(restarted.peerID == peerID)
            #expect(restarted.pendingMutationsForSync.isEmpty)
            #expect(restarted.conversation(for: titled.id)?.title == "Deferred title")
            #expect(restarted.conversation(for: configured.id)?.model == "deferred-model")
            #expect(restarted.conversation(for: deleted.id) == nil)
        }

        @Test
        func `Offline message coalescing retains every explicit message delta`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            for index in 0 ..< 25 {
                fixture.store.addMessage(
                    makeMessage(role: .user, content: "offline-\(index)"),
                    to: conversation.id
                )
            }

            let pending = try #require(fixture.store.pendingMutationsForSync.first)

            #expect(pending.revision == 26)
            #expect(pending.messageChanges.count == 25)
            #expect(pending.messageChanges.map(\.content) == (0 ..< 25).map { "offline-\($0)" })
            let firstChange = try #require(pending.messageChanges.first)
            let lastChange = try #require(pending.messageChanges.last)
            #expect(pending.messageChangeRevisions[firstChange.id] == 2)
            #expect(pending.messageChangeRevisions[lastChange.id] == 26)
        }

        @Test
        func `Disjoint bounded legacy echoes cumulatively acknowledge a durable mutation`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            for index in 0 ..< 25 {
                fixture.store.addMessage(
                    makeMessage(role: .user, content: "offline-\(index)"),
                    to: conversation.id
                )
            }
            let firstMutation = try #require(fixture.store.pendingMutationsForSync.first)
            var firstEcho = try #require(fixture.store.conversation(for: conversation.id))
            firstEcho.messages = Array(firstEcho.messages.prefix(12))
            let firstReconciliation = WatchLegacyEchoReconciler.reconcile(
                firstMutation,
                echoedConversations: [firstEcho]
            )

            #expect(!firstReconciliation.canAcknowledgeMutation)
            #expect(fixture.store.markLegacyComponentsDelivered(
                firstReconciliation.matchedComponents,
                for: firstMutation
            ))

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            let reloadedMutation = try #require(reloaded.pendingMutationsForSync.first)
            let firstCoverage = try #require(reloaded.durableLegacyDeliveryCoverage(for: conversation.id))
            #expect(reloadedMutation.messageChanges(
                after: 0,
                coverage: firstCoverage
            ).count == 13)

            var secondEcho = try #require(reloaded.conversation(for: conversation.id))
            secondEcho.messages = Array(secondEcho.messages.suffix(13))
            let secondReconciliation = WatchLegacyEchoReconciler.reconcile(
                reloadedMutation,
                echoedConversations: [secondEcho]
            )
            #expect(!secondReconciliation.canAcknowledgeMutation)
            #expect(reloaded.markLegacyComponentsDelivered(
                secondReconciliation.matchedComponents,
                for: reloadedMutation
            ))

            #expect(WatchLegacyEchoReconciler.canAcknowledge(
                reloadedMutation,
                currentMatches: secondReconciliation.matchedComponents,
                durableCoverage: reloaded.durableLegacyDeliveryCoverage(for: conversation.id)
            ))
            #expect(reloaded.acknowledgeWatchRevision(
                conversationID: conversation.id,
                revision: reloadedMutation.revision
            ))
            #expect(reloaded.pendingMutationsForSync.isEmpty)
        }

        @Test
        func `counterpart reset clears durable legacy coverage across restart`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            let message = makeMessage(role: .user, content: "Pending counterpart delivery")
            #expect(fixture.store.addMessage(message, to: conversation.id))
            let mutation = try #require(fixture.store.pendingMutationsForSync.first)
            let component = WatchLegacyEchoComponent.message(
                id: message.id,
                revision: mutation.messageChangeRevisions[message.id] ?? mutation.revision
            )
            #expect(fixture.store.markLegacyComponentsDelivered([component], for: mutation))
            #expect(fixture.store.durableLegacyDeliveryCoverage(for: conversation.id) != nil)

            #expect(fixture.store.clearLegacyDeliveryCoverage())
            #expect(fixture.store.durableLegacyDeliveryCoverage(for: conversation.id) == nil)

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(reloaded.durableLegacyDeliveryCoverage(for: conversation.id) == nil)
            #expect(reloaded.pendingMutationsForSync == [mutation])
        }

        @Test
        func `Rejected counterpart reset restores legacy coverage and clears durably on retry`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            let message = makeMessage(role: .user, content: "Pending counterpart delivery")
            #expect(fixture.store.addMessage(message, to: conversation.id))
            let mutation = try #require(fixture.store.pendingMutationsForSync.first)
            let component = WatchLegacyEchoComponent.message(
                id: message.id,
                revision: mutation.messageChangeRevisions[message.id] ?? mutation.revision
            )
            #expect(fixture.store.markLegacyComponentsDelivered([component], for: mutation))
            let coverage = try #require(
                fixture.store.durableLegacyDeliveryCoverage(for: conversation.id)
            )
            fixture.allowsPersistence = false

            #expect(!fixture.store.clearLegacyDeliveryCoverage())
            #expect(fixture.store.durableLegacyDeliveryCoverage(for: conversation.id) == coverage)
            #expect(fixture.store.pendingMutationsForSync == [mutation])
            #expect(
                try persistedFixtureState(in: fixture).legacyDeliveryCoverage?[conversation.id] == coverage
            )

            let restartedAfterFailure = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(restartedAfterFailure.durableLegacyDeliveryCoverage(for: conversation.id) == coverage)
            #expect(restartedAfterFailure.pendingMutationsForSync == [mutation])

            fixture.allowsPersistence = true
            #expect(fixture.store.clearLegacyDeliveryCoverage())
            #expect(fixture.store.durableLegacyDeliveryCoverage(for: conversation.id) == nil)

            let restartedAfterRetry = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(restartedAfterRetry.durableLegacyDeliveryCoverage(for: conversation.id) == nil)
            #expect(restartedAfterRetry.pendingMutationsForSync == [mutation])
        }

        @Test
        func `Deletion is durable and emits a revisioned deletion mutation`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 1)

            fixture.store.deleteConversation(conversation.id)

            #expect(fixture.store.conversation(for: conversation.id) == nil)
            let deletion = try #require(fixture.store.pendingMutationsForSync.first)
            #expect(deletion.conversationID == conversation.id)
            #expect(deletion.revision == 2)
            #expect(deletion.fields.contains(.delete))
            #expect(fixture.enqueued.last == deletion)

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(reloaded.conversation(for: conversation.id) == nil)
            #expect(reloaded.pendingMutationsForSync == [deletion])
        }

        @Test
        func `Failed persistence does not publish or enqueue an undurable title mutation`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(title: "Original", model: "model"))
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 1)
            fixture.enqueued.removeAll()
            var publishedTitles: [[String]] = []
            let cancellable = fixture.store.$conversations.sink { conversations in
                publishedTitles.append(conversations.map(\.title))
            }
            defer { cancellable.cancel() }
            fixture.allowsPersistence = false

            let renamed = fixture.store.renameConversation(conversation.id, newTitle: "Undurable")

            #expect(renamed == false)
            #expect(publishedTitles == [["Original"]])
            #expect(fixture.store.conversation(for: conversation.id)?.title == "Original")
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.enqueued.isEmpty)

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(try #require(reloaded.conversation(for: conversation.id)).title == "Original")
        }

        @Test
        func `Failed message persistence does not publish the candidate message`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 1)
            fixture.enqueued.removeAll()
            var publishedMessageContents: [[String]] = []
            let cancellable = fixture.store.$conversations.sink { conversations in
                publishedMessageContents.append(conversations.first?.messages.map(\.content) ?? [])
            }
            defer { cancellable.cancel() }
            fixture.allowsPersistence = false

            let added = fixture.store.addMessage(
                makeMessage(role: .user, content: "Undurable"),
                to: conversation.id
            )

            #expect(added == false)
            #expect(publishedMessageContents == [[]])
            #expect(fixture.store.conversation(for: conversation.id)?.messages.isEmpty == true)
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.enqueued.isEmpty)
        }

        @Test
        func `Failed model persistence does not publish the candidate configuration`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model-a"))
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 1)
            fixture.enqueued.removeAll()
            var publishedModels: [[String]] = []
            let cancellable = fixture.store.$conversations.sink { conversations in
                publishedModels.append(conversations.map(\.model))
            }
            defer { cancellable.cancel() }
            fixture.allowsPersistence = false

            let updated = fixture.store.updateModel("model-b", for: conversation.id)

            #expect(updated == false)
            #expect(publishedModels == [["model-a"]])
            #expect(fixture.store.conversation(for: conversation.id)?.model == "model-a")
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.enqueued.isEmpty)
        }

        @Test
        func `Failed delete persistence publishes neither removal nor selection clearing`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(title: "Keep", model: "model"))
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 1)
            fixture.store.selectedConversationId = conversation.id
            fixture.enqueued.removeAll()
            var publishedConversationIDs: [[UUID]] = []
            var publishedSelections: [UUID?] = []
            let conversationsCancellable = fixture.store.$conversations.sink { conversations in
                publishedConversationIDs.append(conversations.map(\.id))
            }
            let selectionCancellable = fixture.store.$selectedConversationId.sink { selection in
                publishedSelections.append(selection)
            }
            defer {
                conversationsCancellable.cancel()
                selectionCancellable.cancel()
            }
            fixture.allowsPersistence = false

            let deleted = fixture.store.deleteConversation(conversation.id)

            #expect(deleted == false)
            #expect(publishedConversationIDs == [[conversation.id]])
            #expect(publishedSelections == [conversation.id])
            #expect(fixture.store.conversation(for: conversation.id)?.title == "Keep")
            #expect(fixture.store.selectedConversationId == conversation.id)
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.enqueued.isEmpty)
        }

        @Test
        func `Failed draft persistence does not publish the draft overlay`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 1)
            var publishedMessageContents: [[String]] = []
            let cancellable = fixture.store.$conversations.sink { conversations in
                publishedMessageContents.append(conversations.first?.messages.map(\.content) ?? [])
            }
            defer { cancellable.cancel() }
            fixture.allowsPersistence = false
            var draft = try #require(fixture.store.conversation(for: conversation.id))
            draft.messages.append(makeMessage(role: .assistant, content: "Undurable", model: "model"))

            let persisted = fixture.store.syncDraft(draft)

            #expect(persisted == false)
            #expect(publishedMessageContents == [[]])
            #expect(fixture.store.conversation(for: conversation.id)?.messages.isEmpty == true)
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
        }

        @Test
        func `Failed acknowledgement persistence does not publish the candidate revision`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            var publishedRevisions: [WatchSyncRevision] = []
            let cancellable = fixture.store.$conversations.sink { conversations in
                publishedRevisions.append(conversations.first?.watchRevision ?? 0)
            }
            defer { cancellable.cancel() }
            fixture.allowsPersistence = false

            let acknowledged = fixture.store.acknowledgeWatchRevision(
                conversationID: conversation.id,
                revision: 2
            )

            #expect(acknowledged == false)
            #expect(publishedRevisions == [1])
            #expect(fixture.store.pendingMutationsForSync.count == 1)
            #expect(fixture.store.pendingMutationsForSync.first?.revision == 1)
            #expect(fixture.store.conversation(for: conversation.id)?.watchRevision == 1)
        }

        @Test
        func `Echo-covered mutation retries failed local acknowledgement without retransmission`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(title: "A", model: "model"))
            #expect(fixture.store.acknowledgeWatchRevision(
                conversationID: conversation.id,
                revision: 1
            ))
            #expect(fixture.store.renameConversation(conversation.id, newTitle: "B"))
            let mutation = try #require(fixture.store.pendingMutationsForSync.first)
            #expect(fixture.store.markLegacyComponentsDelivered(
                [.title(revision: mutation.titleRevision ?? mutation.revision)],
                for: mutation
            ))
            let coverage = try #require(
                fixture.store.durableLegacyDeliveryCoverage(for: conversation.id)
            )
            #expect(WatchLegacyEchoReconciler.canAcknowledge(
                mutation,
                currentMatches: [.title(revision: mutation.titleRevision ?? mutation.revision)],
                durableCoverage: coverage
            ))
            let deliveryTracker = WatchLegacyDeliveryTracker(
                userDefaults: fixture.defaults,
                persistenceKey: "legacy-delivery"
            )
            deliveryTracker.confirm(
                WatchLegacyEchoComponent.title(revision: mutation.titleRevision ?? mutation.revision)
                    .deliveryUserInfo(for: mutation)
            )
            let suppressedSend = try WatchLegacyMutationSender.prepare(
                mutation,
                tracker: deliveryTracker
            )
            #expect(suppressedSend.componentIDs.isEmpty)
            #expect(suppressedSend.fullyRepresented)
            let transportEnqueueCount = fixture.enqueued.count
            let retryTracker = WatchLegacyAcknowledgementRetryTracker()
            retryTracker.retain(mutation)
            fixture.allowsPersistence = false

            let failed = retryTracker.retry { conversationID, revision in
                fixture.store.acknowledgeWatchRevision(
                    conversationID: conversationID,
                    revision: revision
                )
            }

            #expect(failed.isEmpty)
            #expect(retryTracker.contains(operationID: mutation.operationID))
            #expect(fixture.store.pendingMutationsForSync == [mutation])
            #expect(fixture.enqueued.count == transportEnqueueCount)

            fixture.allowsPersistence = true
            let succeeded = retryTracker.retry { conversationID, revision in
                fixture.store.acknowledgeWatchRevision(
                    conversationID: conversationID,
                    revision: revision
                )
            }

            #expect(succeeded.map(\.operationID) == [mutation.operationID])
            #expect(!retryTracker.contains(operationID: mutation.operationID))
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.enqueued.count == transportEnqueueCount)
        }

        @Test
        func `Failed conversation creation returns no phantom conversation`() {
            let fixture = makeFixture()
            fixture.allowsPersistence = false

            let conversation = fixture.store.createConversation(model: "model")

            #expect(conversation == nil)
            #expect(fixture.store.conversations.isEmpty)
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.enqueued.isEmpty)
        }

        @Test
        func `Failed draft promotion reports failure and keeps the durable draft retryable`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            #expect(fixture.store.acknowledgeWatchRevision(
                conversationID: conversation.id,
                revision: 1
            ))
            fixture.enqueued.removeAll()

            let assistant = makeMessage(role: .assistant, content: "Answer", model: "model")
            var draft = try #require(fixture.store.conversation(for: conversation.id))
            draft.messages.append(assistant)
            #expect(fixture.store.syncDraft(draft))
            fixture.allowsPersistence = false

            let failed = fixture.store.finishDraft(conversationID: conversation.id)

            #expect(failed == .persistenceFailed)
            #expect(fixture.store.conversation(for: conversation.id)?.messages == [assistant])
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
            #expect(fixture.enqueued.isEmpty)

            fixture.allowsPersistence = true
            let retried = fixture.store.finishDraft(conversationID: conversation.id)

            guard case let .promoted(promoted) = retried else {
                Issue.record("Expected the same durable draft to promote on retry")
                return
            }
            #expect(promoted.messages == [assistant])
            #expect(fixture.store.pendingMutationsForSync.flatMap(\.messageChanges) == [assistant])
            #expect(fixture.enqueued.count == 1)
        }

        @Test
        func `Adding a message while a draft exists preserves unique message identities`() throws {
            let fixture = makeFixture()
            let messageID = UUID()
            let original = WatchMessage(
                id: messageID,
                role: Message.Role.user.rawValue,
                content: "Original",
                timestamp: Date(timeIntervalSince1970: 10)
            )
            let conversation = makeConversation(messages: [original])
            #expect(fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation])) == .applied)

            let assistant = makeMessage(role: .assistant, content: "Draft", model: "model")
            var draft = try #require(fixture.store.conversation(for: conversation.id))
            draft.messages.append(assistant)
            #expect(fixture.store.syncDraft(draft))

            let replacement = WatchMessage(
                id: messageID,
                role: Message.Role.user.rawValue,
                content: "Replacement",
                timestamp: Date(timeIntervalSince1970: 20)
            )
            #expect(fixture.store.addMessage(replacement, to: conversation.id))

            let visible = try #require(fixture.store.conversation(for: conversation.id))
            #expect(visible.messages.map(\.id) == [messageID, assistant.id])
            #expect(visible.messages.first?.content == "Replacement")
            #expect(Set(visible.messages.map(\.id)).count == visible.messages.count)
        }

        @Test
        func `Finishing a draft syncs it once while discard restores committed state`() throws {
            let fixture = makeFixture()
            let conversation = try #require(fixture.store.createConversation(model: "model"))
            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 1)

            var draft = try #require(fixture.store.conversation(for: conversation.id))
            draft.messages.append(makeMessage(role: .assistant, content: "Partial", model: "model"))
            fixture.store.syncDraft(draft)
            #expect(fixture.store.pendingMutationsForSync.isEmpty)

            _ = fixture.store.finishDraft(conversationID: conversation.id)
            #expect(fixture.store.pendingMutationsForSync.count == 1)
            #expect(fixture.store.pendingMutationsForSync.first?.revision == 2)
            #expect(fixture.store.finishDraft(conversationID: conversation.id) == .noDraft)
            #expect(fixture.store.pendingMutationsForSync.count == 1)

            fixture.store.acknowledgeWatchRevision(conversationID: conversation.id, revision: 2)
            var discarded = try #require(fixture.store.conversation(for: conversation.id))
            discarded.messages.append(makeMessage(role: .assistant, content: "Discard me", model: "model"))
            fixture.store.syncDraft(discarded)
            fixture.store.discardDraft(conversationID: conversation.id)
            #expect(fixture.store.conversation(for: conversation.id)?.messages.last?.content == "Partial")
            #expect(fixture.store.pendingMutationsForSync.isEmpty)
        }

        @Test
        func `Draft finish preserves phone edits and deletions outside request ownership`() throws {
            let fixture = makeFixture()
            let edited = makeMessage(role: .user, content: "Original")
            let deleted = makeMessage(role: .user, content: "Delete remotely")
            let conversation = makeConversation(messages: [edited, deleted])
            fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation]))

            let assistant = makeMessage(role: .assistant, content: "Partial", model: "model")
            var draft = conversation
            draft.messages.append(assistant)
            fixture.store.syncDraft(draft)

            var phone = conversation
            phone.messages = [
                WatchMessage(
                    id: edited.id,
                    role: edited.role,
                    content: "Edited on phone",
                    timestamp: edited.timestamp,
                    model: edited.model
                )
            ]
            fixture.store.applySyncSnapshot(snapshot(revision: 2, conversations: [phone]))
            _ = fixture.store.finishDraft(conversationID: conversation.id)

            let finished = try #require(fixture.store.conversation(for: conversation.id))
            let pending = try #require(fixture.store.pendingMutationsForSync.first)
            #expect(finished.messages.map(\.id) == [edited.id, assistant.id])
            #expect(finished.messages.first?.content == "Edited on phone")
            #expect(pending.messageChanges == [assistant])
        }

        @Test
        func `Draft finish safely canonicalizes duplicate remote message identities`() throws {
            let fixture = makeFixture()
            let duplicateID = UUID()
            let older = WatchMessage(
                id: duplicateID,
                role: Message.Role.user.rawValue,
                content: "Older",
                timestamp: Date(timeIntervalSince1970: 10)
            )
            let newer = WatchMessage(
                id: duplicateID,
                role: Message.Role.user.rawValue,
                content: "Newer",
                timestamp: Date(timeIntervalSince1970: 20)
            )
            let conversation = makeConversation(messages: [older, newer])
            fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation]))
            let assistant = makeMessage(role: .assistant, content: "Answer", model: "model")
            var draft = try #require(fixture.store.conversation(for: conversation.id))
            draft.messages.append(assistant)
            fixture.store.syncDraft(draft)

            _ = fixture.store.finishDraft(conversationID: conversation.id)

            let finished = try #require(fixture.store.conversation(for: conversation.id))
            #expect(finished.messages.map(\.id) == [duplicateID, assistant.id])
            #expect(finished.messages.first?.content == "Newer")
        }

        @Test
        func `Snapshot publication canonicalizes duplicate message identities immediately`() throws {
            let fixture = makeFixture()
            let duplicateID = UUID()
            let older = WatchMessage(
                id: duplicateID,
                role: Message.Role.user.rawValue,
                content: "Older",
                timestamp: Date(timeIntervalSince1970: 10)
            )
            let newer = WatchMessage(
                id: duplicateID,
                role: Message.Role.user.rawValue,
                content: "Newer",
                timestamp: Date(timeIntervalSince1970: 20)
            )
            let conversation = makeConversation(messages: [older, newer])

            fixture.store.applySyncSnapshot(snapshot(revision: 1, conversations: [conversation]))

            let published = try #require(fixture.store.conversation(for: conversation.id))
            #expect(published.messages.map(\.id) == [duplicateID])
            #expect(published.messages.first?.content == "Newer")
        }
    }

    private struct PersistedFixtureState: Codable {
        var sourceID: UUID?
        var peerID: UUID?
        var lastSnapshotRevision: WatchSyncRevision
        var conversations: [WatchConversation]
        var pendingMutations: [WatchConversationMutation]
        var pendingDrafts: [WatchConversationDraft]
        var legacyDeliveryCoverage: [UUID: WatchMutationDeliveryCoverage]?
    }

    @MainActor
    private func persistedFixtureState(in fixture: StoreFixture) throws -> PersistedFixtureState {
        let data = try #require(fixture.defaults.data(forKey: fixture.key))
        return try JSONDecoder().decode(PersistedFixtureState.self, from: data)
    }

    @MainActor
    private func persistFixtureState(
        peerID: UUID,
        conversations: [WatchConversation],
        pendingMutations: [WatchConversationMutation] = [],
        pendingDrafts: [WatchConversationDraft] = [],
        legacyDeliveryCoverage: [UUID: WatchMutationDeliveryCoverage] = [:],
        in fixture: StoreFixture
    ) throws {
        let data = try JSONEncoder().encode(PersistedFixtureState(
            sourceID: nil,
            peerID: peerID,
            lastSnapshotRevision: 0,
            conversations: conversations,
            pendingMutations: pendingMutations,
            pendingDrafts: pendingDrafts,
            legacyDeliveryCoverage: legacyDeliveryCoverage
        ))
        fixture.defaults.set(data, forKey: fixture.key)
    }

    @MainActor
    private final class StoreFixture {
        let defaults: UserDefaults
        let key: String
        var enqueued: [WatchConversationMutation] = []
        var allowsPersistence = true
        private let maximumCachedConversationBodies: Int
        lazy var store = WatchConversationStore(
            userDefaults: defaults,
            persistenceKey: key,
            maximumCachedConversationBodies: maximumCachedConversationBodies,
            now: { Date(timeIntervalSince1970: 100) },
            persistenceWriter: { [weak self] data in
                guard let self, allowsPersistence else { return false }
                defaults.set(data, forKey: key)
                return true
            },
            mutationEnqueuer: { [weak self] mutation in self?.enqueued.append(mutation) }
        )

        init(maximumCachedConversationBodies: Int = 20) {
            self.maximumCachedConversationBodies = maximumCachedConversationBodies
            let suiteName = "WatchConversationStoreNativeTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            key = "state"
        }
    }

    @MainActor
    private func makeFixture(maximumCachedConversationBodies: Int = 20) -> StoreFixture {
        StoreFixture(maximumCachedConversationBodies: maximumCachedConversationBodies)
    }

    private func snapshot(
        revision: WatchSyncRevision,
        conversations: [WatchConversation]
    ) -> WatchSyncSnapshot {
        WatchSyncSnapshot(
            revision: revision,
            conversations: conversations,
            authoritativeConversationIDs: conversations.map(\.id)
        )
    }

    private func makeConversation(
        id: UUID = UUID(),
        messages: [WatchMessage] = []
    ) -> WatchConversation {
        let date = Date(timeIntervalSince1970: 10)
        return WatchConversation(
            id: id,
            title: "Synced",
            messages: messages,
            model: "model",
            updatedAt: date,
            createdAt: date,
            temperature: 0.25,
            resolvedSystemPrompt: "System prompt"
        )
    }

    private func makeMessage(
        role: Message.Role,
        content: String,
        model: String? = nil
    ) -> WatchMessage {
        WatchMessage(
            id: UUID(),
            role: role.rawValue,
            content: content,
            timestamp: Date(timeIntervalSince1970: 20),
            model: model
        )
    }

    // swiftlint:enable identifier_name

#endif
