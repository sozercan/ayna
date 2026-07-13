// swiftlint:disable file_length identifier_name type_body_length
@testable import Ayna
import Foundation
import Testing

@Suite("Watch sync protocol tests", .tags(.fast))
struct WatchSyncProtocolTests {
    @Test
    func `Mutation retry backoff is bounded and exponential`() {
        #expect(WatchMutationRetryBackoff.seconds(forAttempt: 0) == 5)
        #expect(WatchMutationRetryBackoff.seconds(forAttempt: 1) == 10)
        #expect(WatchMutationRetryBackoff.seconds(forAttempt: 2) == 20)
        #expect(WatchMutationRetryBackoff.seconds(forAttempt: 20) == 60)
    }

    @Test
    func `Model fallback keeps every model referenced by mirrored conversations`() {
        let models = WatchModelSyncSelection.models(
            selectedModel: "selected",
            availableModels: ["other-a", "other-b", "referenced-b"],
            referencedModels: ["referenced-a", "referenced-b"],
            limit: 2
        )

        #expect(models == ["selected", "referenced-a", "referenced-b"])
        #expect(WatchModelSyncSelection.selectableModels(
            selectedModel: "referenced-a",
            availableModels: ["other-a", "other-b", "referenced-b"],
            limit: 2
        ) == ["other-a", "other-b"])
    }

    @Test
    func `Long model identifiers remain exact through body build Codable and reconcile`() throws {
        let maximumModelCharacters = 16
        let model = "custom-provider/" + String(repeating: "long-model-segment-", count: 12)
        #expect(model.count > maximumModelCharacters)
        let message = Message(
            role: .assistant,
            content: "Response",
            model: model
        )
        let phone = Conversation(
            title: "Long model",
            messages: [message],
            model: model
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumModelCharacters = maximumModelCharacters

        let payload = try WatchSyncPayloadBuilder.build(
            conversations: [phone],
            snapshotRevision: 1,
            configuration: configuration
        )
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: payload.data)
        let body = try #require(decoded.conversations.first)
        let reconciled = try #require(
            WatchSnapshotReconciler.reconcile(decoded, with: WatchSyncLocalState())
                .state.conversations.first
        )
        let settingsByModel = [model: "exact-settings"]

        #expect(body.model == model)
        #expect(body.messages.first?.model == model)
        #expect(settingsByModel[body.model] == "exact-settings")
        #expect(reconciled.model == model)
        #expect(reconciled.messages.first?.model == model)
        #expect(settingsByModel[reconciled.model] == "exact-settings")
    }

    @Test
    func `Long model identifiers remain exact through compact configuration build Codable and reconcile`() throws {
        let maximumModelCharacters = 16
        let model = "custom-provider/" + String(repeating: "configuration-segment-", count: 12)
        #expect(model.count > maximumModelCharacters)
        let phone = Conversation(
            title: "Manifest only",
            model: model,
            temperature: 0.25
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumModelCharacters = maximumModelCharacters

        let payload = try WatchSyncPayloadBuilder.build(
            conversations: [phone],
            snapshotRevision: 1,
            configuration: configuration
        )
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: payload.data)
        let compactConfiguration = try #require(decoded.conversationConfigurations.first)
        let retainedMessage = WatchMessage(from: Message(role: .user, content: "Keep me"))
        let retained = WatchConversation(
            id: phone.id,
            title: phone.title,
            messages: [retainedMessage],
            model: "old-model",
            updatedAt: phone.updatedAt,
            createdAt: phone.createdAt
        )
        let state = WatchSyncLocalState(conversations: [retained])
        let reconciled = try #require(
            WatchSnapshotReconciler.reconcile(decoded, with: state)
                .state.conversations.first
        )
        let settingsByModel = [model: "exact-settings"]

        #expect(decoded.conversations.isEmpty)
        #expect(compactConfiguration.model == model)
        #expect(settingsByModel[compactConfiguration.model] == "exact-settings")
        #expect(reconciled.model == model)
        #expect(reconciled.messages == [retainedMessage])
        #expect(settingsByModel[reconciled.model] == "exact-settings")
    }

    @Test
    func `Resolved prompt above the character threshold is delivered when the byte budget permits`() throws {
        let prompt = String(repeating: "lossless-prompt-segment-", count: 240)
        #expect(prompt.count > WatchSyncPayloadConfiguration.default.maximumSystemPromptCharacters)
        let phone = Conversation(
            title: "Oversized prompt",
            model: "test-model",
            systemPromptMode: .custom(prompt)
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumConversationConfigurations = 1
        configuration.byteBudget = 32000

        let payload = try WatchSyncPayloadBuilder.build(
            conversations: [phone],
            snapshotRevision: 1,
            configuration: configuration,
            resolvedSystemPrompt: { _ in prompt }
        )

        let compactConfiguration = try #require(payload.snapshot.conversationConfigurations.first)
        #expect(payload.data.count <= configuration.byteBudget)
        #expect(compactConfiguration.resolvedSystemPrompt == prompt)
    }

    @Test
    func `Oversized model record is deferred rather than truncated to fit the snapshot budget`() throws {
        let model = "custom-provider/" + String(repeating: "oversized-model-segment-", count: 200)
        let phone = Conversation(title: "Oversized model", model: model)
        let deferredSnapshot = WatchSyncSnapshot(
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: [],
            authoritativeConversationIDsAreComplete: false,
            conversationConfigurations: [],
            conversationConfigurationsAreComplete: false
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumModelCharacters = 8
        configuration.byteBudget = try WatchSyncPayloadBuilder.encode(deferredSnapshot).count

        let payload = try WatchSyncPayloadBuilder.build(
            conversations: [phone],
            snapshotRevision: 1,
            configuration: configuration
        )

        #expect(payload.data.count <= configuration.byteBudget)
        #expect(payload.snapshot == deferredSnapshot)
        #expect(payload.snapshot.conversations.isEmpty)
        #expect(payload.snapshot.conversationConfigurations.isEmpty)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `Oversized prompt gate clears stale state and a later page cycle converges losslessly`() throws {
        let oversizedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000301"))
        let laterID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000302"))
        let peerID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000304"))
        let sourceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000305"))
        let oversizedPrompt = String(repeating: "lossless-prompt-segment-", count: 260)
        let oversized = Conversation(
            id: oversizedID,
            title: "Oversized",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 30),
            model: "oversized-model",
            systemPromptMode: .custom(oversizedPrompt)
        )
        let later = Conversation(
            id: laterID,
            title: "Later",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20),
            model: "later-model",
            temperature: 0.25
        )
        let state = PhoneWatchSyncState(
            peerID: peerID,
            conversations: [later, oversized]
        )
        let availabilityGate = WatchConversationRequestConfiguration(
            id: oversizedID,
            model: oversized.model,
            temperature: oversized.temperature,
            resolvedSystemPrompt: nil
        )
        let laterConfiguration = WatchConversationRequestConfiguration(
            id: laterID,
            model: later.model,
            temperature: later.temperature,
            resolvedSystemPrompt: nil
        )
        let firstExpectedSnapshot = WatchSyncSnapshot(
            snapshotRevision: 10,
            sourceID: sourceID,
            paginationCursor: 0,
            conversations: [],
            authoritativeConversationIDs: [oversizedID, laterID],
            authoritativeConversationIDsAreComplete: true,
            conversationConfigurations: [availabilityGate],
            conversationConfigurationsAreComplete: false,
            acknowledgedPeerID: peerID
        )
        let secondExpectedSnapshot = WatchSyncSnapshot(
            snapshotRevision: 11,
            sourceID: sourceID,
            paginationCursor: 1,
            conversations: [],
            authoritativeConversationIDs: [],
            authoritativeConversationIDsAreComplete: false,
            conversationConfigurations: [laterConfiguration],
            conversationConfigurationsAreComplete: false,
            acknowledgedPeerID: peerID
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumManifestConversationIDs = 2
        configuration.maximumConversationConfigurations = 1
        configuration.maximumAcknowledgements = 0
        configuration.maximumTombstones = 0
        configuration.maximumSystemPromptCharacters = 8
        configuration.byteBudget = try max(
            WatchSyncPayloadBuilder.encode(firstExpectedSnapshot).count,
            WatchSyncPayloadBuilder.encode(secondExpectedSnapshot).count
        )
        let cycleID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000306"))
        let promptResolver: (Conversation) -> String? = { conversation in
            conversation.id == oversizedID ? oversizedPrompt : nil
        }

        let first = try WatchSyncPayloadBuilder.buildPageCycle(
            state: state,
            sourceID: sourceID,
            snapshotRevision: 10,
            cycleID: cycleID,
            cursor: .initial,
            configuration: configuration,
            resolvedSystemPrompt: promptResolver
        )
        let secondCursor = try #require(first.metadata.nextCursor)
        let second = try WatchSyncPayloadBuilder.buildPageCycle(
            state: state,
            sourceID: sourceID,
            snapshotRevision: 11,
            cycleID: cycleID,
            cursor: secondCursor,
            configuration: configuration,
            resolvedSystemPrompt: promptResolver
        )

        #expect(first.data.count <= configuration.byteBudget)
        #expect(first.snapshot == firstExpectedSnapshot)
        #expect(first.metadata.configurations == WatchSyncPageSection(
            offset: 0,
            itemCount: 1,
            totalCount: 2,
            containsUnavailablePromptGate: true
        ))
        #expect(!first.metadata.configurations.isLossless)
        #expect(secondCursor == WatchSyncPageCycleCursor(
            pageIndex: 1,
            manifestOffset: 2,
            configurationOffset: 1,
            tombstoneOffset: 0,
            precedingConfigurationsAreLossless: false
        ))
        #expect(second.data.count <= configuration.byteBudget)
        #expect(second.snapshot == secondExpectedSnapshot)
        #expect(second.metadata.nextCursor == nil)
        #expect(!second.metadata.modelMetadataCycleIsAuthoritative)

        let stale = WatchConversation(
            id: oversizedID,
            title: oversized.title,
            model: oversized.model,
            updatedAt: oversized.updatedAt,
            createdAt: oversized.createdAt,
            resolvedSystemPrompt: "stale instructions"
        )
        let gatedState = WatchSnapshotReconciler.reconcile(
            first.snapshot,
            with: WatchSyncLocalState(
                sourceID: sourceID,
                peerID: peerID,
                lastSnapshotRevision: 9,
                conversations: [stale]
            )
        ).state
        #expect(gatedState.conversations.first?.resolvedSystemPrompt == nil)

        configuration.byteBudget = 32000
        let retried = try WatchSyncPayloadBuilder.buildPageCycle(
            state: state,
            sourceID: sourceID,
            snapshotRevision: 12,
            cycleID: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000307")),
            cursor: .initial,
            configuration: configuration,
            resolvedSystemPrompt: promptResolver
        )
        let retriedConfiguration = try #require(retried.snapshot.conversationConfigurations.first)
        let convergedState = WatchSnapshotReconciler.reconcile(
            retried.snapshot,
            with: gatedState
        ).state

        #expect(retried.data.count <= configuration.byteBudget)
        #expect(retriedConfiguration.id == oversizedID)
        #expect(retriedConfiguration.resolvedSystemPrompt == oversizedPrompt)
        #expect(retried.metadata.configurations.isLossless)
        #expect(convergedState.conversations.first?.resolvedSystemPrompt == oversizedPrompt)
    }

    @Test
    @MainActor
    func `Default prompt fallbacks clear stale instructions and later converge without source loss`() throws {
        let suiteName = "WatchDefaultPromptGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let oversizedPrompt = String(repeating: "global-prompt-segment-", count: 260)
        defaults.set(oversizedPrompt, forKey: "globalSystemPrompt")
        defer {
            WatchDefaultSystemPromptPublicationGate.prepareForSnapshotBuild(defaults: defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let attempts = WatchApplicationContextAttempt.fallbacks(
            memoryFacts: WatchMemoryFactsPayload(data: nil, preservesAcrossFallbacks: false)
        )
        var retainedPrompt: String? = "stale instructions"
        for attempt in attempts {
            var configuration = WatchSyncPayloadConfiguration.default
            configuration.byteBudget = attempt.snapshotBytes
            #expect(WatchDefaultSystemPromptPublicationGate.maximumCharacters(
                for: configuration
            ) == attempt.maximumDefaultSystemPromptCharacters)
            #expect(WatchDefaultSystemPromptPublicationGate.installIfNeeded(
                configuration: configuration,
                defaults: defaults,
                schedulesAutomaticRestore: false
            ))

            let incoming = WatchPayloadStringLimiter.losslessRepresentation(
                defaults.string(forKey: "globalSystemPrompt") ?? "",
                maximumCharacters: attempt.maximumDefaultSystemPromptCharacters
            )
            #expect(incoming == "")
            retainedPrompt = WatchDefaultSystemPromptReducer.value(
                current: retainedPrompt,
                incoming: incoming
            )
            #expect(retainedPrompt == nil)
            #expect(defaults.persistentDomain(forName: suiteName)?["globalSystemPrompt"] as? String
                == oversizedPrompt)
        }

        WatchDefaultSystemPromptPublicationGate.prepareForSnapshotBuild(defaults: defaults)
        #expect(defaults.string(forKey: "globalSystemPrompt") == oversizedPrompt)
        defaults.set("replacement instructions", forKey: "globalSystemPrompt")
        var recoveryConfiguration = WatchSyncPayloadConfiguration.default
        recoveryConfiguration.byteBudget = attempts[0].snapshotBytes
        #expect(!WatchDefaultSystemPromptPublicationGate.installIfNeeded(
            configuration: recoveryConfiguration,
            defaults: defaults,
            schedulesAutomaticRestore: false
        ))
        let recoveredPrompt = WatchPayloadStringLimiter.losslessRepresentation(
            defaults.string(forKey: "globalSystemPrompt") ?? "",
            maximumCharacters: attempts[0].maximumDefaultSystemPromptCharacters
        )

        #expect(recoveredPrompt == "replacement instructions")
        #expect(WatchDefaultSystemPromptReducer.value(
            current: retainedPrompt,
            incoming: recoveredPrompt
        ) == "replacement instructions")
    }

    @Test
    func `Legacy page section decoding defaults prompt availability gates to absent`() throws {
        let data = Data(
            #"{"offset":0,"itemCount":1,"totalCount":1,"cursorAdvanceCount":1}"#.utf8
        )

        let section = try JSONDecoder().decode(WatchSyncPageSection.self, from: data)

        #expect(!section.containsUnavailablePromptGate)
        #expect(section.isLossless)
    }

    @Test
    func `Application context prompt fallback emits only lossless values or explicit clears`() {
        #expect(WatchPayloadStringLimiter.losslessRepresentation(
            "abc",
            maximumCharacters: 3
        ) == "abc")
        #expect(WatchPayloadStringLimiter.losslessRepresentation(
            "abcdef",
            maximumCharacters: 3
        ) == nil)
        #expect(WatchPayloadStringLimiter.losslessRepresentation(
            "",
            maximumCharacters: 0
        ) == "")
        #expect(WatchPayloadStringLimiter.losslessRepresentation(
            "a",
            maximumCharacters: 0
        ) == nil)
        #expect(WatchDefaultSystemPromptReducer.value(
            current: "retained",
            incoming: nil
        ) == "retained")
        #expect(WatchDefaultSystemPromptReducer.value(
            current: "retained",
            incoming: ""
        ) == nil)
        #expect(WatchDefaultSystemPromptReducer.value(
            current: "retained",
            incoming: "replacement"
        ) == "replacement")
    }

    @Test
    func `Revision decoder accepts only exact unsigned integers`() {
        #expect(WatchSyncValueDecoder.revision(UInt64.max) == UInt64.max)
        #expect(WatchSyncValueDecoder.revision(NSNumber(value: 42.0)) == 42)

        #expect(WatchSyncValueDecoder.revision(true) == nil)
        #expect(WatchSyncValueDecoder.revision(NSNumber(value: -1)) == nil)
        #expect(WatchSyncValueDecoder.revision(NSNumber(value: 1.5)) == nil)
        #expect(WatchSyncValueDecoder.revision(NSNumber(value: Double(UInt64.max))) == nil)
        #expect(WatchSyncValueDecoder.revision(NSDecimalNumber(string: "18446744073709551616")) == nil)
        #expect(WatchSyncValueDecoder.revision(NSDecimalNumber(string: "42.0000000000000000001")) == nil)
    }

    @Test
    func `Revision map decoder merges UUID case aliases at the maximum revision`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1"))
        let data = try JSONSerialization.data(withJSONObject: [
            id.uuidString: 2,
            id.uuidString.lowercased(): 7
        ], options: [.sortedKeys])

        let decoded = WatchSyncMetadataCodec.decodeRevisionMap(data)

        #expect(decoded == [id: 7])
    }

    @Test
    func `Peer revision map decoder merges peer and conversation UUID aliases`() throws {
        let peerID = try #require(UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEF01"))
        let conversationID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2"))
        let otherConversationID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE3"))
        let data = try JSONSerialization.data(withJSONObject: [
            peerID.uuidString: [
                conversationID.uuidString: 2,
                conversationID.uuidString.lowercased(): 5
            ],
            peerID.uuidString.lowercased(): [
                conversationID.uuidString: 7,
                otherConversationID.uuidString.lowercased(): 4
            ]
        ], options: [.sortedKeys])

        let decoded = WatchSyncMetadataCodec.decodePeerRevisionMaps(data)

        #expect(decoded == [peerID: [conversationID: 7, otherConversationID: 4]])
    }

    @Test
    func `Snapshot acknowledgement decoder merges UUID case aliases`() throws {
        let conversationID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE4"))
        let snapshot = WatchSyncSnapshot(
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: []
        )
        let encoded = try WatchSyncPayloadBuilder.encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["acknowledgedWatchRevisions"] = [
            conversationID.uuidString: 3,
            conversationID.uuidString.lowercased(): 9
        ]
        let aliased = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: aliased)

        #expect(decoded.acknowledgedWatchRevisions == [conversationID: 9])
    }

    @Test
    func `Mutation message revision decoder normalizes UUID aliases`() throws {
        let messageID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE5"))
        let message = WatchMessage(
            id: messageID,
            role: Message.Role.user.rawValue,
            content: "Changed",
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let mutation = WatchConversationMutation(
            revision: 10,
            conversation: makeWatchConversation(title: "Alias", revision: 10),
            fields: [.messages],
            messageChanges: [message]
        )
        let encoded = try WatchSyncPayloadBuilder.encodeMutation(mutation)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["messageChangeRevisions"] = [
            messageID.uuidString: 3,
            messageID.uuidString.lowercased(): 7
        ]
        let aliased = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(WatchConversationMutation.self, from: aliased)

        #expect(decoded.messageChangeRevisions == [messageID: 7])
        #expect(decoded.messageChanges(after: 6) == [message])
    }

    @Test
    @MainActor
    func `Legacy delivery tracker sends create and each incremental change once across restart`() throws {
        let suiteName = "WatchLegacyDeliveryTrackerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let key = "state"
        let conversation = makeWatchConversation(title: "Initial", revision: 1)
        let firstMessage = WatchMessage(from: Message(role: .user, content: "First"))
        let firstMutation = WatchConversationMutation(
            revision: 1,
            conversation: conversation,
            fields: [.create, .messages, .title],
            messageChanges: [firstMessage]
        )
        let tracker = WatchLegacyDeliveryTracker(userDefaults: defaults, persistenceKey: key)

        #expect(tracker.needsCreate(conversationID: conversation.id))
        #expect(tracker.pendingMessages(from: firstMutation) == [firstMessage])
        #expect(tracker.needsTitle(
            conversationID: conversation.id,
            title: "Initial",
            revision: 1
        ))
        #expect(tracker.configurationIsRepresented(by: firstMutation, createWillBeSent: true))
        tracker.confirm([
            WatchMessageKeys.conversationId: conversation.id.uuidString,
            WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentCreate,
            WatchMessageKeys.configurationRevision: NSNumber(value: 1)
        ])
        tracker.confirm([
            WatchMessageKeys.conversationId: conversation.id.uuidString,
            WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentMessage,
            WatchMessageKeys.messageId: firstMessage.id.uuidString,
            WatchMessageKeys.mutationRevision: NSNumber(value: 1)
        ])
        tracker.confirm([
            WatchMessageKeys.conversationId: conversation.id.uuidString,
            WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentTitle,
            WatchMessageKeys.title: "Initial",
            WatchMessageKeys.mutationRevision: NSNumber(value: 1)
        ])
        #expect(!tracker.needsCreate(conversationID: conversation.id))
        #expect(tracker.pendingMessages(from: firstMutation).isEmpty)
        #expect(!tracker.needsTitle(
            conversationID: conversation.id,
            title: "Initial",
            revision: 1
        ))

        let updatedMessage = WatchMessage(
            id: firstMessage.id,
            role: firstMessage.role,
            content: "Updated",
            timestamp: firstMessage.timestamp
        )
        let secondMessage = WatchMessage(from: Message(role: .assistant, content: "Second"))
        let secondMutation = WatchConversationMutation(
            revision: 2,
            conversation: conversation,
            fields: [.create, .messages, .title, .configuration],
            messageChanges: [updatedMessage, secondMessage]
        )
        #expect(tracker.pendingMessages(from: secondMutation) == [updatedMessage, secondMessage])
        #expect(!tracker.configurationIsRepresented(by: secondMutation, createWillBeSent: false))

        let reloaded = WatchLegacyDeliveryTracker(userDefaults: defaults, persistenceKey: key)
        #expect(!reloaded.needsCreate(conversationID: conversation.id))
        #expect(reloaded.pendingMessages(from: secondMutation) == [updatedMessage, secondMessage])
        #expect(reloaded.needsTitle(
            conversationID: conversation.id,
            title: "Initial",
            revision: 2
        ))
        #expect(reloaded.needsTitle(
            conversationID: conversation.id,
            title: "Renamed",
            revision: 2
        ))
    }

    @Test
    func `Revision metadata fences delayed legacy fallback`() {
        let peerID = UUID()
        let conversationID = UUID()
        let metadata = WatchLegacyMutationMetadata(message: [
            WatchMessageKeys.peerId: peerID.uuidString,
            WatchMessageKeys.mutationRevision: NSNumber(value: 4)
        ])

        #expect(metadata.isCovered(
            conversationID: conversationID,
            activePeerID: peerID,
            acknowledgements: [conversationID: 4]
        ))
        #expect(!metadata.isCovered(
            conversationID: conversationID,
            activePeerID: peerID,
            acknowledgements: [conversationID: 3]
        ))
    }

    @Test
    @MainActor
    func `Legacy operation completes only after every component succeeds`() {
        let mutation = WatchConversationMutation(
            revision: 3,
            conversation: makeWatchConversation(title: "Legacy", revision: 3),
            fields: [.create, .messages, .title]
        )
        let tracker = WatchLegacyOperationTracker()
        tracker.begin(
            mutation,
            result: WatchLegacySendResult(
                userInfos: ["create", "message", "title"].map {
                    [WatchMessageKeys.legacyComponentId: $0]
                },
                fullyRepresented: true
            )
        )

        #expect(tracker.completion(operationID: mutation.operationID, componentID: "create") == nil)
        #expect(tracker.completion(operationID: mutation.operationID, componentID: "message") == nil)
        let completion = tracker.completion(operationID: mutation.operationID, componentID: "title")
        #expect(completion?.conversationID == mutation.conversationID)
        #expect(completion?.revision == mutation.revision)
    }

    @Test
    @MainActor
    func `Mutation processing queue does not let a later callback overtake persistence`() async {
        let queue = WatchMutationProcessingQueue()
        let gate = TestGate()
        var events: [String] = []

        let newest = Task { @MainActor in
            await queue.enqueue {
                events.append("revision-2-start")
                await gate.wait()
                events.append("revision-2-finish")
            }
        }
        await Task.yield()
        let stale = Task { @MainActor in
            await queue.enqueue {
                events.append("revision-1")
            }
        }
        await Task.yield()

        #expect(events == ["revision-2-start"])
        gate.open()
        await newest.value
        await stale.value
        #expect(events == ["revision-2-start", "revision-2-finish", "revision-1"])
    }

    @Test
    @MainActor
    func `Session event queue drains receives before a later lifecycle event`() async {
        let queue = WatchSessionEventQueue()
        let gate = TestGate()
        var events: [String] = []

        queue.enqueue {
            events.append("receive-start")
            await gate.wait()
            events.append("receive-finish")
        }
        queue.enqueue {
            events.append("deactivate")
        }
        await Task.yield()

        #expect(events == ["receive-start"])
        gate.open()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while events.count < 3, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(events == ["receive-start", "receive-finish", "deactivate"])
    }

    @Test
    func `Phone state and reducer canonicalize duplicate conversation IDs using the newest state`() {
        let conversationID = UUID()
        let older = Conversation(
            id: conversationID,
            title: "Older",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 10),
            model: "older-model"
        )
        let newer = Conversation(
            id: conversationID,
            title: "Newer",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20),
            model: "newer-model"
        )

        let initialized = PhoneWatchSyncState(conversations: [older, newer])
        #expect(initialized.conversations.count == 1)
        #expect(initialized.conversations.first?.title == "Newer")

        var mutated = initialized
        mutated.conversations = [older, newer]
        let watchState = makeWatchConversation(
            id: conversationID,
            title: "Watch edit",
            revision: 1,
            updatedAt: 30
        )
        let reduced = PhoneWatchMutationReducer.reduce(
            mutated,
            mutation: WatchConversationMutation(
                revision: 1,
                conversation: watchState,
                fields: [.title]
            )
        )

        #expect(reduced.state.conversations.count == 1)
        #expect(reduced.state.conversations.first?.title == "Watch edit")
        #expect(reduced.state.conversations.first?.model == "newer-model")
    }

    @Test
    func `Watch local state canonicalizes duplicate IDs using revision before timestamp`() {
        let conversationID = UUID()
        let newerTimestamp = makeWatchConversation(
            id: conversationID,
            title: "Newer timestamp",
            revision: 4,
            updatedAt: 40
        )
        let newerRevision = makeWatchConversation(
            id: conversationID,
            title: "Newer revision",
            revision: 5,
            updatedAt: 20
        )

        let state = WatchSyncLocalState(conversations: [newerTimestamp, newerRevision])

        #expect(state.conversations.count == 1)
        #expect(state.conversations.first?.title == "Newer revision")
        #expect(state.conversations.first?.watchRevision == 5)
    }

    @Test
    func `Phone reducer preserves phone-only state and merges messages by stable ID`() throws {
        let conversationID = UUID()
        let existingMessageID = UUID()
        let newMessageID = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        var phone = Conversation(
            id: conversationID,
            title: "Phone title",
            messages: [
                Message(
                    id: existingMessageID,
                    role: .user,
                    content: "old",
                    timestamp: timestamp
                )
            ],
            createdAt: timestamp,
            updatedAt: timestamp,
            model: "phone-model",
            systemPromptMode: .custom("phone-only prompt"),
            temperature: 0.7
        )
        phone.pendingAutoSendPrompt = "pending phone prompt"

        var watch = WatchConversation(
            id: conversationID,
            title: "Watch title",
            messages: [
                WatchMessage(
                    id: existingMessageID,
                    role: Message.Role.user.rawValue,
                    content: "edited",
                    timestamp: timestamp
                ),
                WatchMessage(
                    id: newMessageID,
                    role: Message.Role.assistant.rawValue,
                    content: "answer",
                    timestamp: timestamp.addingTimeInterval(1)
                ),
                WatchMessage(
                    id: newMessageID,
                    role: Message.Role.assistant.rawValue,
                    content: "answer-final",
                    timestamp: timestamp.addingTimeInterval(1)
                )
            ],
            model: "watch-model",
            updatedAt: timestamp.addingTimeInterval(2),
            createdAt: timestamp,
            temperature: 0.2,
            resolvedSystemPrompt: "must not replace phone mode"
        )
        watch.watchRevision = 2
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: watch,
            fields: [.title, .messages],
            messageChanges: watch.messages
        )

        let reduction = PhoneWatchMutationReducer.reduce(
            PhoneWatchSyncState(conversations: [phone]),
            mutation: mutation
        )
        let merged = try #require(reduction.state.conversations.first)

        #expect(reduction.disposition == .applied)
        #expect(merged.title == "Watch title")
        #expect(merged.model == "phone-model")
        #expect(merged.temperature == 0.7)
        #expect(merged.systemPromptMode == .custom("phone-only prompt"))
        #expect(merged.pendingAutoSendPrompt == "pending phone prompt")
        #expect(merged.messages.map(\.id) == [existingMessageID, newMessageID])
        #expect(merged.messages[0].content == "edited")
        #expect(merged.messages[1].content == "answer-final")
        #expect(reduction.state.acknowledgedWatchRevisions[conversationID] == 2)
    }

    @Test
    func `Configuration mutation updates model and temperature without replacing phone prompt`() throws {
        let conversationID = UUID()
        var phone = Conversation(
            id: conversationID,
            title: "Phone",
            model: "old-model",
            systemPromptMode: .custom("phone prompt"),
            temperature: 0.4
        )
        phone.pendingAutoSendPrompt = "pending"
        let watch = WatchConversation(
            id: conversationID,
            title: "Phone",
            model: "new-model",
            updatedAt: Date(timeIntervalSince1970: 2),
            createdAt: Date(timeIntervalSince1970: 1),
            temperature: 0.9,
            resolvedSystemPrompt: "stale resolved prompt",
            watchRevision: 1
        )
        let mutation = WatchConversationMutation(
            revision: 1,
            conversation: watch,
            fields: [.configuration]
        )

        let reduction = PhoneWatchMutationReducer.reduce(
            PhoneWatchSyncState(conversations: [phone]),
            mutation: mutation
        )
        let updated = try #require(reduction.state.conversations.first)

        #expect(updated.model == "new-model")
        #expect(updated.temperature == 0.9)
        #expect(updated.systemPromptMode == .custom("phone prompt"))
        #expect(updated.pendingAutoSendPrompt == "pending")
    }

    @Test
    func `Message mutation preserves bounded phone history and appends only explicit Watch changes`() throws {
        let conversationID = UUID()
        let phoneMessageID = UUID()
        let watchMessageID = UUID()
        let originalContent = String(repeating: "phone-history-", count: 400)
        let truncatedContent = String(originalContent.prefix(4000))
        let timestamp = Date(timeIntervalSince1970: 100)
        let phone = Conversation(
            id: conversationID,
            title: "History",
            messages: [
                Message(
                    id: phoneMessageID,
                    role: .user,
                    content: originalContent,
                    timestamp: timestamp
                )
            ],
            createdAt: timestamp,
            updatedAt: timestamp,
            model: "model"
        )
        let newMessage = WatchMessage(
            id: watchMessageID,
            role: Message.Role.assistant.rawValue,
            content: "Watch answer",
            timestamp: timestamp.addingTimeInterval(1),
            model: "model"
        )
        let boundedWatchState = WatchConversation(
            id: conversationID,
            title: "History",
            messages: [
                WatchMessage(
                    id: phoneMessageID,
                    role: Message.Role.user.rawValue,
                    content: truncatedContent,
                    timestamp: timestamp
                ),
                newMessage
            ],
            model: "model",
            updatedAt: timestamp.addingTimeInterval(1),
            createdAt: timestamp,
            watchRevision: 1
        )
        let mutation = WatchConversationMutation(
            revision: 1,
            conversation: boundedWatchState,
            fields: [.messages],
            messageChanges: [newMessage]
        )

        let reduction = PhoneWatchMutationReducer.reduce(
            PhoneWatchSyncState(conversations: [phone]),
            mutation: mutation
        )
        let merged = try #require(reduction.state.conversations.first)

        #expect(merged.messages.map(\.id) == [phoneMessageID, watchMessageID])
        #expect(merged.messages.first?.content == originalContent)
        #expect(merged.messages.last?.content == "Watch answer")
    }

    @Test
    func `Acknowledged message delta is not replayed under a newer metadata revision`() throws {
        let conversationID = UUID()
        let messageID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1)
        let phone = Conversation(
            id: conversationID,
            title: "Phone",
            messages: [
                Message(
                    id: messageID,
                    role: .assistant,
                    content: "Edited on phone",
                    timestamp: timestamp
                )
            ],
            createdAt: timestamp,
            updatedAt: timestamp,
            model: "model"
        )
        let staleChange = WatchMessage(
            id: messageID,
            role: Message.Role.assistant.rawValue,
            content: "Already acknowledged",
            timestamp: timestamp,
            model: "model"
        )
        let watch = WatchConversation(
            id: conversationID,
            title: "Renamed on Watch",
            model: "model",
            updatedAt: timestamp.addingTimeInterval(1),
            createdAt: timestamp,
            watchRevision: 2
        )
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: watch,
            fields: [.title, .messages],
            messageChanges: [staleChange],
            messageChangeRevisions: [messageID: 1]
        )
        let state = PhoneWatchSyncState(
            conversations: [phone],
            acknowledgedWatchRevisions: [conversationID: 1]
        )

        let result = PhoneWatchMutationReducer.reduce(state, mutation: mutation)
        let merged = try #require(result.state.conversations.first)

        #expect(merged.title == "Renamed on Watch")
        #expect(merged.messages.first?.content == "Edited on phone")
        #expect(result.state.acknowledgedWatchRevisions[conversationID] == 2)
    }

    @Test
    func `Acknowledged title is not replayed under a newer configuration revision`() throws {
        let conversationID = UUID()
        let phone = Conversation(
            id: conversationID,
            title: "Edited on phone",
            model: "old-model"
        )
        let watch = WatchConversation(
            id: conversationID,
            title: "Already acknowledged",
            model: "new-model",
            updatedAt: Date(timeIntervalSince1970: 2),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 2
        )
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: watch,
            fields: [.title, .configuration],
            titleRevision: 1,
            configurationRevision: 2
        )
        let state = PhoneWatchSyncState(
            conversations: [phone],
            acknowledgedWatchRevisions: [conversationID: 1]
        )

        let result = PhoneWatchMutationReducer.reduce(state, mutation: mutation)
        let merged = try #require(result.state.conversations.first)

        #expect(merged.title == "Edited on phone")
        #expect(merged.model == "new-model")
    }

    @Test
    func `Locally delivered legacy mutation stays pending without overriding phone echo`() throws {
        let conversationID = UUID()
        let local = makeWatchConversation(id: conversationID, title: "Watch title", revision: 2)
        let pending = WatchConversationMutation(
            revision: 2,
            conversation: local,
            fields: [.title]
        )
        let remote = makeWatchConversation(id: conversationID, title: "Phone title", revision: 0)
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [local],
            pendingMutations: [pending],
            localDeliveryCoverage: [
                conversationID: WatchMutationDeliveryCoverage(titleRevision: 2)
            ]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [remote],
            authoritativeConversationIDs: [conversationID]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let visible = try #require(result.state.conversations.first)

        #expect(visible.title == "Phone title")
        #expect(result.state.pendingMutations == [pending])
        #expect(result.state.localDeliveryCoverage[conversationID]?.titleRevision == 2)
    }

    @Test
    func `Partial legacy coverage suppresses delivered fields but retains unsupported configuration`() throws {
        let conversationID = UUID()
        let messageID = UUID()
        let deliveredMessage = WatchMessage(
            id: messageID,
            role: Message.Role.user.rawValue,
            content: "Watch message",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let local = WatchConversation(
            id: conversationID,
            title: "Watch title",
            messages: [deliveredMessage],
            model: "watch-model",
            updatedAt: Date(timeIntervalSince1970: 2),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 2
        )
        let pending = WatchConversationMutation(
            revision: 2,
            conversation: local,
            fields: [.title, .messages, .configuration],
            titleRevision: 1,
            configurationRevision: 2,
            messageChanges: [deliveredMessage],
            messageChangeRevisions: [messageID: 1]
        )
        let phoneMessage = WatchMessage(
            id: messageID,
            role: Message.Role.user.rawValue,
            content: "Edited on phone",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let remote = WatchConversation(
            id: conversationID,
            title: "Phone title",
            messages: [phoneMessage],
            model: "phone-model",
            updatedAt: Date(timeIntervalSince1970: 3),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [local],
            pendingMutations: [pending],
            localDeliveryCoverage: [
                conversationID: WatchMutationDeliveryCoverage(
                    titleRevision: 1,
                    messageRevisions: [messageID: 1]
                )
            ]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [remote],
            authoritativeConversationIDs: [conversationID]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let visible = try #require(result.state.conversations.first)

        #expect(visible.title == "Phone title")
        #expect(visible.messages == [phoneMessage])
        #expect(visible.model == "watch-model")
        #expect(result.state.pendingMutations == [pending])
    }

    @Test
    func `Acknowledged create does not replay a stale resolved system prompt`() throws {
        let conversationID = UUID()
        let pendingMessage = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Pending message",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        var local = makeWatchConversation(
            id: conversationID,
            title: "Local",
            revision: 2
        )
        local.messages = [pendingMessage]
        local.resolvedSystemPrompt = "Stale create prompt"
        let pending = WatchConversationMutation(
            revision: 2,
            conversation: local,
            fields: [.create, .messages],
            createRevision: 1,
            messageChanges: [pendingMessage],
            messageChangeRevisions: [pendingMessage.id: 2]
        )
        var remote = makeWatchConversation(
            id: conversationID,
            title: "Phone",
            revision: 0
        )
        remote.resolvedSystemPrompt = "Phone-authoritative prompt"
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [local],
            pendingMutations: [pending]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [remote],
            authoritativeConversationIDs: [conversationID],
            acknowledgedWatchRevisions: [conversationID: 1]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let visible = try #require(result.state.conversations.first)

        #expect(visible.resolvedSystemPrompt == "Phone-authoritative prompt")
        #expect(visible.messages == [pendingMessage])
        #expect(result.state.pendingMutations == [pending])
    }

    @Test
    func `Fully delivered legacy mutation does not recreate a phone-deleted conversation`() {
        let local = makeWatchConversation(title: "Deleted on phone", revision: 2)
        let pending = WatchConversationMutation(
            revision: 2,
            conversation: local,
            fields: [.title],
            titleRevision: 2
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [local],
            pendingMutations: [pending],
            localDeliveryCoverage: [
                local.id: WatchMutationDeliveryCoverage(titleRevision: 2)
            ]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [],
            authoritativeConversationIDs: []
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)

        #expect(result.state.conversations.isEmpty)
        #expect(result.state.pendingMutations == [pending])
    }

    @Test
    func `Deletion creates a tombstone and later mutations cannot resurrect the ID`() {
        let conversation = makeWatchConversation(title: "Delete me", revision: 2)
        let phone = conversation.toConversation()
        let delete = WatchConversationMutation(
            revision: 3,
            conversation: conversation,
            fields: [.delete]
        )

        let deleted = PhoneWatchMutationReducer.reduce(
            PhoneWatchSyncState(conversations: [phone]),
            mutation: delete
        )
        let recreate = WatchConversationMutation(
            revision: 4,
            conversation: makeWatchConversation(
                id: conversation.id,
                title: "Resurrected",
                revision: 4
            ),
            fields: .fullState
        )
        let rejected = PhoneWatchMutationReducer.reduce(deleted.state, mutation: recreate)

        #expect(deleted.disposition == .deleted)
        #expect(deleted.state.conversations.isEmpty)
        #expect(deleted.state.tombstoneRevisions[conversation.id] == 3)
        #expect(rejected.disposition == .rejectedDeletedTombstone)
        #expect(rejected.state.conversations.isEmpty)
        #expect(rejected.state.acknowledgedWatchRevisions[conversation.id] == 4)
        #expect(rejected.state.tombstoneRevisions[conversation.id] == 3)
    }

    @Test
    func `Out-of-order mutations reject stale revisions and coalescing keeps latest full state`() throws {
        let id = UUID()
        let revisionOne = try WatchConversationMutation(
            operationID: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            revision: 1,
            conversation: makeWatchConversation(id: id, title: "one", revision: 1),
            fields: [.title]
        )
        var revisionTwoState = makeWatchConversation(id: id, title: "two", revision: 2)
        revisionTwoState.messages = [WatchMessage(from: Message(role: .user, content: "latest"))]
        let revisionTwo = try WatchConversationMutation(
            operationID: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            revision: 2,
            conversation: revisionTwoState,
            fields: [.messages],
            messageChanges: revisionTwoState.messages
        )

        let coalesced = try #require(WatchConversationMutation.coalesced([revisionTwo, revisionOne]).first)
        #expect(coalesced.revision == 2)
        #expect(coalesced.operationID == revisionTwo.operationID)
        #expect(coalesced.fields.contains(.title))
        #expect(coalesced.fields.contains(.messages))
        #expect(coalesced.conversation.title == "two")

        let initial = PhoneWatchSyncState(
            conversations: [makeWatchConversation(id: id, title: "base", revision: 0).toConversation()]
        )
        let newest = PhoneWatchMutationReducer.reduce(initial, mutation: revisionTwo)
        let stale = PhoneWatchMutationReducer.reduce(newest.state, mutation: revisionOne)

        #expect(stale.disposition == .rejectedStale)
        #expect(stale.state.acknowledgedWatchRevisions[id] == 2)
        #expect(stale.state.conversations.first?.messages.first?.content == "latest")
    }

    @Test
    func `Stale snapshots are ignored without clearing pending work`() {
        let local = makeWatchConversation(title: "Local", revision: 3)
        let mutation = WatchConversationMutation(
            revision: 4,
            conversation: local,
            fields: [.messages]
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 10,
            conversations: [local],
            pendingMutations: [mutation],
            pendingDrafts: [local.id: WatchConversationDraft(conversation: local, ownedMessageIDs: Set(local.messages.map(\.id)))]
        )
        let stale = WatchSyncSnapshot(
            revision: 9,
            conversations: [],
            authoritativeConversationIDs: []
        )

        let result = WatchSnapshotReconciler.reconcile(stale, with: state)

        #expect(result.disposition == .ignoredStale)
        #expect(result.state == state)
    }

    @Test
    func `New phone source applies revision one after the previous source reached a higher revision`() {
        let oldSourceID = UUID()
        let newSourceID = UUID()
        let local = makeWatchConversation(title: "Old source", revision: 3)
        let replacement = makeWatchConversation(id: local.id, title: "New source", revision: 0)
        let state = WatchSyncLocalState(
            sourceID: oldSourceID,
            lastSnapshotRevision: 100,
            conversations: [local]
        )
        let snapshot = WatchSyncSnapshot(
            sourceID: newSourceID,
            revision: 1,
            conversations: [replacement],
            authoritativeConversationIDs: [replacement.id]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)

        #expect(result.disposition == .applied)
        #expect(result.state.sourceID == newSourceID)
        #expect(result.state.lastSnapshotRevision == 1)
        #expect(result.state.conversations.first?.title == "New source")
    }

    @Test
    func `New phone source retains an incomplete old base until the manifest cycle completes`() throws {
        let oldSourceID = UUID()
        let newSourceID = UUID()
        let oldPhoneConversation = makeWatchConversation(title: "Old phone only", updatedAt: 30)
        let newPhoneConversation = makeWatchConversation(title: "New phone page", updatedAt: 20)
        let watchCreatedID = UUID()
        let pendingUserMessage = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Pending prompt",
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let pendingAssistantDraft = WatchMessage(
            id: UUID(),
            role: Message.Role.assistant.rawValue,
            content: "Pending response",
            timestamp: Date(timeIntervalSince1970: 11)
        )
        var watchCreated = makeWatchConversation(
            id: watchCreatedID,
            title: "Watch created",
            revision: 4,
            updatedAt: 11
        )
        watchCreated.messages = [pendingUserMessage, pendingAssistantDraft]
        let pendingCreate = WatchConversationMutation(
            revision: 4,
            conversation: watchCreated,
            fields: .fullState,
            messageChanges: [pendingUserMessage]
        )
        let state = WatchSyncLocalState(
            sourceID: oldSourceID,
            lastSnapshotRevision: 100,
            conversations: [oldPhoneConversation, watchCreated],
            pendingMutations: [pendingCreate],
            pendingDrafts: [
                watchCreatedID: WatchConversationDraft(
                    conversation: watchCreated,
                    ownedMessageIDs: [pendingAssistantDraft.id]
                )
            ]
        )
        let snapshot = WatchSyncSnapshot(
            sourceID: newSourceID,
            revision: 1,
            conversations: [newPhoneConversation],
            authoritativeConversationIDs: [newPhoneConversation.id],
            authoritativeConversationIDsAreComplete: false
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let created = try #require(
            result.state.conversations.first { $0.id == watchCreatedID }
        )

        #expect(result.disposition == .applied)
        #expect(Set(result.state.conversations.map(\.id)) == [
            oldPhoneConversation.id,
            newPhoneConversation.id,
            watchCreatedID
        ])
        #expect(created.messages == [pendingUserMessage, pendingAssistantDraft])
        #expect(result.state.pendingMutations == [pendingCreate])
        #expect(result.state.pendingDrafts[watchCreatedID]?.conversation == created)

        let completedSnapshot = WatchSyncSnapshot(
            sourceID: newSourceID,
            revision: 2,
            conversations: [newPhoneConversation],
            authoritativeConversationIDs: [newPhoneConversation.id],
            authoritativeConversationIDsAreComplete: true
        )
        let completed = WatchSnapshotReconciler.reconcile(completedSnapshot, with: result.state)
        #expect(Set(completed.state.conversations.map(\.id)) == [
            newPhoneConversation.id,
            watchCreatedID
        ])
    }

    @Test
    func `Source replacement preserves a manifest-listed cached body omitted by bounds`() throws {
        let oldSourceID = UUID()
        let newSourceID = UUID()
        var cached = makeWatchConversation(title: "Cached body", updatedAt: 20)
        cached.model = "old-model"
        let stale = makeWatchConversation(title: "Old phone only", updatedAt: 10)
        let state = WatchSyncLocalState(
            sourceID: oldSourceID,
            lastSnapshotRevision: 8,
            conversations: [cached, stale]
        )
        let snapshot = WatchSyncSnapshot(
            sourceID: newSourceID,
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: [cached.id],
            authoritativeConversationIDsAreComplete: true,
            conversationConfigurations: [
                WatchConversationRequestConfiguration(
                    id: cached.id,
                    model: "new-model",
                    temperature: 0.2,
                    resolvedSystemPrompt: "new prompt"
                )
            ],
            conversationConfigurationsAreComplete: true
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let retained = try #require(result.state.conversations.first)

        #expect(result.state.conversations.count == 1)
        #expect(retained.id == cached.id)
        #expect(retained.title == "Cached body")
        #expect(retained.model == "new-model")
        #expect(retained.temperature == 0.2)
        #expect(retained.resolvedSystemPrompt == "new prompt")
    }

    @Test
    func `Acknowledgements from another Watch peer never clear local mutations`() {
        let peerA = UUID()
        let peerB = UUID()
        let local = makeWatchConversation(title: "Peer B", revision: 3)
        let pending = WatchConversationMutation(
            peerID: peerB,
            revision: 3,
            conversation: local,
            fields: [.title]
        )
        let state = WatchSyncLocalState(
            peerID: peerB,
            lastSnapshotRevision: 1,
            conversations: [local],
            pendingMutations: [pending]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [local],
            authoritativeConversationIDs: [local.id],
            acknowledgedPeerID: peerA,
            acknowledgedWatchRevisions: [local.id: 99]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)

        #expect(result.state.pendingMutations == [pending])
    }

    @Test
    func `Mutation revisions are isolated by Watch peer`() {
        let peerA = UUID()
        let peerB = UUID()
        let conversation = makeWatchConversation(title: "Updated by B", revision: 3)
        let mutation = WatchConversationMutation(
            peerID: peerB,
            revision: 3,
            conversation: conversation,
            fields: [.title]
        )
        let state = PhoneWatchSyncState(
            peerID: peerA,
            conversations: [makeWatchConversation(id: conversation.id, title: "Phone", revision: 0).toConversation()],
            acknowledgedWatchRevisions: [conversation.id: 10]
        )

        let result = PhoneWatchMutationReducer.reduce(state, mutation: mutation)

        #expect(result.disposition == .applied)
        #expect(result.state.peerID == peerB)
        #expect(result.state.acknowledgedWatchRevisions[conversation.id] == 3)
        #expect(result.state.conversations.first?.title == "Updated by B")
    }

    @Test
    func `Future snapshot schema is ignored without mutating local state`() {
        let local = makeWatchConversation(title: "Local", revision: 1)
        let state = WatchSyncLocalState(lastSnapshotRevision: 4, conversations: [local])
        let snapshot = WatchSyncSnapshot(
            schemaVersion: WatchSyncSnapshot.currentSchemaVersion + 1,
            revision: 5,
            conversations: [],
            authoritativeConversationIDs: []
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)

        #expect(result.disposition == .ignoredUnsupportedSchema)
        #expect(result.state == state)
    }

    @Test
    func `Missing snapshot schema remains legacy v1 while nonpositive schemas are unsupported`() throws {
        let body = makeWatchConversation(title: "Legacy body")
        let snapshot = WatchSyncSnapshot(
            revision: 1,
            conversations: [body],
            authoritativeConversationIDs: [body.id]
        )
        let encoded = try WatchSyncPayloadBuilder.encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "schemaVersion",
            "paginationCursor",
            "authoritativeConversationIDsAreComplete",
            "conversationConfigurations",
            "conversationConfigurationsAreComplete",
            "authoritativeConversationIDs"
        ] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let legacy = try JSONDecoder().decode(WatchSyncSnapshot.self, from: legacyData)
        let state = WatchSyncLocalState()

        #expect(legacy.schemaVersion == 1)
        #expect(legacy.paginationCursor == 0)
        #expect(legacy.authoritativeConversationIDs == [body.id])
        #expect(legacy.authoritativeConversationIDsAreComplete)
        #expect(legacy.conversationConfigurations.isEmpty)
        #expect(!legacy.conversationConfigurationsAreComplete)
        #expect(WatchSnapshotReconciler.reconcile(legacy, with: state).disposition == .applied)

        for unsupportedVersion in [0, -1] {
            var unsupported = legacy
            unsupported.schemaVersion = unsupportedVersion
            let result = WatchSnapshotReconciler.reconcile(unsupported, with: state)
            #expect(result.disposition == .ignoredUnsupportedSchema)
            #expect(result.state == state)
        }
    }

    @Test
    func `Schema two snapshot defaults to a complete manifest and no configuration page`() throws {
        let body = makeWatchConversation(title: "Body")
        let manifestOnly = makeWatchConversation(title: "Manifest only")
        let snapshot = WatchSyncSnapshot(
            schemaVersion: 2,
            revision: 7,
            conversations: [body],
            authoritativeConversationIDs: [body.id, manifestOnly.id]
        )
        let encoded = try WatchSyncPayloadBuilder.encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "paginationCursor",
            "authoritativeConversationIDsAreComplete",
            "conversationConfigurations",
            "conversationConfigurationsAreComplete"
        ] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: legacyData)
        let localManifestOnly = makeWatchConversation(
            id: manifestOnly.id,
            title: "Retained local body"
        )
        let result = WatchSnapshotReconciler.reconcile(
            decoded,
            with: WatchSyncLocalState(conversations: [localManifestOnly])
        )

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.paginationCursor == 6)
        #expect(decoded.authoritativeConversationIDsAreComplete)
        #expect(decoded.conversationConfigurations.isEmpty)
        #expect(!decoded.conversationConfigurationsAreComplete)
        #expect(result.state.conversations.contains { $0.id == manifestOnly.id })
    }

    @Test
    func `Schema three without a completeness flag fails safe as an incomplete page`() throws {
        let included = makeWatchConversation(title: "Included")
        let omitted = makeWatchConversation(title: "Omitted")
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [included],
            authoritativeConversationIDs: [included.id],
            authoritativeConversationIDsAreComplete: false
        )
        let encoded = try WatchSyncPayloadBuilder.encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "authoritativeConversationIDsAreComplete")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: data)
        let result = WatchSnapshotReconciler.reconcile(
            decoded,
            with: WatchSyncLocalState(
                lastSnapshotRevision: 1,
                conversations: [included, omitted]
            )
        )

        #expect(!decoded.authoritativeConversationIDsAreComplete)
        #expect(result.state.conversations.contains { $0.id == omitted.id })
    }

    @Test
    func `Empty complete manifest still clears retained conversations`() {
        let local = makeWatchConversation(title: "Local")
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [],
            authoritativeConversationIDs: [],
            authoritativeConversationIDsAreComplete: true,
            conversationConfigurations: [],
            conversationConfigurationsAreComplete: true
        )

        let result = WatchSnapshotReconciler.reconcile(
            snapshot,
            with: WatchSyncLocalState(
                lastSnapshotRevision: 1,
                conversations: [local]
            )
        )

        #expect(result.state.conversations.isEmpty)
    }

    @Test
    func `Bounded body omission is not deletion when the full manifest contains the ID`() {
        let included = makeWatchConversation(title: "Included", updatedAt: 20)
        let omitted = makeWatchConversation(title: "Omitted body", updatedAt: 10)
        let remoteIncluded = makeWatchConversation(
            id: included.id,
            title: "Remote included",
            updatedAt: 30
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [remoteIncluded],
            authoritativeConversationIDs: [included.id, omitted.id]
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [included, omitted]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)

        #expect(result.state.conversations.count == 2)
        #expect(result.state.conversations.contains { $0.id == omitted.id && $0.title == "Omitted body" })
        #expect(result.state.conversations.contains { $0.id == included.id && $0.title == "Remote included" })
    }

    @Test
    func `Manifest-only custom configuration updates request settings without replacing messages`() throws {
        let body = Conversation(
            title: "Body",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 30),
            model: "body-model"
        )
        let manifestOnly = Conversation(
            title: "Manifest only",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20),
            model: "new-model",
            systemPromptMode: .custom("New custom prompt"),
            temperature: 0.2
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 1
        let payload = try WatchSyncPayloadBuilder.build(
            conversations: [manifestOnly, body],
            snapshotRevision: 2,
            configuration: configuration,
            resolvedSystemPrompt: { conversation in
                guard case let .custom(prompt) = conversation.systemPromptMode else { return nil }
                return prompt
            }
        )
        let retainedMessage = WatchMessage(from: Message(role: .user, content: "Keep me"))
        let retained = WatchConversation(
            id: manifestOnly.id,
            title: manifestOnly.title,
            messages: [retainedMessage],
            model: "old-model",
            updatedAt: manifestOnly.updatedAt,
            createdAt: manifestOnly.createdAt,
            temperature: 1.1,
            resolvedSystemPrompt: "Old prompt"
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [retained]
        )

        let result = WatchSnapshotReconciler.reconcile(payload.snapshot, with: state)
        let updated = try #require(result.state.conversations.first { $0.id == manifestOnly.id })

        #expect(payload.snapshot.conversations.map(\.id) == [body.id])
        #expect(payload.snapshot.conversationConfigurations.map(\.id) == [manifestOnly.id])
        #expect(payload.snapshot.conversationConfigurationsAreComplete)
        #expect(updated.model == "new-model")
        #expect(updated.temperature == 0.2)
        #expect(updated.resolvedSystemPrompt == "New custom prompt")
        #expect(updated.messages == [retainedMessage])
    }

    @Test
    func `Manifest-only inherited global prompt updates without replacing messages`() throws {
        let phone = Conversation(
            title: "Inherited prompt",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            model: "model",
            systemPromptMode: .inheritGlobal
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        let payload = try WatchSyncPayloadBuilder.build(
            conversations: [phone],
            snapshotRevision: 2,
            configuration: configuration,
            resolvedSystemPrompt: { _ in "New global prompt" }
        )
        let retainedMessage = WatchMessage(from: Message(role: .user, content: "Keep me"))
        let retained = WatchConversation(
            id: phone.id,
            title: phone.title,
            messages: [retainedMessage],
            model: phone.model,
            updatedAt: phone.updatedAt,
            createdAt: phone.createdAt,
            resolvedSystemPrompt: "Old global prompt"
        )
        let result = WatchSnapshotReconciler.reconcile(
            payload.snapshot,
            with: WatchSyncLocalState(
                lastSnapshotRevision: 1,
                conversations: [retained]
            )
        )
        let updated = try #require(result.state.conversations.first)

        #expect(updated.resolvedSystemPrompt == "New global prompt")
        #expect(updated.messages == [retainedMessage])
    }

    @Test
    func `Configuration pages eventually update every manifest-only conversation`() throws {
        let phoneConversations = (1 ... 3).map { index in
            Conversation(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000020\(index)")!,
                title: "Conversation \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(10 - index)),
                model: "new-model-\(index)",
                systemPromptMode: .custom("new-prompt-\(index)"),
                temperature: Double(index) / 10
            )
        }
        let retainedMessages = Dictionary(uniqueKeysWithValues: phoneConversations.map { conversation in
            (
                conversation.id,
                WatchMessage(from: Message(role: .user, content: "message-\(conversation.id)"))
            )
        })
        let localConversations = phoneConversations.map { conversation in
            WatchConversation(
                id: conversation.id,
                title: conversation.title,
                messages: [retainedMessages[conversation.id]!],
                model: "old-model",
                updatedAt: conversation.updatedAt,
                createdAt: conversation.createdAt,
                temperature: 1.0,
                resolvedSystemPrompt: "old-prompt"
            )
        }
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumConversationConfigurations = 1
        var state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: localConversations
        )
        var deliveredConfigurationIDs: Set<UUID> = []

        for cursor in 0 ..< 3 {
            let payload = try WatchSyncPayloadBuilder.build(
                conversations: phoneConversations,
                snapshotRevision: WatchSyncRevision(cursor + 2),
                paginationCursor: WatchSyncRevision(cursor),
                configuration: configuration,
                resolvedSystemPrompt: { conversation in
                    guard case let .custom(prompt) = conversation.systemPromptMode else { return nil }
                    return prompt
                }
            )
            deliveredConfigurationIDs.formUnion(payload.snapshot.conversationConfigurations.map(\.id))
            #expect(!payload.snapshot.conversationConfigurationsAreComplete)
            state = WatchSnapshotReconciler.reconcile(payload.snapshot, with: state).state
        }

        #expect(deliveredConfigurationIDs == Set(phoneConversations.map(\.id)))
        for phone in phoneConversations {
            let updated = try #require(state.conversations.first { $0.id == phone.id })
            #expect(updated.model == phone.model)
            #expect(updated.temperature == phone.temperature)
            let expectedPrompt: String? = if case let .custom(prompt) = phone.systemPromptMode {
                prompt
            } else {
                nil
            }
            #expect(updated.resolvedSystemPrompt == expectedPrompt)
            #expect(try updated.messages == [#require(retainedMessages[phone.id])])
        }
    }

    @Test
    func `Incomplete manifest preserves omitted conversations while tombstones still delete`() {
        let included = makeWatchConversation(title: "Included", updatedAt: 30)
        var omitted = makeWatchConversation(title: "Omitted", updatedAt: 20)
        let draftMessage = WatchMessage(from: Message(role: .assistant, content: "Draft"))
        omitted.messages = [draftMessage]
        let deleted = makeWatchConversation(title: "Deleted", updatedAt: 10)
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [included],
            authoritativeConversationIDs: [included.id],
            authoritativeConversationIDsAreComplete: false,
            tombstones: [WatchConversationTombstone(conversationID: deleted.id, revision: 1)]
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [included, omitted, deleted],
            pendingDrafts: [
                omitted.id: WatchConversationDraft(
                    conversation: omitted,
                    ownedMessageIDs: [draftMessage.id]
                )
            ]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let ids = Set(result.state.conversations.map(\.id))

        #expect(ids == [included.id, omitted.id])
        #expect(result.state.pendingDrafts[omitted.id]?.conversation.messages == [draftMessage])
    }

    @Test
    func `Bounded manifest preserves pending work until the phone acknowledges it`() {
        let acknowledged = makeWatchConversation(title: "Acknowledged")
        var pending = makeWatchConversation(title: "Pending", revision: 3)
        let pendingMessage = WatchMessage(from: Message(role: .user, content: "Pending message"))
        pending.messages = [pendingMessage]
        let drafted = makeWatchConversation(title: "Drafted")
        let clearedMutation = makeWatchConversation(title: "Already sent", revision: 2)
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [acknowledged, pending, drafted, clearedMutation],
            pendingMutations: [
                WatchConversationMutation(
                    revision: 3,
                    conversation: pending,
                    fields: [.messages],
                    messageChanges: [pendingMessage]
                ),
                WatchConversationMutation(
                    revision: 2,
                    conversation: clearedMutation,
                    fields: [.title]
                )
            ],
            pendingDrafts: [
                drafted.id: WatchConversationDraft(
                    conversation: drafted,
                    ownedMessageIDs: Set(drafted.messages.map(\.id))
                )
            ]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [],
            authoritativeConversationIDs: [],
            acknowledgedWatchRevisions: [clearedMutation.id: 2]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let ids = Set(result.state.conversations.map(\.id))

        #expect(result.disposition == .applied)
        #expect(ids == [pending.id])
        #expect(result.state.pendingMutations.map(\.conversationID) == [pending.id])
        #expect(result.state.pendingDrafts.isEmpty)

        let acknowledgedSnapshot = WatchSyncSnapshot(
            revision: 3,
            conversations: [],
            authoritativeConversationIDs: [],
            acknowledgedWatchRevisions: [pending.id: 3]
        )
        let acknowledgedResult = WatchSnapshotReconciler.reconcile(
            acknowledgedSnapshot,
            with: result.state
        )
        #expect(acknowledgedResult.state.conversations.isEmpty)
        #expect(acknowledgedResult.state.pendingMutations.isEmpty)
    }

    @Test
    func `Pending create replays explicit history when the snapshot omits its body`() throws {
        let conversation = makeWatchConversation(title: "Watch-created", revision: 2)
        let userMessage = WatchMessage(from: Message(role: .user, content: "Offline prompt"))
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: conversation,
            fields: [.create, .messages],
            messageChanges: [userMessage]
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            pendingMutations: [mutation]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [],
            authoritativeConversationIDs: []
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let replayed = try #require(result.state.conversations.first)

        #expect(replayed.id == conversation.id)
        #expect(replayed.messages == [userMessage])
    }

    @Test
    func `Local assistant draft overlays an echoed phone body with the same conversation ID`() throws {
        let conversationID = UUID()
        let user = WatchMessage(from: Message(role: .user, content: "prompt"))
        let assistant = WatchMessage(from: Message(role: .assistant, content: "partial"))
        let remote = WatchConversation(
            id: conversationID,
            title: "Phone",
            messages: [user],
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 2),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let draft = WatchConversation(
            id: conversationID,
            title: "Watch",
            messages: [user, assistant],
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 3),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [draft],
            pendingDrafts: [conversationID: WatchConversationDraft(conversation: draft, ownedMessageIDs: [assistant.id])]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [remote],
            authoritativeConversationIDs: [conversationID]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let merged = try #require(result.state.conversations.first)

        #expect(merged.title == "Phone")
        #expect(merged.messages.map(\.id) == [user.id, assistant.id])
        #expect(merged.messages.last?.content == "partial")
    }

    @Test
    func `Draft overlays only request-owned messages and preserves phone edits and deletions`() throws {
        let conversationID = UUID()
        let editedID = UUID()
        let deletedID = UUID()
        let assistantID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1)
        let remote = WatchConversation(
            id: conversationID,
            title: "Phone",
            messages: [
                WatchMessage(
                    id: editedID,
                    role: Message.Role.user.rawValue,
                    content: "phone edit",
                    timestamp: timestamp
                )
            ],
            model: "model",
            updatedAt: timestamp.addingTimeInterval(2),
            createdAt: timestamp
        )
        let staleDraft = WatchConversation(
            id: conversationID,
            title: "Phone",
            messages: [
                WatchMessage(
                    id: editedID,
                    role: Message.Role.user.rawValue,
                    content: "stale Watch copy",
                    timestamp: timestamp
                ),
                WatchMessage(
                    id: deletedID,
                    role: Message.Role.user.rawValue,
                    content: "deleted on phone",
                    timestamp: timestamp.addingTimeInterval(1)
                ),
                WatchMessage(
                    id: assistantID,
                    role: Message.Role.assistant.rawValue,
                    content: "streaming",
                    timestamp: timestamp.addingTimeInterval(2)
                )
            ],
            model: "model",
            updatedAt: timestamp.addingTimeInterval(3),
            createdAt: timestamp
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [staleDraft],
            pendingDrafts: [
                conversationID: WatchConversationDraft(
                    conversation: staleDraft,
                    ownedMessageIDs: [assistantID]
                )
            ]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [remote],
            authoritativeConversationIDs: [conversationID]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)
        let merged = try #require(result.state.conversations.first)

        #expect(merged.messages.map(\.id) == [editedID, assistantID])
        #expect(merged.messages.first?.content == "phone edit")
        #expect(!merged.messages.contains(where: { $0.id == deletedID }))
        #expect(result.state.pendingDrafts[conversationID]?.conversation == merged)
    }

    @Test
    func `Acknowledged create flag does not recreate a phone-deleted conversation`() {
        let conversationID = UUID()
        let pendingMessage = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Newer message",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        var local = makeWatchConversation(
            id: conversationID,
            title: "Stale create",
            revision: 2
        )
        local.messages = [pendingMessage]
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: local,
            fields: [.create, .messages],
            createRevision: 1,
            messageChanges: [pendingMessage],
            messageChangeRevisions: [pendingMessage.id: 2]
        )
        let state = PhoneWatchSyncState(
            conversations: [],
            acknowledgedWatchRevisions: [conversationID: 1]
        )

        let reduction = PhoneWatchMutationReducer.reduce(state, mutation: mutation)

        #expect(reduction.disposition == .rejectedMissingCreate)
        #expect(reduction.state.conversations.isEmpty)
        #expect(reduction.state.acknowledgedWatchRevisions[conversationID] == 2)
    }

    @Test
    func `Missing non-create mutation is acknowledged without resurrecting a phone deletion`() {
        let conversation = makeWatchConversation(title: "Original metadata", revision: 2)
        let messageMutation = WatchConversationMutation(
            revision: 2,
            conversation: conversation,
            fields: [.messages],
            messageChanges: conversation.messages
        )
        let olderCreate = WatchConversationMutation(
            revision: 1,
            conversation: makeWatchConversation(
                id: conversation.id,
                title: "stale",
                revision: 1
            ),
            fields: .fullState
        )

        let created = PhoneWatchMutationReducer.reduce(PhoneWatchSyncState(), mutation: messageMutation)
        let stale = PhoneWatchMutationReducer.reduce(created.state, mutation: olderCreate)

        #expect(created.disposition == .rejectedMissingCreate)
        #expect(created.state.conversations.isEmpty)
        #expect(created.state.acknowledgedWatchRevisions[conversation.id] == 2)
        #expect(stale.disposition == .rejectedStale)
        #expect(stale.state.conversations.isEmpty)
    }

    @Test
    func `Explicit tombstone revisions acknowledge and clear matching pending mutations`() {
        let local = makeWatchConversation(title: "Deleted", revision: 5)
        let pendingDelete = WatchConversationMutation(
            revision: 5,
            conversation: local,
            fields: [.delete]
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [local],
            pendingMutations: [pendingDelete]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [],
            authoritativeConversationIDs: [],
            tombstones: [WatchConversationTombstone(conversationID: local.id, revision: 5)]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)

        #expect(result.state.conversations.isEmpty)
        #expect(result.state.pendingMutations.isEmpty)
    }

    @Test
    func `Phone tombstone always defeats higher local revisions and drafts`() {
        let local = makeWatchConversation(title: "Deleted", revision: 99)
        let pending = WatchConversationMutation(
            revision: 99,
            conversation: local,
            fields: [.messages]
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [local],
            pendingMutations: [pending],
            pendingDrafts: [local.id: WatchConversationDraft(conversation: local, ownedMessageIDs: Set(local.messages.map(\.id)))]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [],
            authoritativeConversationIDs: [],
            tombstones: [WatchConversationTombstone(conversationID: local.id, revision: 2)]
        )

        let result = WatchSnapshotReconciler.reconcile(snapshot, with: state)

        #expect(result.state.conversations.isEmpty)
        #expect(result.state.pendingMutations.isEmpty)
        #expect(result.state.pendingDrafts.isEmpty)
    }

    @Test
    func `Tombstone pages are bounded deterministic and eventually deliver every deletion`() throws {
        let activeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000100"))
        let tombstoneIDs = try (1 ... 5).map { index in
            try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000020\(index)"))
        }
        let active = Conversation(
            id: activeID,
            title: "Active",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 10),
            model: "model"
        )
        let tombstones = Dictionary(uniqueKeysWithValues: tombstoneIDs.enumerated().map { index, id in
            (id, WatchSyncRevision(index + 1))
        })
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumManifestConversationIDs = 0
        configuration.maximumConversationConfigurations = 0
        configuration.maximumTombstones = 2
        configuration.byteBudget = 2000

        let payloads = try (1 ... 3).map { revision in
            try WatchSyncPayloadBuilder.build(
                conversations: [active],
                snapshotRevision: WatchSyncRevision(revision),
                tombstoneRevisions: tombstones,
                configuration: configuration
            )
        }
        let repeatedFirst = try WatchSyncPayloadBuilder.build(
            conversations: [active],
            snapshotRevision: 1,
            tombstoneRevisions: tombstones,
            configuration: configuration
        )

        #expect(payloads[0].data == repeatedFirst.data)
        #expect(payloads.map(\.snapshot.paginationCursor) == [0, 1, 2])
        #expect(payloads.allSatisfy { $0.data.count <= configuration.byteBudget })
        #expect(payloads.allSatisfy { !$0.snapshot.authoritativeConversationIDsAreComplete })
        #expect(payloads.allSatisfy { $0.snapshot.tombstones.count <= 2 })
        #expect(Set(payloads.flatMap(\.snapshot.tombstones).map(\.conversationID)) == Set(tombstoneIDs))

        var localState = WatchSyncLocalState(
            conversations: [
                makeWatchConversation(id: activeID, title: "Retained active"),
            ] + tombstoneIDs.map { makeWatchConversation(id: $0, title: "Deleted") }
        )
        for payload in payloads {
            localState = WatchSnapshotReconciler.reconcile(payload.snapshot, with: localState).state
        }

        #expect(localState.conversations.map(\.id) == [activeID])
    }

    @Test
    func `Byte-trimmed tombstone pages rotate every deletion into delivery`() throws {
        let activeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000300"))
        let tombstoneIDs = try (1 ... 5).map { index in
            try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000040\(index)"))
        }
        let active = Conversation(
            id: activeID,
            title: "Active",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 10),
            model: "model"
        )
        let tombstones = Dictionary(uniqueKeysWithValues: tombstoneIDs.map { ($0, WatchSyncRevision(1)) })
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumManifestConversationIDs = 0
        configuration.maximumConversationConfigurations = 0
        configuration.maximumTombstones = 2
        configuration.byteBudget = 10000
        let untrimmed = try WatchSyncPayloadBuilder.build(
            conversations: [active],
            snapshotRevision: 1,
            tombstoneRevisions: tombstones,
            configuration: configuration
        )
        let firstTombstone = try #require(untrimmed.snapshot.tombstones.first)
        var oneTombstone = untrimmed.snapshot
        oneTombstone.tombstones = [firstTombstone]
        configuration.byteBudget = try WatchSyncPayloadBuilder.encode(oneTombstone).count

        let payloads = try (1 ... 5).map { revision in
            try WatchSyncPayloadBuilder.build(
                conversations: [active],
                snapshotRevision: WatchSyncRevision(revision),
                tombstoneRevisions: tombstones,
                configuration: configuration
            )
        }

        #expect(payloads.allSatisfy { $0.data.count <= configuration.byteBudget })
        #expect(payloads.allSatisfy { $0.snapshot.tombstones.count == 1 })
        #expect(Set(payloads.flatMap(\.snapshot.tombstones).map(\.conversationID)) == Set(tombstoneIDs))
    }

    @Test
    func `Page cycle metadata exposes exact continuation offsets for every partial section`() throws {
        let conversations = (0 ..< 80).map { index in
            Conversation(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0003-0000-%012d",
                    index + 1
                ))!,
                title: "Conversation \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                model: "model-\(index)"
            )
        }
        let tombstones = Dictionary(uniqueKeysWithValues: (0 ..< 70).map { index in
            (
                UUID(uuidString: String(
                    format: "00000000-0000-0004-0000-%012d",
                    index + 1
                ))!,
                WatchSyncRevision(index + 1)
            )
        })
        let state = PhoneWatchSyncState(
            conversations: conversations,
            tombstoneRevisions: tombstones
        )
        let cycleID = UUID()
        let sourceID = UUID()
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumManifestConversationIDs = 32
        configuration.maximumConversationConfigurations = 32
        configuration.maximumTombstones = 32
        configuration.byteBudget = 30000

        let page = try WatchSyncPayloadBuilder.buildPageCycle(
            state: state,
            sourceID: sourceID,
            snapshotRevision: 10,
            cycleID: cycleID,
            cursor: .initial,
            configuration: configuration
        )

        #expect(page.snapshot.paginationCursor == 0)
        #expect(page.metadata.cycleID == cycleID)
        #expect(page.metadata.sourceID == sourceID)
        #expect(page.metadata.snapshotRevision == 10)
        #expect(page.metadata.isValid(for: page.snapshot))
        var staleSnapshot = page.snapshot
        staleSnapshot.revision += 1
        #expect(!page.metadata.isValid(for: staleSnapshot))
        #expect(page.metadata.manifest == WatchSyncPageSection(
            offset: 0,
            itemCount: 32,
            totalCount: 80
        ))
        #expect(page.metadata.configurations == WatchSyncPageSection(
            offset: 0,
            itemCount: 32,
            totalCount: 80
        ))
        #expect(page.metadata.tombstones == WatchSyncPageSection(
            offset: 0,
            itemCount: 32,
            totalCount: 70
        ))
        #expect(page.metadata.nextCursor == WatchSyncPageCycleCursor(
            pageIndex: 1,
            manifestOffset: 32,
            configurationOffset: 32,
            tombstoneOffset: 32
        ))
    }

    @Test
    func `Manifest pages are bounded deterministic and progress by cursor`() throws {
        let conversations = (1 ... 5).map { index in
            Conversation(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000010\(index)")!,
                title: "Conversation \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(10 - index)),
                model: "model"
            )
        }
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumManifestConversationIDs = 2
        configuration.byteBudget = 2000

        let first = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 10,
            paginationCursor: 0,
            configuration: configuration
        )
        let repeated = try WatchSyncPayloadBuilder.build(
            conversations: conversations.reversed(),
            snapshotRevision: 10,
            paginationCursor: 0,
            configuration: configuration
        )
        let second = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 11,
            paginationCursor: 1,
            configuration: configuration
        )
        let third = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 12,
            paginationCursor: 2,
            configuration: configuration
        )

        #expect(first.data == repeated.data)
        #expect(first.snapshot.paginationCursor == 0)
        #expect(first.snapshot.authoritativeConversationIDs == Array(conversations[0 ... 1].map(\.id)))
        #expect(second.snapshot.authoritativeConversationIDs == Array(conversations[2 ... 3].map(\.id)))
        #expect(third.snapshot.authoritativeConversationIDs == [conversations[4].id])
        #expect(!first.snapshot.authoritativeConversationIDsAreComplete)
        #expect(!second.snapshot.authoritativeConversationIDsAreComplete)
        #expect(!third.snapshot.authoritativeConversationIDsAreComplete)
        #expect(
            Set(
                first.snapshot.authoritativeConversationIDs +
                    second.snapshot.authoritativeConversationIDs +
                    third.snapshot.authoritativeConversationIDs
            ) == Set(conversations.map(\.id))
        )
    }

    @Test
    func `Body bounds do not change the selected manifest page`() throws {
        let conversations = (1 ... 5).map { index in
            Conversation(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000020\(index)")!,
                title: "Conversation \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(10 - index)),
                model: "model"
            )
        }
        let expectedManifestPage = Array(conversations[2 ... 3].map(\.id))
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumManifestConversationIDs = 2
        configuration.maximumConversationConfigurations = 0
        configuration.byteBudget = 10000

        for maximumBodies in [0, 1, conversations.count] {
            configuration.maximumConversations = maximumBodies
            let payload = try WatchSyncPayloadBuilder.build(
                conversations: conversations,
                snapshotRevision: 20,
                paginationCursor: 1,
                configuration: configuration
            )

            #expect(payload.snapshot.authoritativeConversationIDs == expectedManifestPage)
            #expect(!payload.snapshot.authoritativeConversationIDsAreComplete)
            #expect(payload.snapshot.conversations.count <= maximumBodies)
        }
    }

    @Test
    func `Realistic large history emits bounded progressing partial pages`() throws {
        let conversations = (0 ..< 2000).map { index in
            Conversation(
                id: UUID(),
                title: "Conversation \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(2000 - index)),
                model: "model"
            )
        }
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumConversationConfigurations = 1
        configuration.byteBudget = 1800

        let first = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 1,
            configuration: configuration
        )
        let second = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 2,
            configuration: configuration
        )

        #expect(first.data.count <= configuration.byteBudget)
        #expect(second.data.count <= configuration.byteBudget)
        #expect(!first.snapshot.authoritativeConversationIDsAreComplete)
        #expect(!second.snapshot.authoritativeConversationIDsAreComplete)
        #expect(!first.snapshot.authoritativeConversationIDs.isEmpty)
        #expect(!second.snapshot.authoritativeConversationIDs.isEmpty)
        #expect(first.snapshot.authoritativeConversationIDs != second.snapshot.authoritativeConversationIDs)
        #expect(first.snapshot.conversationConfigurations.count <= 1)
        #expect(second.snapshot.conversationConfigurations.count <= 1)
    }

    @Test
    func `Body limit preserves the complete manifest and an omitted pending draft`() throws {
        let newestID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
        let middleID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000102"))
        let omittedDraftID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000103"))
        let draftMessageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000201"))
        let createdAt = Date(timeIntervalSince1970: 1)
        let conversations = [
            Conversation(
                id: omittedDraftID,
                title: "Omitted draft",
                createdAt: createdAt,
                updatedAt: Date(timeIntervalSince1970: 10),
                model: "model"
            ),
            Conversation(
                id: newestID,
                title: "Newest",
                createdAt: createdAt,
                updatedAt: Date(timeIntervalSince1970: 30),
                model: "model"
            ),
            Conversation(
                id: middleID,
                title: "Middle",
                createdAt: createdAt,
                updatedAt: Date(timeIntervalSince1970: 20),
                model: "model"
            )
        ]
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 1
        configuration.maximumMessagesPerConversation = 0
        configuration.byteBudget = 10000

        let payload = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 2,
            configuration: configuration
        )
        let reorderedPayload = try WatchSyncPayloadBuilder.build(
            conversations: conversations.reversed(),
            snapshotRevision: 2,
            configuration: configuration
        )
        let expectedManifest = [newestID, middleID, omittedDraftID]

        #expect(payload.data == reorderedPayload.data)
        #expect(payload.snapshot.authoritativeConversationIDs == expectedManifest)
        #expect(payload.snapshot.authoritativeConversationIDsAreComplete)
        #expect(reorderedPayload.snapshot.authoritativeConversationIDsAreComplete)
        #expect(payload.snapshot.conversations.map(\.id) == [newestID])

        let draftMessage = WatchMessage(
            id: draftMessageID,
            role: Message.Role.assistant.rawValue,
            content: "Pending response",
            timestamp: Date(timeIntervalSince1970: 40)
        )
        let omittedDraft = WatchConversation(
            id: omittedDraftID,
            title: "Omitted draft",
            messages: [draftMessage],
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 40),
            createdAt: createdAt
        )
        let state = WatchSyncLocalState(
            lastSnapshotRevision: 1,
            conversations: [omittedDraft],
            pendingDrafts: [
                omittedDraftID: WatchConversationDraft(
                    conversation: omittedDraft,
                    ownedMessageIDs: [draftMessageID]
                )
            ]
        )

        let reconciled = WatchSnapshotReconciler.reconcile(payload.snapshot, with: state)

        #expect(reconciled.state.conversations.contains { $0.id == omittedDraftID })
        #expect(reconciled.state.pendingDrafts[omittedDraftID]?.conversation.messages == [draftMessage])

        let irreducibleSnapshot = WatchSyncSnapshot(
            revision: 2,
            conversations: [],
            authoritativeConversationIDs: expectedManifest
        )
        configuration.byteBudget = try WatchSyncPayloadBuilder.encode(irreducibleSnapshot).count - 1

        let paged = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 2,
            configuration: configuration
        )

        #expect(paged.data.count <= configuration.byteBudget)
        #expect(!paged.snapshot.authoritativeConversationIDsAreComplete)
        #expect(paged.snapshot.authoritativeConversationIDs.count < expectedManifest.count)
    }

    @Test
    func `Payload builder canonicalizes duplicate conversation IDs and keeps the newest state`() throws {
        let conversationID = UUID()
        let olderMessage = Message(
            role: .user,
            content: "Older message",
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let newerMessage = Message(
            role: .user,
            content: "Newer message",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let older = Conversation(
            id: conversationID,
            title: "Older",
            messages: [olderMessage],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 10),
            model: "older-model"
        )
        let newer = Conversation(
            id: conversationID,
            title: "Newer",
            messages: [newerMessage],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20),
            model: "newer-model"
        )

        let first = try WatchSyncPayloadBuilder.build(
            conversations: [older, newer],
            snapshotRevision: 1
        )
        let second = try WatchSyncPayloadBuilder.build(
            conversations: [newer, older],
            snapshotRevision: 1
        )

        #expect(first.data == second.data)
        #expect(first.snapshot.authoritativeConversationIDs == [conversationID])
        #expect(first.snapshot.conversations.count == 1)
        #expect(first.snapshot.conversations.first?.title == "Newer")
        #expect(first.snapshot.conversations.first?.model == "newer-model")
        #expect(first.snapshot.conversations.first?.messages.map(\.content) == ["Newer message"])
    }

    @Test
    func `Payload builder is deterministic bounded sorted and keeps the complete manifest`() throws {
        let base = Date(timeIntervalSince1970: 1000)
        let conversations = (0 ..< 3).map { index -> Conversation in
            let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!
            let call = MCPToolCall(
                id: String(repeating: "i", count: 500),
                toolName: String(repeating: "tool", count: 200),
                arguments: ["huge": AnyCodable(String(repeating: "argument", count: 1000))],
                result: String(repeating: "result", count: 1000),
                timestamp: base
            )
            let messages = (0 ..< 8).map { messageIndex in
                Message(
                    role: messageIndex.isMultiple(of: 2) ? .user : .assistant,
                    content: String(repeating: "content-\(index)-\(messageIndex)", count: 100),
                    timestamp: base.addingTimeInterval(Double(messageIndex)),
                    toolCalls: [call]
                )
            }
            return Conversation(
                id: id,
                title: String(repeating: "title-\(index)", count: 50),
                messages: messages,
                createdAt: base,
                updatedAt: base.addingTimeInterval(Double(index)),
                model: String(repeating: "model", count: 100),
                systemPromptMode: .custom(String(repeating: "prompt", count: 500))
            )
        }
        var configuration = WatchSyncPayloadConfiguration(
            byteBudget: 2200,
            maximumConversations: 2,
            maximumMessagesPerConversation: 5,
            maximumContentCharacters: 80
        )
        configuration.maximumTitleCharacters = 40
        configuration.maximumModelCharacters = 30
        configuration.maximumSystemPromptCharacters = 60
        configuration.maximumToolCallsPerMessage = 1
        configuration.maximumToolMetadataBytes = 180

        let first = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 9,
            acknowledgedWatchRevisions: [conversations[0].id: 4],
            configuration: configuration,
            resolvedSystemPrompt: { conversation in
                if case let .custom(prompt) = conversation.systemPromptMode {
                    return prompt
                }
                return nil
            }
        )
        let second = try WatchSyncPayloadBuilder.build(
            conversations: conversations.reversed(),
            snapshotRevision: 9,
            acknowledgedWatchRevisions: [conversations[0].id: 4],
            configuration: configuration,
            resolvedSystemPrompt: { conversation in
                if case let .custom(prompt) = conversation.systemPromptMode {
                    return prompt
                }
                return nil
            }
        )
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: first.data)

        #expect(first.data.count <= configuration.byteBudget)
        #expect(first.data == second.data)
        #expect(first.snapshot == decoded)
        let expectedManifest = conversations.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id)
        let bodyIDs = first.snapshot.conversations.map(\.id)
        #expect(first.snapshot.authoritativeConversationIDs == expectedManifest)
        #expect(first.snapshot.conversations.count <= configuration.maximumConversations)
        #expect(bodyIDs == Array(expectedManifest.prefix(bodyIDs.count)))
        #expect(first.snapshot.conversations.map(\.updatedAt) == first.snapshot.conversations.map(\.updatedAt).sorted(by: >))
        #expect(first.snapshot.conversations.allSatisfy { $0.title.count <= 40 })
        #expect(first.snapshot.conversations.flatMap(\.messages).allSatisfy { $0.content.count <= 80 })
        #expect(first.snapshot.conversations.flatMap(\.messages).flatMap { $0.toolCalls ?? [] }.allSatisfy {
            (try? JSONEncoder().encode($0).count) ?? .max <= 180
        })
    }

    @Test
    func `Large durable acknowledgement and tombstone history still produces a bounded snapshot`() throws {
        let conversations = (0 ..< 20).map { index in
            Conversation(
                id: UUID(),
                title: "Conversation \(index)",
                model: "model"
            )
        }
        let acknowledged = Dictionary(uniqueKeysWithValues: (0 ..< 512).map { index in
            (UUID(), WatchSyncRevision(index + 1))
        })
        let tombstones = Dictionary(uniqueKeysWithValues: (0 ..< 256).map { index in
            (UUID(), WatchSyncRevision(index + 1))
        })
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.byteBudget = 32000
        configuration.maximumConversations = 10
        let prioritizedAcknowledgementID = try #require(acknowledged.keys.first)

        let payload = try WatchSyncPayloadBuilder.build(
            conversations: conversations,
            snapshotRevision: 10001,
            acknowledgedWatchRevisions: acknowledged,
            prioritizedAcknowledgementIDs: [prioritizedAcknowledgementID],
            tombstoneRevisions: tombstones,
            configuration: configuration
        )

        #expect(payload.data.count <= configuration.byteBudget)
        #expect(Set(payload.snapshot.authoritativeConversationIDs) == Set(conversations.map(\.id)))
        #expect(payload.snapshot.conversations.count <= configuration.maximumConversations)
        #expect(payload.snapshot.acknowledgedWatchRevisions.count <= configuration.maximumAcknowledgements)
        #expect(payload.snapshot.acknowledgedWatchRevisions[prioritizedAcknowledgementID] != nil)
    }

    @Test
    func `Post-encoding trimming drops lowest-priority metadata first`() throws {
        let lowAcknowledgementID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1")
        )
        let prioritizedAcknowledgementID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2")
        )
        let oldestTombstoneID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE3")
        )
        let newestTombstoneID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE4")
        )
        let acknowledgements: [UUID: WatchSyncRevision] = [
            lowAcknowledgementID: 1,
            prioritizedAcknowledgementID: 9
        ]
        let tombstones: [UUID: WatchSyncRevision] = [
            oldestTombstoneID: 1,
            newestTombstoneID: 9
        ]
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumAcknowledgements = 2
        configuration.maximumTombstones = 2
        configuration.byteBudget = 10000
        let full = try WatchSyncPayloadBuilder.build(
            conversations: [],
            snapshotRevision: 10,
            acknowledgedWatchRevisions: acknowledgements,
            prioritizedAcknowledgementIDs: [prioritizedAcknowledgementID],
            tombstoneRevisions: tombstones,
            configuration: configuration
        )

        var afterLowAcknowledgement = full.snapshot
        afterLowAcknowledgement.acknowledgedWatchRevisions.removeValue(forKey: lowAcknowledgementID)
        configuration.byteBudget = try WatchSyncPayloadBuilder.encode(afterLowAcknowledgement).count
        let acknowledgementTrimmed = try WatchSyncPayloadBuilder.build(
            conversations: [],
            snapshotRevision: 10,
            acknowledgedWatchRevisions: acknowledgements,
            prioritizedAcknowledgementIDs: [prioritizedAcknowledgementID],
            tombstoneRevisions: tombstones,
            configuration: configuration
        )

        #expect(acknowledgementTrimmed.snapshot.acknowledgedWatchRevisions == [
            prioritizedAcknowledgementID: 9
        ])
        #expect(Set(acknowledgementTrimmed.snapshot.tombstones.map(\.conversationID)) == [
            oldestTombstoneID,
            newestTombstoneID
        ])

        var afterOldestTombstone = afterLowAcknowledgement
        afterOldestTombstone.tombstones.removeAll { $0.conversationID == oldestTombstoneID }
        configuration.byteBudget = try WatchSyncPayloadBuilder.encode(afterOldestTombstone).count
        let tombstoneTrimmed = try WatchSyncPayloadBuilder.build(
            conversations: [],
            snapshotRevision: 10,
            acknowledgedWatchRevisions: acknowledgements,
            prioritizedAcknowledgementIDs: [prioritizedAcknowledgementID],
            tombstoneRevisions: tombstones,
            configuration: configuration
        )

        #expect(tombstoneTrimmed.snapshot.acknowledgedWatchRevisions == [
            prioritizedAcknowledgementID: 9
        ])
        #expect(tombstoneTrimmed.snapshot.tombstones == [
            WatchConversationTombstone(conversationID: newestTombstoneID, revision: 9)
        ])
    }

    @Test
    func `Mutation payload preserves every offline message change`() throws {
        let conversation = makeWatchConversation(title: "Offline", revision: 25)
        let changes = (0 ..< 25).map { index in
            WatchMessage(
                id: UUID(),
                role: Message.Role.user.rawValue,
                content: "offline-\(index)",
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        let mutation = WatchConversationMutation(
            revision: 25,
            conversation: conversation,
            fields: [.messages],
            messageChanges: changes
        )

        let payload = try WatchSyncPayloadBuilder.buildMutation(mutation)
        let decoded = try JSONDecoder().decode(WatchConversationMutation.self, from: payload.data)

        #expect(decoded.messageChanges == changes)
        #expect(decoded.revision == 25)
    }

    @Test
    func `Oversized mutation is rejected without truncating durable changes`() throws {
        var conversation = makeWatchConversation(title: "Large mutation", revision: 7)
        conversation.messages = (0 ..< 10).map { index in
            WatchMessage(
                id: UUID(),
                role: Message.Role.assistant.rawValue,
                content: String(repeating: "payload-\(index)", count: 1000),
                timestamp: Date(timeIntervalSince1970: Double(index)),
                toolCalls: [MCPToolCall(
                    id: "tool-\(index)",
                    toolName: "lookup",
                    arguments: ["value": AnyCodable(String(repeating: "x", count: 5000))]
                )]
            )
        }
        let operationID = UUID()
        let mutation = WatchConversationMutation(
            operationID: operationID,
            revision: 7,
            conversation: conversation,
            fields: [.messages],
            messageChanges: conversation.messages
        )

        #expect(throws: WatchSyncPayloadBuilderError.self) {
            try WatchSyncPayloadBuilder.buildMutation(mutation, byteBudget: 4000)
        }
        #expect(mutation.operationID == operationID)
        #expect(mutation.messageChanges == conversation.messages)
    }

    @Test
    func `An explicitly empty manifest survives Codable round trip`() throws {
        let snapshot = WatchSyncSnapshot(
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: [],
            acknowledgedWatchRevisions: [:],
            tombstones: []
        )

        let data = try WatchSyncPayloadBuilder.encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: data)

        #expect(decoded.authoritativeConversationIDs.isEmpty)
        #expect(decoded.conversations.isEmpty)
    }
}

private func makeWatchConversation(
    id: UUID = UUID(),
    title: String,
    revision: WatchSyncRevision = 0,
    updatedAt: TimeInterval = 1
) -> WatchConversation {
    let date = Date(timeIntervalSince1970: updatedAt)
    return WatchConversation(
        id: id,
        title: title,
        messages: [],
        model: "model",
        updatedAt: date,
        createdAt: date,
        temperature: 0.7,
        watchRevision: revision
    )
}

@MainActor
private final class TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

// swiftlint:enable identifier_name type_body_length
