// swiftlint:disable file_length
@testable import Ayna
import Combine
import Foundation
import Testing

@Suite("Watch connectivity support tests", .tags(.fast))
// swiftlint:disable:next type_body_length
struct WatchConnectivitySupportTests {
    @Test
    func `memory facts are omitted from reduced contexts unless they represent an explicit clear`() {
        let facts = Data("facts".utf8)
        let explicitClear = Data("[]".utf8)

        let ordinary = WatchApplicationContextAttempt.fallbacks(
            memoryFacts: WatchMemoryFactsPayload(
                data: facts,
                preservesAcrossFallbacks: false
            )
        )
        let clearing = WatchApplicationContextAttempt.fallbacks(
            memoryFacts: WatchMemoryFactsPayload(
                data: explicitClear,
                preservesAcrossFallbacks: true
            )
        )
        let oversized = WatchApplicationContextAttempt.fallbacks(
            memoryFacts: WatchMemoryFactsPayload(
                data: nil,
                preservesAcrossFallbacks: false
            )
        )

        #expect(ordinary.map(\.facts) == [facts, nil, nil, nil])
        #expect(clearing.map(\.facts) == [explicitClear, explicitClear, explicitClear, explicitClear])
        #expect(oversized.allSatisfy { $0.facts == nil })
    }

    @Test
    func `retained default prompt persists across restart and explicit clear`() throws {
        let suiteName = "WatchDefaultSystemPromptPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        WatchDefaultSystemPromptPersistence.store("retained prompt", in: defaults)
        #expect(WatchDefaultSystemPromptPersistence.load(from: defaults) == "retained prompt")

        WatchDefaultSystemPromptPersistence.store(nil, in: defaults)
        #expect(WatchDefaultSystemPromptPersistence.load(from: defaults) == nil)
    }

    @Test
    func `legacy awaiting echo results require scheduled sync retry`() {
        let awaiting = WatchLegacySendResult(
            userInfos: [],
            awaitingEchoComponentIDs: ["message:1"],
            fullyRepresented: true
        )
        let settled = WatchLegacySendResult(
            userInfos: [],
            awaitingEchoComponentIDs: [],
            fullyRepresented: true
        )

        #expect(awaiting.requiresEchoRetry)
        #expect(!settled.requiresEchoRetry)
    }

    @Test
    func `invalid persisted revision rotates an otherwise valid source identity`() {
        let persistedSourceID = UUID()
        let replacementSourceID = UUID()
        let invalidRevisions: [Any?] = [
            nil,
            "12",
            true,
            NSNumber(value: -1),
            NSNumber(value: 1.5)
        ]

        for invalidRevision in invalidRevisions {
            let metadata = WatchSyncSourceMetadata.resolve(
                persistedSourceID: persistedSourceID.uuidString,
                persistedSnapshotRevision: invalidRevision,
                replacementSourceID: replacementSourceID
            )

            #expect(metadata.sourceID == replacementSourceID)
            #expect(metadata.snapshotRevision == 0)
        }
    }

    @Test
    func `matching application context echo covers every legacy mutation component`() {
        let message = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Durable prompt",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Durable title",
            messages: [message],
            model: "durable-model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10),
            temperature: 0.4,
            resolvedSystemPrompt: "Durable system prompt",
            watchRevision: 4
        )
        let mutation = WatchConversationMutation(
            revision: 4,
            conversation: conversation,
            fields: .fullState,
            createRevision: 1,
            titleRevision: 2,
            configurationRevision: 3,
            messageChanges: [message],
            messageChangeRevisions: [message.id: 4]
        )

        let reconciliation = WatchLegacyEchoReconciler.reconcile(
            mutation,
            echoedConversations: [conversation]
        )

        #expect(reconciliation.matchedComponents == [
            .create(revision: 1),
            .title(revision: 2),
            .configuration(revision: 3),
            .message(id: message.id, revision: 4)
        ])
        #expect(reconciliation.unsupportedFields.isEmpty)
        #expect(reconciliation.canAcknowledgeMutation)
    }

    @Test
    func `same ID placeholder echo does not confirm legacy create with mismatched configuration`() {
        let message = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Arrived before create",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Watch title",
            messages: [message],
            model: "watch-model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10),
            temperature: 0.3,
            resolvedSystemPrompt: "Watch prompt",
            watchRevision: 2
        )
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: conversation,
            fields: .fullState,
            createRevision: 1,
            titleRevision: 1,
            configurationRevision: 1,
            messageChanges: [message],
            messageChangeRevisions: [message.id: 2]
        )
        let placeholder = WatchConversation(
            id: conversation.id,
            title: conversation.title,
            messages: [message],
            model: "phone-placeholder-model",
            updatedAt: conversation.updatedAt,
            createdAt: message.timestamp,
            temperature: 0.7,
            resolvedSystemPrompt: nil,
            watchRevision: 0
        )

        let reconciliation = WatchLegacyEchoReconciler.reconcile(
            mutation,
            echoedConversations: [placeholder]
        )

        #expect(!reconciliation.matchedComponents.contains(.create(revision: 1)))
        #expect(reconciliation.matchedComponents.contains(.title(revision: 1)))
        #expect(reconciliation.matchedComponents.contains(.message(id: message.id, revision: 2)))
        #expect(!reconciliation.canAcknowledgeMutation)
    }

    @Test
    func `covered or unrelated legacy creates cannot overwrite existing conversations`() {
        let conversationID = UUID()
        let activePeerID = UUID()
        let coveredMetadata = WatchLegacyMutationMetadata(message: [
            WatchMessageKeys.peerId: activePeerID.uuidString,
            WatchMessageKeys.mutationRevision: NSNumber(value: 3)
        ])

        #expect(WatchLegacyCreateIngressResolver.action(
            metadata: coveredMetadata,
            conversationID: conversationID,
            activePeerID: activePeerID,
            acknowledgements: [conversationID: 3],
            conversationExists: true,
            isTrackedPlaceholder: true
        ) == .ignore)
        #expect(WatchLegacyCreateIngressResolver.action(
            metadata: WatchLegacyMutationMetadata(message: [:]),
            conversationID: conversationID,
            activePeerID: activePeerID,
            acknowledgements: [:],
            conversationExists: true,
            isTrackedPlaceholder: true
        ) == .repairPlaceholder)
        #expect(WatchLegacyCreateIngressResolver.action(
            metadata: WatchLegacyMutationMetadata(message: [:]),
            conversationID: conversationID,
            activePeerID: activePeerID,
            acknowledgements: [:],
            conversationExists: true,
            isTrackedPlaceholder: false
        ) == .ignore)
        #expect(WatchLegacyCreateIngressResolver.action(
            metadata: WatchLegacyMutationMetadata(message: [:]),
            conversationID: conversationID,
            activePeerID: activePeerID,
            acknowledgements: [:],
            conversationExists: false,
            isTrackedPlaceholder: false
        ) == .create)
        #expect(WatchLegacyCreateIngressResolver.action(
            metadata: WatchLegacyMutationMetadata(message: [
                WatchMessageKeys.peerId: UUID().uuidString,
                WatchMessageKeys.mutationRevision: NSNumber(value: 4)
            ]),
            conversationID: conversationID,
            activePeerID: activePeerID,
            acknowledgements: [:],
            conversationExists: false,
            isTrackedPlaceholder: false
        ) == .ignore)
    }

    @Test
    func `late legacy create repairs a message placeholder without losing messages`() {
        let conversationID = UUID()
        let message = Message(
            id: UUID(),
            role: .user,
            content: "Arrived first",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let placeholder = Conversation(
            id: conversationID,
            title: "Watch Chat",
            messages: [message],
            createdAt: message.timestamp,
            updatedAt: message.timestamp,
            model: "phone-placeholder-model",
            temperature: 0.7
        )
        let create = WatchConversation(
            id: conversationID,
            title: "Watch title",
            model: "watch-model",
            updatedAt: Date(timeIntervalSince1970: 10),
            createdAt: Date(timeIntervalSince1970: 10),
            temperature: 0.3,
            resolvedSystemPrompt: "Watch prompt",
            watchRevision: 1
        )

        let repaired = WatchLegacyConversationMerger.mergeCreate(create, into: placeholder)

        #expect(repaired.title == "Watch title")
        #expect(repaired.model == "watch-model")
        #expect(repaired.temperature == 0.3)
        #expect(repaired.systemPromptMode == .inheritGlobal)
        #expect(repaired.createdAt == create.createdAt)
        #expect(repaired.updatedAt == message.timestamp)
        #expect(repaired.messages == [message])
    }

    @Test
    func `nonmatching application context echo covers no legacy components`() {
        let message = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Pending",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Pending",
            messages: [message],
            model: "pending-model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10),
            watchRevision: 1
        )
        let mutation = WatchConversationMutation(
            revision: 1,
            conversation: conversation,
            fields: .fullState,
            messageChanges: [message]
        )
        let unrelatedConversation = WatchConversation(
            id: UUID(),
            title: conversation.title,
            messages: conversation.messages,
            model: conversation.model,
            updatedAt: conversation.updatedAt,
            createdAt: conversation.createdAt,
            temperature: conversation.temperature,
            resolvedSystemPrompt: conversation.resolvedSystemPrompt,
            watchRevision: conversation.watchRevision
        )

        let reconciliation = WatchLegacyEchoReconciler.reconcile(
            mutation,
            echoedConversations: [unrelatedConversation]
        )

        #expect(reconciliation.matchedComponents.isEmpty)
        #expect(!reconciliation.canAcknowledgeMutation)
    }

    @Test
    func `partial application context echo covers only matching message components`() {
        let firstMessage = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "First",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let secondMessage = WatchMessage(
            id: UUID(),
            role: Message.Role.assistant.rawValue,
            content: "Second",
            timestamp: Date(timeIntervalSince1970: 21)
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Existing",
            messages: [firstMessage, secondMessage],
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 21),
            createdAt: Date(timeIntervalSince1970: 10),
            watchRevision: 3
        )
        let mutation = WatchConversationMutation(
            revision: 3,
            conversation: conversation,
            fields: [.messages],
            messageChanges: [firstMessage, secondMessage],
            messageChangeRevisions: [firstMessage.id: 2, secondMessage.id: 3]
        )
        var partialEcho = conversation
        partialEcho.messages = [firstMessage]

        let reconciliation = WatchLegacyEchoReconciler.reconcile(
            mutation,
            echoedConversations: [partialEcho]
        )

        #expect(reconciliation.matchedComponents == [
            .message(id: firstMessage.id, revision: 2)
        ])
        #expect(reconciliation.unsupportedFields.isEmpty)
        #expect(!reconciliation.canAcknowledgeMutation)
    }

    @Test
    @MainActor
    func `partial echo suppresses only the components durably reflected by phone`() throws {
        let suiteName = "WatchLegacyEchoCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "coverage"
        )
        let message = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Echoed",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Existing",
            messages: [message],
            model: "new-model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10),
            watchRevision: 2
        )
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: conversation,
            fields: [.messages, .configuration],
            configurationRevision: 2,
            messageChanges: [message],
            messageChangeRevisions: [message.id: 2]
        )
        let reconciliation = WatchLegacyEchoReconciler.reconcile(
            mutation,
            echoedConversations: [conversation]
        )

        for component in reconciliation.matchedComponents {
            tracker.confirm(component.deliveryUserInfo(for: mutation))
        }

        #expect(tracker.pendingMessages(from: mutation).isEmpty)
        #expect(!tracker.configurationIsRepresented(by: mutation, createWillBeSent: false))
        #expect(!reconciliation.canAcknowledgeMutation)
    }

    @Test
    @MainActor
    func `successful legacy transfer waits for echo without duplicate retransmission`() throws {
        let suiteName = "WatchLegacyAwaitingEchoSuccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let message = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Send once",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Legacy",
            messages: [message],
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10),
            watchRevision: 1
        )
        let mutation = WatchConversationMutation(
            revision: 1,
            conversation: conversation,
            fields: [.messages],
            messageChanges: [message],
            messageChangeRevisions: [message.id: 1]
        )
        let initialSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let componentID = try #require(initialSend.componentIDs.first)

        tracker.recordTransferCompletion(componentID: componentID, succeeded: true)

        let retry = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        #expect(retry.userInfos.isEmpty)
        #expect(retry.awaitingEchoComponentIDs == [componentID])
        #expect(tracker.isAwaitingEcho(componentID: componentID))
        #expect(retry.fullyRepresented)
    }

    @Test
    @MainActor
    func `legacy delivery evidence reset makes persisted components sendable to a new counterpart`() throws {
        let suiteName = "WatchLegacyCounterpartResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let mutation = makeLegacyMessageMutation(content: "Deliver to replacement phone")
        let initial = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let componentID = try #require(initial.componentIDs.first)
        let component = try #require(initial.userInfos.first)
        tracker.confirm(component)

        #expect(try WatchLegacyMutationSender.prepare(mutation, tracker: tracker).componentIDs.isEmpty)

        tracker.reset()
        let reloaded = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let replacementSend = try WatchLegacyMutationSender.prepare(mutation, tracker: reloaded)

        #expect(replacementSend.componentIDs == [componentID])
        #expect(replacementSend.awaitingEchoComponentIDs.isEmpty)
        #expect(!WatchLegacyEchoReconciler.canAcknowledge(
            mutation,
            currentMatches: [],
            durableCoverage: WatchMutationDeliveryCoverage(
                messageRevisions: [mutation.messageChanges[0].id: mutation.revision]
            )
        ))
    }

    @Test
    @MainActor
    func `legacy transfer retransmits after bounded unanswered echo retries`() throws {
        let suiteName = "WatchLegacyEchoExpiryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(userDefaults: defaults, persistenceKey: "state")
        let mutation = makeLegacyMessageMutation(content: "Retry after missing durable echo")
        let initial = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let componentID = try #require(initial.componentIDs.first)
        tracker.recordTransferCompletion(componentID: componentID, succeeded: true)

        for _ in 0 ..< 3 {
            let awaiting = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
            #expect(awaiting.userInfos.isEmpty)
            #expect(awaiting.awaitingEchoComponentIDs == [componentID])
        }
        let retry = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)

        #expect(retry.componentIDs == [componentID])
        #expect(retry.awaitingEchoComponentIDs.isEmpty)
        #expect(!tracker.isAwaitingEcho(componentID: componentID))
    }

    @Test
    @MainActor
    func `legacy create and title transfers expire into retransmission`() throws {
        let suiteName = "WatchLegacyCreateTitleExpiryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(userDefaults: defaults, persistenceKey: "state")
        let conversation = WatchConversation(
            id: UUID(),
            title: "Create me",
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 2),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 1
        )
        let mutation = WatchConversationMutation(
            revision: 1,
            conversation: conversation,
            fields: [.create, .title, .configuration]
        )
        let initial = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        #expect(initial.componentIDs.count == 2)
        for componentID in initial.componentIDs {
            tracker.recordTransferCompletion(componentID: componentID, succeeded: true)
        }

        for _ in 0 ..< 3 {
            let awaiting = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
            #expect(awaiting.userInfos.isEmpty)
            #expect(awaiting.awaitingEchoComponentIDs == initial.componentIDs)
        }
        let retry = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)

        #expect(retry.componentIDs == initial.componentIDs)
        #expect(retry.awaitingEchoComponentIDs.isEmpty)
    }

    @Test
    @MainActor
    func `expired legacy retransmissions do not starve never-sent message tail`() throws {
        let suiteName = "WatchLegacyTailProgressTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(userDefaults: defaults, persistenceKey: "state")
        let messages = (0 ..< 25).map { index in
            WatchMessage(
                id: UUID(),
                role: Message.Role.user.rawValue,
                content: "message-\(index)",
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        let conversation = WatchConversation(
            id: UUID(),
            title: "Paged",
            messages: messages,
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 30),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 25
        )
        let mutation = WatchConversationMutation(
            revision: 25,
            conversation: conversation,
            fields: [.messages],
            messageChanges: messages,
            messageChangeRevisions: Dictionary(
                uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, UInt64($0.offset + 1)) }
            )
        )
        let first = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        for componentID in first.componentIDs {
            tracker.recordTransferCompletion(componentID: componentID, succeeded: true)
        }
        for _ in 0 ..< 3 {
            _ = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        }

        let retry = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let retryMessageIDs = retry.userInfos.compactMap {
            ($0[WatchMessageKeys.messageId] as? String).flatMap(UUID.init(uuidString:))
        }

        #expect(Array(retryMessageIDs.prefix(5)) == messages.suffix(5).map(\.id))
        #expect(Set(retryMessageIDs).count == retryMessageIDs.count)
    }

    @Test
    @MainActor
    func `failed legacy transfer becomes eligible for retry`() throws {
        let suiteName = "WatchLegacyAwaitingEchoFailureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let mutation = makeLegacyMessageMutation(content: "Retry after failure")
        let initialSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let componentID = try #require(initialSend.componentIDs.first)
        tracker.recordTransferCompletion(componentID: componentID, succeeded: true)

        tracker.recordTransferCompletion(componentID: componentID, succeeded: false)

        let retry = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        #expect(retry.componentIDs == [componentID])
        #expect(retry.awaitingEchoComponentIDs.isEmpty)
        #expect(!tracker.isAwaitingEcho(componentID: componentID))
    }

    @Test
    @MainActor
    func `legacy completion follows a retained component into a coalesced operation`() throws {
        let suiteName = "WatchLegacyCoalescedCompletionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let conversationID = UUID()
        let firstMessage = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "First",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let firstConversation = WatchConversation(
            id: conversationID,
            title: "Legacy",
            messages: [firstMessage],
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10),
            watchRevision: 1
        )
        let firstMutation = WatchConversationMutation(
            revision: 1,
            conversation: firstConversation,
            fields: [.messages],
            messageChanges: [firstMessage]
        )
        let initialSend = try WatchLegacyMutationSender.prepare(firstMutation, tracker: tracker)
        let componentID = try #require(initialSend.componentIDs.first)
        let secondMessage = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Second",
            timestamp: Date(timeIntervalSince1970: 21)
        )
        var secondConversation = firstConversation
        secondConversation.messages.append(secondMessage)
        secondConversation.updatedAt = Date(timeIntervalSince1970: 21)
        secondConversation.watchRevision = 2
        let secondMutation = WatchConversationMutation(
            revision: 2,
            conversation: secondConversation,
            fields: [.messages],
            messageChanges: [secondMessage]
        )
        let coalesced = try #require(firstMutation.coalescing(with: secondMutation))

        let resolved = WatchLegacyTransferCompletionResolver.pendingMutation(
            originalOperationID: firstMutation.operationID,
            componentID: componentID,
            pendingMutations: [coalesced]
        )

        #expect(resolved?.operationID == secondMutation.operationID)
    }

    @Test
    @MainActor
    func `durable phone echo clears legacy transfer awaiting state`() throws {
        let suiteName = "WatchLegacyAwaitingEchoClearTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let mutation = makeLegacyMessageMutation(content: "Echoed once")
        let initialSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let componentID = try #require(initialSend.componentIDs.first)
        tracker.recordTransferCompletion(componentID: componentID, succeeded: true)
        var echoedConversation = mutation.conversation
        echoedConversation.messages = mutation.messageChanges
        let reconciliation = tracker.reconcile(
            mutation,
            echoedConversations: [echoedConversation]
        )

        for component in reconciliation.matchedComponents {
            tracker.confirm(component.deliveryUserInfo(for: mutation))
        }

        #expect(!tracker.isAwaitingEcho(componentID: componentID))
        let retry = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        #expect(retry.userInfos.isEmpty)
        #expect(retry.awaitingEchoComponentIDs.isEmpty)
    }

    @Test
    @MainActor
    func `legacy transfer awaiting echo survives tracker restart`() throws {
        let suiteName = "WatchLegacyAwaitingEchoRestartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let persistenceKey = "state"
        let mutation = makeLegacyMessageMutation(content: "Persist awaiting echo")
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: persistenceKey
        )
        let initialSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let componentID = try #require(initialSend.componentIDs.first)
        tracker.recordTransferCompletion(componentID: componentID, succeeded: true)

        let reloaded = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: persistenceKey
        )
        let retry = try WatchLegacyMutationSender.prepare(mutation, tracker: reloaded)

        #expect(retry.userInfos.isEmpty)
        #expect(retry.awaitingEchoComponentIDs == [componentID])
        #expect(reloaded.isAwaitingEcho(componentID: componentID))
    }

    @Test
    func `partial echo covers matching messages but leaves unsupported configuration pending`() {
        let message = WatchMessage(
            id: UUID(),
            role: Message.Role.user.rawValue,
            content: "Echoed",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let conversation = WatchConversation(
            id: UUID(),
            title: "Existing",
            messages: [message],
            model: "new-model",
            updatedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 10),
            watchRevision: 2
        )
        let mutation = WatchConversationMutation(
            revision: 2,
            conversation: conversation,
            fields: [.messages, .configuration],
            configurationRevision: 2,
            messageChanges: [message],
            messageChangeRevisions: [message.id: 2]
        )

        let reconciliation = WatchLegacyEchoReconciler.reconcile(
            mutation,
            echoedConversations: [conversation]
        )

        #expect(reconciliation.matchedComponents == [
            .message(id: message.id, revision: 2)
        ])
        #expect(reconciliation.unsupportedFields == [.configuration])
        #expect(!reconciliation.canAcknowledgeMutation)
        #expect(!WatchLegacyEchoReconciler.canAcknowledge(
            mutation,
            currentMatches: reconciliation.matchedComponents,
            durableCoverage: WatchMutationDeliveryCoverage(
                configurationRevision: 2,
                messageRevisions: [message.id: 2]
            )
        ))
    }

    @Test
    @MainActor
    func `title delivery tracking resends a higher revision when text returns to a prior value`() throws {
        let suiteName = "WatchLegacyTitleRevisionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let conversationID = UUID()

        tracker.confirm([
            WatchMessageKeys.conversationId: conversationID.uuidString,
            WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentTitle,
            WatchMessageKeys.title: "A",
            WatchMessageKeys.mutationRevision: NSNumber(value: 1)
        ])

        #expect(tracker.needsTitle(conversationID: conversationID, title: "B", revision: 2))
        #expect(tracker.needsTitle(conversationID: conversationID, title: "A", revision: 3))

        tracker.confirm([
            WatchMessageKeys.conversationId: conversationID.uuidString,
            WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentTitle,
            WatchMessageKeys.title: "A",
            WatchMessageKeys.mutationRevision: NSNumber(value: 3)
        ])

        #expect(!tracker.needsTitle(conversationID: conversationID, title: "A", revision: 3))
    }

    @Test
    @MainActor
    func `stale A echo cannot confirm final A after A B A title sequence`() throws {
        let suiteName = "WatchLegacyTitleEchoFenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let conversationID = UUID()
        let initial = WatchConversation(
            id: conversationID,
            title: "A",
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 10),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 1
        )
        tracker.confirm([
            WatchMessageKeys.conversationId: conversationID.uuidString,
            WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentTitle,
            WatchMessageKeys.title: "A",
            WatchMessageKeys.mutationRevision: NSNumber(value: 1)
        ])

        var middle = initial
        middle.title = "B"
        middle.updatedAt = Date(timeIntervalSince1970: 20)
        middle.watchRevision = 2
        tracker.recordTitleMutation(WatchConversationMutation(
            revision: 2,
            conversation: middle,
            fields: [.title]
        ))

        var final = middle
        final.title = "A"
        final.updatedAt = Date(timeIntervalSince1970: 30)
        final.watchRevision = 3
        let finalMutation = WatchConversationMutation(
            revision: 3,
            conversation: final,
            fields: [.title]
        )
        tracker.recordTitleMutation(finalMutation)

        var staleEcho = initial
        staleEcho.watchRevision = 0
        let staleReconciliation = tracker.reconcile(
            finalMutation,
            echoedConversations: [staleEcho]
        )

        #expect(staleReconciliation.matchedComponents.isEmpty)
        #expect(!staleReconciliation.canAcknowledgeMutation)
        #expect(tracker.needsTitle(
            conversationID: conversationID,
            title: "A",
            revision: 3
        ))

        var freshEcho = final
        freshEcho.updatedAt = Date(timeIntervalSince1970: 40)
        freshEcho.watchRevision = 0
        let freshReconciliation = tracker.reconcile(
            finalMutation,
            echoedConversations: [freshEcho]
        )

        #expect(freshReconciliation.matchedComponents == [.title(revision: 3)])
        #expect(freshReconciliation.canAcknowledgeMutation)
        for component in freshReconciliation.matchedComponents {
            tracker.confirm(component.deliveryUserInfo(for: finalMutation))
        }
        #expect(!tracker.needsTitle(
            conversationID: conversationID,
            title: "A",
            revision: 3
        ))
    }

    @Test
    @MainActor
    func `legacy string-only title tracker state migrates without suppressing newer revisions`() throws {
        let suiteName = "WatchLegacyTitleMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let key = "state"
        let conversationID = UUID()
        let legacyState = LegacyTitleDeliveryState(
            titles: [conversationID: "A"]
        )
        try defaults.set(JSONEncoder().encode(legacyState), forKey: key)

        let migrated = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: key
        )

        #expect(migrated.needsTitle(
            conversationID: conversationID,
            title: "A",
            revision: 3
        ))
        migrated.confirm([
            WatchMessageKeys.conversationId: conversationID.uuidString,
            WatchMessageKeys.legacyComponentKind: WatchMessageKeys.legacyComponentTitle,
            WatchMessageKeys.title: "A",
            WatchMessageKeys.mutationRevision: NSNumber(value: 3)
        ])

        let reloaded = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: key
        )
        #expect(!reloaded.needsTitle(
            conversationID: conversationID,
            title: "A",
            revision: 3
        ))
    }

    @Test
    func `model selection retains manifest-only conversation configuration beyond nominal limit`() throws {
        let bodyConversation = Conversation(
            title: "Body",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            model: "body-model"
        )
        let manifestOnlyConversation = Conversation(
            title: "Manifest only",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 15),
            model: "manifest-only-model"
        )
        let state = PhoneWatchSyncState(conversations: [
            bodyConversation,
            manifestOnlyConversation
        ])
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 1
        let payload = try WatchSyncPayloadBuilder.build(
            state: state,
            snapshotRevision: 1,
            configuration: configuration
        )

        #expect(payload.snapshot.conversations.map(\.id) == [bodyConversation.id])
        #expect(payload.snapshot.authoritativeConversationIDs == [
            bodyConversation.id,
            manifestOnlyConversation.id
        ])

        let models = WatchModelSyncSelection.models(
            selectedModel: "selected-model",
            availableModels: ["fallback-model"],
            authoritativeState: state,
            snapshot: payload.snapshot,
            limit: 1
        )

        #expect(models == [
            "selected-model",
            "body-model",
            "manifest-only-model"
        ])
    }

    @Test
    func `reduced publication covers advertised models without selecting transport-only references`() throws {
        let selectableModels = (1 ... 5).map { "selectable-\($0)" }
        let transportOnlyModels = (1 ... 4).map { "transport-only-\($0)" }
        let conversations = transportOnlyModels.enumerated().map { index, model in
            Conversation(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0003-0000-%012d",
                    index + 1
                ))!,
                title: "Historical \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                model: model
            )
        }
        let state = PhoneWatchSyncState(conversations: conversations)
        let snapshot = try WatchSyncPayloadBuilder.build(
            state: state,
            snapshotRevision: 1
        ).snapshot
        let publication = WatchModelSyncSelection.publication(
            selectedModel: selectableModels[0],
            availableModels: selectableModels,
            authoritativeState: state,
            snapshot: snapshot,
            limit: 5
        )

        #expect(publication.availableModels == selectableModels)
        #expect(publication.metadataModels == [selectableModels[0]] + transportOnlyModels + selectableModels.dropFirst())
        #expect(transportOnlyModels.allSatisfy { !publication.availableModels.contains($0) })
        #expect(Set(publication.availableModels).isSubset(of: publication.metadataModelIDs))
    }

    @Test
    func `fresh watch receives credentials for every model advertised by a reduced publication`() {
        let selectableModels = (1 ... 5).map { "selectable-\($0)" }
        let selectedModel = selectableModels[0]
        let transportOnlyModels = (1 ... 4).map { "transport-only-\($0)" }
        let allModels = selectableModels + transportOnlyModels
        let publication = WatchModelSyncSelection.publication(
            selectedModel: selectedModel,
            availableModels: selectableModels,
            referencedModels: transportOnlyModels,
            limit: 5
        )
        let providers = Dictionary(uniqueKeysWithValues: allModels.map { ($0, "provider-\($0)") })
        let endpoints = Dictionary(uniqueKeysWithValues: allModels.map { ($0, "https://\($0).example/v1") })
        let endpointTypes = Dictionary(uniqueKeysWithValues: allModels.map { ($0, "endpoint-\($0)") })
        let oauth = Dictionary(uniqueKeysWithValues: allModels.enumerated().map { index, model in
            (model, index.isMultiple(of: 2))
        })
        let apiKeys = Dictionary(uniqueKeysWithValues: allModels.map { ($0, "key-\($0)") })
        let page = WatchModelMetadataPage(
            selectedModel: selectedModel,
            availableModels: publication.availableModels,
            customModels: selectableModels.filter(publication.metadataModelIDs.contains),
            defaultProvider: "default-provider",
            modelProviders: publication.metadataValues(from: providers),
            modelEndpoints: publication.metadataValues(from: endpoints),
            modelEndpointTypes: publication.metadataValues(from: endpointTypes),
            modelUsesGitHubOAuth: publication.metadataValues(from: oauth),
            modelAPIKeys: publication.metadataValues(from: apiKeys)
        )
        var state = WatchModelMetadataState(
            selectedModel: "",
            availableModels: [],
            customModels: [],
            defaultProvider: "",
            modelProviders: [:],
            modelEndpoints: [:],
            modelEndpointTypes: [:],
            modelUsesGitHubOAuth: [:],
            modelAPIKeys: [:]
        )
        var accumulator = WatchModelMetadataCycleAccumulator()

        accumulator.applyStandaloneContext(page, isComplete: false, to: &state)

        #expect(state.availableModels == selectableModels)
        #expect(transportOnlyModels.allSatisfy { !state.availableModels.contains($0) })
        for model in state.availableModels {
            #expect(state.modelProviders[model] == providers[model])
            #expect(state.modelEndpoints[model] == endpoints[model])
            #expect(state.modelEndpointTypes[model] == endpointTypes[model])
            #expect(state.modelUsesGitHubOAuth[model] == oauth[model])
            #expect(state.modelAPIKeys[model] == apiKeys[model])
        }
    }

    @Test
    @MainActor
    func `shared session FIFO prevents stale source rollback from unordered task completion`() async {
        let sourceA = UUID()
        let sourceB = UUID()
        let snapshotA = WatchSyncSnapshot(
            sourceID: sourceA,
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: []
        )
        let snapshotB = WatchSyncSnapshot(
            sourceID: sourceB,
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: []
        )
        let unorderedAStarted = TestAsyncGate()
        let releaseUnorderedA = TestAsyncGate()
        let unorderedBFinished = TestAsyncGate()
        var unorderedState = WatchSyncLocalState()

        let staleTask = Task { @MainActor in
            unorderedAStarted.open()
            await releaseUnorderedA.wait()
            unorderedState = WatchSnapshotReconciler.reconcile(snapshotA, with: unorderedState).state
        }
        await unorderedAStarted.wait()
        let newerTask = Task { @MainActor in
            unorderedState = WatchSnapshotReconciler.reconcile(snapshotB, with: unorderedState).state
            unorderedBFinished.open()
        }
        await unorderedBFinished.wait()
        releaseUnorderedA.open()
        await staleTask.value
        await newerTask.value

        #expect(unorderedState.sourceID == sourceA)

        let queue = WatchSessionEventQueue()
        let queuedAStarted = TestAsyncGate()
        let releaseQueuedA = TestAsyncGate()
        let queueFinished = TestAsyncGate()
        var sequencedState = WatchSyncLocalState()

        queue.enqueue {
            queuedAStarted.open()
            await releaseQueuedA.wait()
            sequencedState = WatchSnapshotReconciler.reconcile(snapshotA, with: sequencedState).state
        }
        await queuedAStarted.wait()
        queue.enqueue {
            sequencedState = WatchSnapshotReconciler.reconcile(snapshotB, with: sequencedState).state
            queueFinished.open()
        }
        releaseQueuedA.open()
        await queueFinished.wait()

        #expect(sequencedState.sourceID == sourceB)
    }

    @Test
    @MainActor
    func `phone publication reconciles durable deletions before deferring transport`() {
        var events: [String] = []

        let shouldPublish = WatchPhonePublicationBarrier.prepare(
            pendingOperationCount: { 1 },
            reconcile: { events.append("reconcile durable manifest") }
        )

        #expect(!shouldPublish)
        #expect(events == ["reconcile durable manifest"])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `destructive legacy deferral keeps later session events live`() async {
        let sessionQueue = WatchSessionEventQueue()
        let legacyDeferral = WatchLegacyIngressDeferralQueue()
        let pendingState = PendingDestructiveOperationState(count: 1)
        let laterEventFinished = TestAsyncGate()
        let legacyFinished = TestAsyncGate()
        var events: [String] = []

        sessionQueue.enqueue {
            guard WatchLegacyIngressRouting.shouldDefer(
                isAuthoritative: true,
                pendingDestructiveOperationCount: pendingState.count
            ) else {
                Issue.record("Destructive legacy ingress must leave the WCSession FIFO")
                return
            }
            legacyDeferral.retain(
                untilReady: { true },
                operation: {
                    await WatchLegacyPersistenceBarrier.perform(
                        pendingOperationCount: { pendingState.count },
                        changes: pendingState.$count,
                        reconcile: { events.append("reconcile") },
                        apply: { events.append("legacy") }
                    )
                    legacyFinished.open()
                }
            )
        }
        sessionQueue.enqueue {
            events.append("later")
            laterEventFinished.open()
        }

        await laterEventFinished.wait()
        #expect(events == ["later"])

        pendingState.count = 0
        await legacyFinished.wait()
        #expect(events == ["later", "reconcile", "legacy"])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func `deferred legacy ingress stays retained without blocking later session events`() async {
        let sessionQueue = WatchSessionEventQueue()
        let legacyDeferral = WatchLegacyIngressDeferralQueue()
        let authority = TestAsyncGate()
        let laterEventFinished = TestAsyncGate()
        let legacyFinished = TestAsyncGate()
        var events: [String] = []

        sessionQueue.enqueue {
            legacyDeferral.retain(
                untilReady: {
                    await authority.wait()
                    return true
                },
                operation: {
                    events.append("legacy")
                    legacyFinished.open()
                }
            )
        }
        sessionQueue.enqueue {
            events.append("later")
            laterEventFinished.open()
        }

        await laterEventFinished.wait()
        #expect(events == ["later"])

        authority.open()
        await legacyFinished.wait()
        #expect(events == ["later", "legacy"])
    }

    @Test
    func `received mutation does not override negotiated legacy capability`() {
        var capability = WatchPeerCapabilityState()
        capability.apply(.advertisedMaximumSchema(1))
        #expect(!capability.supportsCurrentSchema)

        capability.apply(.receivedMutation)
        #expect(!capability.supportsCurrentSchema)

        capability.apply(.advertisedMaximumSchema(WatchSyncSnapshot.currentSchemaVersion))
        capability.apply(.receivedMutation)
        #expect(capability.supportsCurrentSchema)
    }

    @Test
    func `peer capability strictly rejects malformed and nonpositive schema advertisements`() {
        let invalidValues: [Any?] = [
            nil,
            NSNull(),
            "2",
            true,
            NSNumber(value: 0),
            NSNumber(value: -1),
            NSNumber(value: 1.5),
            NSNumber(value: Double.infinity),
            NSNumber(value: Double.nan),
            NSNumber(value: UInt64.max)
        ]

        for value in invalidValues {
            #expect(WatchSyncCapability.advertisedMaximumSchemaVersion(value) == nil)
            #expect(!WatchSyncCapability.supportsCurrentSchema(value))
        }
    }

    @Test
    func `peer capability requires an advertised schema at least as new as current`() {
        #expect(!WatchSyncCapability.supportsCurrentSchema(NSNumber(value: 1)))
        #expect(WatchSyncCapability.supportsCurrentSchema(
            NSNumber(value: WatchSyncSnapshot.currentSchemaVersion)
        ))
        #expect(WatchSyncCapability.supportsCurrentSchema(
            NSNumber(value: WatchSyncSnapshot.currentSchemaVersion + 1)
        ))
    }

    @Test
    @MainActor
    func `legacy payload waits for destructive persistence then reconciles before applying`() async {
        let pendingState = PendingDestructiveOperationState(count: 1)
        let started = TestAsyncGate()
        var events: [String] = []

        let task = Task { @MainActor in
            started.open()
            await WatchLegacyPersistenceBarrier.perform(
                pendingOperationCount: { pendingState.count },
                changes: pendingState.$count,
                reconcile: { events.append("reconcile") },
                apply: { events.append("apply") }
            )
        }

        await started.wait()
        #expect(events.isEmpty)

        pendingState.count = 0
        await task.value

        #expect(events == ["reconcile", "apply"])
    }
}

@Suite("Watch connectivity autoreview regression tests", .tags(.fast))
struct WatchConnectivityRegressionTests {
    @Test
    func `retired activation rejects delayed peer and source payloads on a reused session`() {
        let fence = WatchSessionActivationFence()
        let retiredActivation = fence.beginActivation()
        let currentActivation = fence.beginActivation()
        let retiredPeerID = UUID()
        let currentPeerID = UUID()
        let retiredSourceID = UUID()
        let currentSourceID = UUID()
        var activePeerID: UUID?
        var appliedSourceID: UUID?

        func apply(
            activation: WatchSessionActivationToken,
            peerID: UUID,
            sourceID: UUID
        ) {
            guard fence.isCurrent(activation) else { return }
            activePeerID = peerID
            appliedSourceID = sourceID
        }

        apply(
            activation: currentActivation,
            peerID: currentPeerID,
            sourceID: currentSourceID
        )
        apply(
            activation: retiredActivation,
            peerID: retiredPeerID,
            sourceID: retiredSourceID
        )

        #expect(activePeerID == currentPeerID)
        #expect(appliedSourceID == currentSourceID)
        #expect(!fence.isCurrent(retiredActivation))
        #expect(fence.isCurrent(currentActivation))
    }

    @Test
    func `bounded model fallback follows represented snapshot pages with full model IDs`() throws {
        let conversations = (0 ..< 80).map { index in
            Conversation(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0002-0000-%012d",
                    index + 1
                ))!,
                title: "Historical \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(200 - index)),
                model: "historical-model-\(index)-" + String(
                    repeating: String(index % 10),
                    count: 180
                )
            )
        }
        let state = PhoneWatchSyncState(conversations: conversations)
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 1
        configuration.maximumConversationConfigurations = 2
        configuration.byteBudget = 32000
        let firstPayload = try WatchSyncPayloadBuilder.build(
            state: state,
            snapshotRevision: 1,
            configuration: configuration
        )
        let secondPayload = try WatchSyncPayloadBuilder.build(
            state: state,
            snapshotRevision: 2,
            configuration: configuration
        )
        let allModels = conversations.map(\.model)

        let firstModels = WatchModelSyncSelection.models(
            selectedModel: "selected-model",
            availableModels: allModels,
            authoritativeState: state,
            snapshot: firstPayload.snapshot,
            limit: 5
        )
        let secondModels = WatchModelSyncSelection.models(
            selectedModel: "selected-model",
            availableModels: allModels,
            authoritativeState: state,
            snapshot: secondPayload.snapshot,
            limit: 5
        )
        let firstRepresentedIDs = Set(
            firstPayload.snapshot.conversations.map(\.id)
                + firstPayload.snapshot.conversationConfigurations.map(\.id)
        )
        let secondRepresentedIDs = Set(
            secondPayload.snapshot.conversations.map(\.id)
                + secondPayload.snapshot.conversationConfigurations.map(\.id)
        )
        let firstRepresentedModels = conversations
            .filter { firstRepresentedIDs.contains($0.id) }
            .map(\.model)
        let secondRepresentedModels = conversations
            .filter { secondRepresentedIDs.contains($0.id) }
            .map(\.model)

        #expect(firstRepresentedIDs != secondRepresentedIDs)
        #expect(firstRepresentedModels.allSatisfy(firstModels.contains))
        #expect(secondRepresentedModels.allSatisfy(secondModels.contains))
        #expect(firstModels.contains("selected-model"))
        #expect(try !firstModels.contains(#require(conversations.last?.model)))
        #expect(firstModels.allSatisfy { $0 == "selected-model" || $0.count > 160 })

        let metadata = Dictionary(uniqueKeysWithValues: allModels.enumerated().map { index, model in
            (
                model,
                "metadata-\(index)-" + String(
                    repeating: String(format: "%02d", index),
                    count: 1024
                )
            )
        })
        let boundedModelSet = Set(firstModels)
        let boundedContext: [String: Any] = [
            WatchContextKeys.syncSnapshot: firstPayload.data,
            WatchContextKeys.selectedModel: "selected-model",
            WatchContextKeys.availableModels: firstModels,
            WatchContextKeys.modelEndpoints: metadata.filter { boundedModelSet.contains($0.key) },
            WatchContextKeys.modelAPIKeys: metadata.filter { boundedModelSet.contains($0.key) },
            WatchContextKeys.modelUsesGitHubOAuth: [String: Bool](
                uniqueKeysWithValues: firstModels.map { ($0, false) }
            )
        ]
        let unboundedContext: [String: Any] = [
            WatchContextKeys.syncSnapshot: firstPayload.data,
            WatchContextKeys.selectedModel: "selected-model",
            WatchContextKeys.availableModels: allModels,
            WatchContextKeys.modelEndpoints: metadata,
            WatchContextKeys.modelAPIKeys: metadata
        ]

        #expect(
            WatchApplicationContextSizer.size(unboundedContext)
                > WatchApplicationContextSizer.maximumSafeBytes
        )
        #expect(WatchApplicationContextSizer.isWithinSafeLimit(boundedContext))
    }
}

@Suite("Watch context application tests", .tags(.fast))
struct WatchContextApplicationTests {
    @Test
    func `rejected standalone snapshots cannot apply snapshot-coupled settings`() {
        let rejectedOutcomes: [WatchSyncSnapshotApplyOutcome] = [
            .persistenceFailed,
            .ignoredStale,
            .ignoredUnsupportedSchema,
        ]

        for outcome in rejectedOutcomes {
            let mode = WatchContextApplicationMode.standalone(
                after: outcome,
                metadataIsComplete: true
            )

            #expect(mode == .ignore)
            #expect(!mode.appliesSnapshotSettings)
        }
    }

    @Test
    func `durable standalone snapshots pages and legacy fallback keep metadata semantics`() {
        let completeStandalone = WatchContextApplicationMode.standalone(
            after: .applied,
            metadataIsComplete: true
        )
        let provisionalStandalone = WatchContextApplicationMode.standalone(
            after: .alreadyDurable,
            metadataIsComplete: false
        )

        #expect(completeStandalone == .complete)
        #expect(completeStandalone.appliesSnapshotSettings)
        #expect(provisionalStandalone == .provisional)
        #expect(provisionalStandalone.appliesSnapshotSettings)
        #expect(WatchContextApplicationMode.page(
            cycleID: UUID(),
            completesCycle: false,
            metadataComplete: false
        ).appliesSnapshotSettings)
        #expect(WatchContextApplicationMode.legacy(metadataIsComplete: true) == .complete)
        #expect(WatchContextApplicationMode.legacy(metadataIsComplete: false) == .provisional)
    }
}

@Suite("Watch model metadata cycle tests", .tags(.fast))
struct WatchModelMetadataCycleTests {
    @Test
    func `distinct paged model configurations accumulate before authoritative pruning`() {
        let staleModel = "stale-model"
        let firstModel = "page-one-model"
        let secondModel = "page-two-model"
        var state = WatchModelMetadataState(
            selectedModel: staleModel,
            availableModels: [staleModel],
            customModels: [staleModel],
            defaultProvider: "openai",
            modelProviders: [staleModel: "openai"],
            modelEndpoints: [staleModel: "https://stale.example/v1"],
            modelEndpointTypes: [staleModel: "chatCompletions"],
            modelUsesGitHubOAuth: [staleModel: false],
            modelAPIKeys: [staleModel: "stale-key"]
        )
        let firstPage = WatchModelMetadataPage(
            selectedModel: firstModel,
            availableModels: [firstModel],
            customModels: [firstModel],
            defaultProvider: "openai",
            modelProviders: [firstModel: "openai"],
            modelEndpoints: [firstModel: "https://one.example/v1"],
            modelEndpointTypes: [firstModel: "responses"],
            modelUsesGitHubOAuth: [firstModel: false],
            modelAPIKeys: [firstModel: "key-one"]
        )
        let secondPage = WatchModelMetadataPage(
            selectedModel: firstModel,
            availableModels: [secondModel],
            customModels: [secondModel],
            defaultProvider: "openai",
            modelProviders: [secondModel: "anthropic"],
            modelEndpoints: [secondModel: "https://two.example/v1"],
            modelEndpointTypes: [secondModel: "messages"],
            modelUsesGitHubOAuth: [secondModel: true],
            modelAPIKeys: [secondModel: "key-two"]
        )
        let cycleID = UUID()
        var accumulator = WatchModelMetadataCycleAccumulator()

        accumulator.apply(
            firstPage,
            cycleID: cycleID,
            completesCycle: false,
            to: &state
        )

        #expect(state.availableModels == [staleModel, firstModel])
        #expect(state.customModels == [staleModel, firstModel])
        #expect(state.modelProviders == [staleModel: "openai", firstModel: "openai"])
        #expect(state.modelAPIKeys == [staleModel: "stale-key", firstModel: "key-one"])

        accumulator.apply(
            secondPage,
            cycleID: cycleID,
            completesCycle: true,
            to: &state
        )

        #expect(state.selectedModel == firstModel)
        #expect(state.availableModels == [firstModel, secondModel])
        #expect(state.customModels == [firstModel, secondModel])
        #expect(state.modelProviders == [firstModel: "openai", secondModel: "anthropic"])
        #expect(state.modelEndpoints == [
            firstModel: "https://one.example/v1",
            secondModel: "https://two.example/v1"
        ])
        #expect(state.modelEndpointTypes == [firstModel: "responses", secondModel: "messages"])
        #expect(state.modelUsesGitHubOAuth == [firstModel: false, secondModel: true])
        #expect(state.modelAPIKeys == [firstModel: "key-one", secondModel: "key-two"])
    }

    @Test
    func `only a completed lossless two-page cycle prunes stale model credentials`() throws {
        let sourceID = UUID()
        let firstCursor = WatchSyncPageCycleCursor.initial
        let firstMetadata = WatchSyncPageCycleMetadata(
            cycleID: UUID(),
            sourceID: sourceID,
            snapshotRevision: 1,
            cursor: firstCursor,
            manifest: WatchSyncPageSection(offset: 0, itemCount: 1, totalCount: 2),
            configurations: WatchSyncPageSection(offset: 0, itemCount: 1, totalCount: 2),
            tombstones: WatchSyncPageSection(offset: 0, itemCount: 0, totalCount: 0)
        )
        let secondCursor = try #require(firstMetadata.nextCursor)
        let secondMetadata = WatchSyncPageCycleMetadata(
            cycleID: firstMetadata.cycleID,
            sourceID: sourceID,
            snapshotRevision: 2,
            cursor: secondCursor,
            manifest: WatchSyncPageSection(offset: 1, itemCount: 1, totalCount: 2),
            configurations: WatchSyncPageSection(offset: 1, itemCount: 1, totalCount: 2),
            tombstones: WatchSyncPageSection(offset: 0, itemCount: 0, totalCount: 0)
        )
        var losslessPhone = WatchPhonePageCycleCoordinator()
        _ = losslessPhone.beginCycle(id: firstMetadata.cycleID)
        let losslessFirst = losslessPhone.metadataForPublication(
            firstMetadata,
            modelMetadataPageIsLossless: true
        )
        losslessPhone.recordPublished(
            losslessFirst,
            modelMetadataPageIsLossless: true
        )
        let losslessFinal = losslessPhone.metadataForPublication(
            secondMetadata,
            modelMetadataPageIsLossless: true
        )

        #expect(!losslessFirst.modelMetadataCycleIsAuthoritative)
        #expect(losslessFinal.modelMetadataCycleIsAuthoritative)
        losslessPhone.recordPublished(
            losslessFinal,
            modelMetadataPageIsLossless: true
        )
        let retriedLosslessFinal = losslessPhone.metadataForPublication(
            secondMetadata,
            modelMetadataPageIsLossless: true
        )
        #expect(retriedLosslessFinal.modelMetadataCycleIsAuthoritative)

        let staleModel = "stale-model"
        let firstModel = "first-model"
        let secondModel = "second-model"
        let firstPage = WatchModelMetadataPage(
            selectedModel: firstModel,
            availableModels: [firstModel],
            modelProviders: [firstModel: "openai"],
            modelAPIKeys: [firstModel: "first-key"]
        )
        let secondPage = WatchModelMetadataPage(
            selectedModel: firstModel,
            availableModels: [secondModel],
            modelProviders: [secondModel: "anthropic"],
            modelAPIKeys: [secondModel: "second-key"]
        )
        var losslessState = modelMetadataState(model: staleModel, key: "stale-key")
        var losslessWatch = WatchModelMetadataCycleAccumulator()
        losslessWatch.apply(
            firstPage,
            cycleID: firstMetadata.cycleID,
            completesCycle: false,
            isAuthoritative: losslessFirst.modelMetadataCycleIsAuthoritative,
            to: &losslessState
        )
        losslessWatch.apply(
            secondPage,
            cycleID: firstMetadata.cycleID,
            completesCycle: true,
            isAuthoritative: losslessFinal.modelMetadataCycleIsAuthoritative,
            to: &losslessState
        )

        #expect(losslessState.availableModels == [firstModel, secondModel])
        #expect(losslessState.modelAPIKeys == [firstModel: "first-key", secondModel: "second-key"])

        let boundedCycleID = UUID()
        let boundedFirstMetadata = WatchSyncPageCycleMetadata(
            cycleID: boundedCycleID,
            sourceID: sourceID,
            snapshotRevision: 3,
            cursor: firstCursor,
            manifest: firstMetadata.manifest,
            configurations: firstMetadata.configurations,
            tombstones: firstMetadata.tombstones
        )
        let boundedFinalMetadata = WatchSyncPageCycleMetadata(
            cycleID: boundedCycleID,
            sourceID: sourceID,
            snapshotRevision: 4,
            cursor: secondCursor,
            manifest: secondMetadata.manifest,
            configurations: secondMetadata.configurations,
            tombstones: secondMetadata.tombstones
        )
        var boundedPhone = WatchPhonePageCycleCoordinator()
        _ = boundedPhone.beginCycle(id: boundedCycleID)
        let boundedFirst = boundedPhone.metadataForPublication(
            boundedFirstMetadata,
            modelMetadataPageIsLossless: false
        )
        boundedPhone.recordPublished(
            boundedFirst,
            modelMetadataPageIsLossless: false
        )
        let boundedFinal = boundedPhone.metadataForPublication(
            boundedFinalMetadata,
            modelMetadataPageIsLossless: true
        )

        #expect(!boundedFinal.modelMetadataCycleIsAuthoritative)

        var boundedState = modelMetadataState(model: staleModel, key: "stale-key")
        var boundedWatch = WatchModelMetadataCycleAccumulator()
        boundedWatch.apply(
            firstPage,
            cycleID: boundedCycleID,
            completesCycle: false,
            isAuthoritative: boundedFirst.modelMetadataCycleIsAuthoritative,
            to: &boundedState
        )
        boundedWatch.apply(
            secondPage,
            cycleID: boundedCycleID,
            completesCycle: true,
            isAuthoritative: boundedFinal.modelMetadataCycleIsAuthoritative,
            to: &boundedState
        )

        #expect(boundedState.availableModels == [staleModel, firstModel, secondModel])
        #expect(boundedState.modelAPIKeys == [
            staleModel: "stale-key",
            firstModel: "first-key",
            secondModel: "second-key"
        ])
    }

    @Test
    func `bounded page cycle completion preserves metadata omitted by the cycle`() {
        let retainedModel = "retained-model"
        let incomingModel = "incoming-model"
        var state = WatchModelMetadataState(
            selectedModel: retainedModel,
            availableModels: [retainedModel],
            customModels: [retainedModel],
            defaultProvider: "openai",
            modelProviders: [retainedModel: "openai"],
            modelEndpoints: [retainedModel: "https://retained.example/v1"],
            modelEndpointTypes: [retainedModel: "responses"],
            modelUsesGitHubOAuth: [retainedModel: false],
            modelAPIKeys: [retainedModel: "retained-key"]
        )
        let page = WatchModelMetadataPage(
            selectedModel: incomingModel,
            availableModels: [incomingModel],
            customModels: [incomingModel],
            defaultProvider: "openai",
            modelProviders: [incomingModel: "anthropic"],
            modelEndpoints: [incomingModel: "https://incoming.example/v1"],
            modelEndpointTypes: [incomingModel: "messages"],
            modelUsesGitHubOAuth: [incomingModel: false],
            modelAPIKeys: [incomingModel: "incoming-key"]
        )
        var accumulator = WatchModelMetadataCycleAccumulator()

        accumulator.apply(
            page,
            cycleID: UUID(),
            completesCycle: true,
            isAuthoritative: false,
            to: &state
        )

        #expect(state.availableModels == [retainedModel, incomingModel])
        #expect(state.modelAPIKeys == [
            retainedModel: "retained-key",
            incomingModel: "incoming-key"
        ])
    }

    @Test
    func `new epoch provisional metadata preserves omitted models until complete replacement`() {
        let retainedModel = "retained-model"
        let removedModel = "removed-model"
        let incomingModel = "incoming-model"
        let previousEpoch = UUID()
        let incomingEpoch = UUID()
        var state = WatchModelMetadataState(
            selectedModel: retainedModel,
            availableModels: [retainedModel, removedModel],
            customModels: [retainedModel, removedModel],
            defaultProvider: "openai",
            modelProviders: [retainedModel: "openai", removedModel: "anthropic"],
            modelEndpoints: [retainedModel: "https://retained.example", removedModel: "https://removed.example"],
            modelEndpointTypes: [retainedModel: "responses", removedModel: "messages"],
            modelUsesGitHubOAuth: [retainedModel: false, removedModel: true],
            modelAPIKeys: [retainedModel: "retained-key", removedModel: "removed-key"]
        )
        var accumulator = WatchModelMetadataCycleAccumulator()
        var pendingEpoch: UUID?
        let provisional = WatchModelMetadataPage(
            selectedModel: incomingModel,
            availableModels: [incomingModel],
            customModels: [incomingModel],
            defaultProvider: "anthropic",
            modelProviders: [incomingModel: "anthropic"],
            modelEndpoints: [incomingModel: "https://incoming.example"],
            modelEndpointTypes: [incomingModel: "messages"],
            modelUsesGitHubOAuth: [incomingModel: false],
            modelAPIKeys: [incomingModel: "incoming-key"],
            removedModelDigests: [WatchModelIdentity.digest(removedModel)]
        )

        let provisionalEpoch = WatchModelMetadataContextReducer.apply(
            provisional,
            mode: .provisional,
            incomingEpoch: incomingEpoch,
            appliedEpoch: previousEpoch,
            pendingEpoch: &pendingEpoch,
            accumulator: &accumulator,
            to: &state
        )

        #expect(provisionalEpoch == nil)
        #expect(pendingEpoch == incomingEpoch)
        #expect(state.availableModels == [retainedModel, incomingModel])
        #expect(state.modelAPIKeys == [retainedModel: "retained-key", incomingModel: "incoming-key"])
        #expect(state.modelAPIKeys[removedModel] == nil)

        let complete = WatchModelMetadataPage(
            selectedModel: incomingModel,
            availableModels: [incomingModel],
            customModels: [incomingModel],
            defaultProvider: "anthropic",
            modelProviders: [incomingModel: "anthropic"],
            modelEndpoints: [incomingModel: "https://incoming.example"],
            modelEndpointTypes: [incomingModel: "messages"],
            modelUsesGitHubOAuth: [incomingModel: false],
            modelAPIKeys: [incomingModel: "incoming-key"]
        )
        let committedEpoch = WatchModelMetadataContextReducer.apply(
            complete,
            mode: .complete,
            incomingEpoch: incomingEpoch,
            appliedEpoch: previousEpoch,
            pendingEpoch: &pendingEpoch,
            accumulator: &accumulator,
            to: &state
        )

        #expect(committedEpoch == incomingEpoch)
        #expect(pendingEpoch == nil)
        #expect(state.availableModels == [incomingModel])
        #expect(state.modelAPIKeys == [incomingModel: "incoming-key"])
    }

    @Test
    func `bounded current schema bootstrap retains omitted model credentials`() throws {
        let retainedModel = "retained-model"
        let incomingModel = "incoming-model"
        var state = WatchModelMetadataState(
            selectedModel: retainedModel,
            availableModels: [retainedModel],
            customModels: [retainedModel],
            defaultProvider: "openai",
            modelProviders: [retainedModel: "openai"],
            modelEndpoints: [retainedModel: "https://retained.example/v1"],
            modelEndpointTypes: [retainedModel: "responses"],
            modelUsesGitHubOAuth: [retainedModel: false],
            modelAPIKeys: [retainedModel: "retained-key"]
        )
        let snapshot = WatchSyncSnapshot(
            revision: 1,
            conversations: [],
            authoritativeConversationIDs: [],
            authoritativeConversationIDsAreComplete: false,
            conversationConfigurations: [],
            conversationConfigurationsAreComplete: false
        )
        let modelMetadataComplete = WatchModelMetadataCompleteness.isCompletePublication(
            snapshot: snapshot,
            modelLimit: 1
        )
        let context: [String: Any] = try [
            WatchContextKeys.syncSnapshot: JSONEncoder().encode(snapshot),
            WatchContextKeys.selectedModel: incomingModel,
            WatchContextKeys.availableModels: [incomingModel],
            WatchContextKeys.modelProviders: [incomingModel: "anthropic"],
            WatchContextKeys.modelAPIKeys: [incomingModel: "incoming-key"],
            WatchContextKeys.modelMetadataComplete: modelMetadataComplete
        ]
        let page = WatchModelMetadataPage(context: context)
        let isComplete = WatchModelMetadataCompleteness.isExplicitlyComplete(in: context)
        #expect(!modelMetadataComplete)
        var accumulator = WatchModelMetadataCycleAccumulator()

        accumulator.applyStandaloneContext(
            page,
            isComplete: isComplete,
            to: &state
        )

        #expect(state.selectedModel == incomingModel)
        #expect(state.availableModels == [retainedModel, incomingModel])
        #expect(state.modelProviders == [retainedModel: "openai", incomingModel: "anthropic"])
        #expect(state.modelAPIKeys == [
            retainedModel: "retained-key",
            incomingModel: "incoming-key"
        ])
    }
}

@Suite("Watch model selection coordinator tests", .tags(.fast))
struct WatchModelSelectionCoordinatorTests {
    @Test
    @MainActor
    func `failed conversation model persistence leaves global selection unchanged`() {
        let conversationID = UUID()
        var globalModels: [String] = []
        var persistenceAttempts: [String] = []

        let selected = WatchModelSelectionCoordinator.select(
            model: "new-model",
            conversationID: conversationID,
            currentConversationModel: { _ in "old-model" },
            persistConversationModel: { model, _ in
                persistenceAttempts.append(model)
                return false
            },
            applyGlobalModel: { globalModels.append($0) }
        )

        #expect(!selected)
        #expect(persistenceAttempts == ["new-model"])
        #expect(globalModels.isEmpty)
    }

    @Test
    func `single model auto selection is limited to new chat`() {
        #expect(WatchModelSelectionCoordinator.shouldAutoSelect(
            availableModelCount: 1,
            conversationID: nil
        ))
        #expect(!WatchModelSelectionCoordinator.shouldAutoSelect(
            availableModelCount: 1,
            conversationID: UUID()
        ))
        #expect(!WatchModelSelectionCoordinator.shouldAutoSelect(
            availableModelCount: 2,
            conversationID: nil
        ))
    }

    @Test
    @MainActor
    func `already selected conversation model commits globals without another write`() {
        let conversationID = UUID()
        var globalModels: [String] = []
        var attemptedPersistence = false

        let selected = WatchModelSelectionCoordinator.select(
            model: "same-model",
            conversationID: conversationID,
            currentConversationModel: { _ in "same-model" },
            persistConversationModel: { _, _ in
                attemptedPersistence = true
                return false
            },
            applyGlobalModel: { globalModels.append($0) }
        )

        #expect(selected)
        #expect(!attemptedPersistence)
        #expect(globalModels == ["same-model"])
    }
}

@Suite("Watch legacy metadata compatibility tests", .tags(.fast))
struct WatchLegacyMetadataCompatibilityTests {
    @Test
    func `markerless legacy metadata is authoritative while explicit false remains provisional`() {
        let staleModel = "stale-model"
        let currentModel = "current-model"
        let markerlessContext: [String: Any] = [
            WatchContextKeys.selectedModel: currentModel,
            WatchContextKeys.availableModels: [currentModel],
            WatchContextKeys.customModels: [currentModel],
            WatchContextKeys.defaultProvider: "openai",
            WatchContextKeys.modelProviders: [currentModel: "openai"],
            WatchContextKeys.modelEndpoints: [currentModel: "https://current.example/v1"],
            WatchContextKeys.modelEndpointTypes: [currentModel: "responses"],
            WatchContextKeys.modelUsesGitHubOAuth: [currentModel: false],
            WatchContextKeys.modelAPIKeys: [currentModel: "current-key"]
        ]
        var state = modelMetadataState(model: staleModel, key: "stale-key")
        var accumulator = WatchModelMetadataCycleAccumulator()

        #expect(WatchModelMetadataCompleteness.legacyContextIsComplete(in: markerlessContext))
        accumulator.applyStandaloneContext(
            WatchModelMetadataPage(context: markerlessContext),
            isComplete: WatchModelMetadataCompleteness.legacyContextIsComplete(in: markerlessContext),
            to: &state
        )

        #expect(state.availableModels == [currentModel])
        #expect(state.modelAPIKeys == [currentModel: "current-key"])

        var explicitBoundedContext = markerlessContext
        explicitBoundedContext[WatchContextKeys.modelMetadataComplete] = false
        #expect(!WatchModelMetadataCompleteness.legacyContextIsComplete(in: explicitBoundedContext))
        #expect(WatchContextApplicationMode.complete.treatsOmittedCredentialsAsRemoved)
        #expect(!WatchContextApplicationMode.provisional.treatsOmittedCredentialsAsRemoved)

        var missingKeysState = modelMetadataState(model: staleModel, key: "stale-key")
        accumulator.applyCompleteContext(
            WatchModelMetadataPage(context: [
                WatchContextKeys.selectedModel: currentModel,
                WatchContextKeys.availableModels: [currentModel],
                WatchContextKeys.customModels: [currentModel]
            ]),
            to: &missingKeysState
        )
        #expect(missingKeysState.modelAPIKeys.isEmpty)
        #expect(missingKeysState.modelProviders.isEmpty)
        #expect(missingKeysState.modelEndpoints.isEmpty)
    }
}

@Suite("Watch model removal compatibility tests", .tags(.fast))
struct WatchModelRemovalCompatibilityTests {
    @Test
    func `removed model digests persist across publications until the model is readded`() throws {
        var tracker = WatchModelRemovalTracker()

        #expect(tracker.publication(inventory: modelInventory(["model-a", "model-b"])).isEmpty)
        let removed = tracker.publication(inventory: modelInventory(["model-b"]))
        #expect(removed.removedModelDigests == [WatchModelIdentity.digest("model-a")])
        #expect(tracker.publication(inventory: modelInventory(["model-b"])) == removed)
        let restored = try JSONDecoder().decode(
            WatchModelRemovalTracker.self,
            from: JSONEncoder().encode(tracker)
        )
        #expect(restored == tracker)
        #expect(tracker.publication(inventory: modelInventory(["model-a", "model-b"])).isEmpty)
    }

    @Test
    func `model removal history rotates epoch before tombstones exceed the context budget`() throws {
        let limit = WatchModelRemovalTracker.maximumRetiredDigestCount
        let fieldRetirementCount = limit / 6
        let modelRetirementCount = limit - (fieldRetirementCount * 5)
        let retiredModels = (0 ..< modelRetirementCount).map { "retired-model-\($0)" }
        let retiredFieldModels = Array(retiredModels.prefix(fieldRetirementCount))
        let retainedModel = "retained-model"
        var tracker = WatchModelRemovalTracker()
        let originalEpoch = tracker.epoch

        #expect(tracker.publication(inventory: WatchModelMetadataInventory(
            modelIDs: retiredModels + [retainedModel],
            providerModelIDs: retiredFieldModels + [retainedModel],
            endpointModelIDs: retiredFieldModels,
            endpointTypeModelIDs: retiredFieldModels,
            gitHubOAuthModelIDs: retiredFieldModels,
            apiKeyModelIDs: retiredFieldModels
        )).isEmpty)
        let atLimit = tracker.publication(inventory: WatchModelMetadataInventory(
            modelIDs: [retainedModel],
            providerModelIDs: [retainedModel],
            endpointModelIDs: [],
            endpointTypeModelIDs: [],
            gitHubOAuthModelIDs: [],
            apiKeyModelIDs: []
        ))
        let atLimitContext: [String: Any] = [
            WatchContextKeys.removedModelDigests: atLimit.removedModelDigests,
            WatchContextKeys.removedModelProviderDigests: atLimit.removedProviderDigests,
            WatchContextKeys.removedModelEndpointDigests: atLimit.removedEndpointDigests,
            WatchContextKeys.removedModelEndpointTypeDigests: atLimit.removedEndpointTypeDigests,
            WatchContextKeys.removedModelGitHubOAuthDigests: atLimit.removedGitHubOAuthDigests,
            WatchContextKeys.removedModelAPIKeyDigests: atLimit.removedAPIKeyDigests,
            WatchContextKeys.modelMetadataEpoch: tracker.epoch.uuidString
        ]
        let encodedAtLimit = try JSONEncoder().encode(tracker)
        let retiredCount = atLimit.removedModelDigests.count
            + atLimit.removedProviderDigests.count
            + atLimit.removedEndpointDigests.count
            + atLimit.removedEndpointTypeDigests.count
            + atLimit.removedGitHubOAuthDigests.count
            + atLimit.removedAPIKeyDigests.count

        #expect(retiredCount == limit)
        #expect(tracker.epoch == originalEpoch)
        #expect(WatchApplicationContextSizer.isWithinSafeLimit(atLimitContext))
        #expect(encodedAtLimit.count <= WatchApplicationContextSizer.maximumSafeBytes)

        let afterRotation = tracker.publication(inventory: WatchModelMetadataInventory(
            modelIDs: [retainedModel],
            providerModelIDs: [],
            endpointModelIDs: [],
            endpointTypeModelIDs: [],
            gitHubOAuthModelIDs: [],
            apiKeyModelIDs: []
        ))
        let encodedAfterRotation = try JSONEncoder().encode(tracker)

        #expect(afterRotation.isEmpty)
        #expect(tracker.epoch != originalEpoch)
        #expect(tracker.publishedDigests == [WatchModelIdentity.digest(retainedModel)])
        #expect(tracker.publishedProviderDigests.isEmpty)
        #expect(tracker.retiredDigests.isEmpty)
        #expect(tracker.retiredProviderDigests.isEmpty)
        #expect(encodedAfterRotation.count < encodedAtLimit.count)
    }

    @Test
    func `changed bounded metadata invalidates stale values until replacements arrive`() {
        let model = "changed-model"
        let modelDigest = WatchModelIdentity.digest(model)
        var tracker = WatchModelRemovalTracker()
        let oldInventory = WatchModelMetadataInventory(
            modelIDs: [model],
            providerModelIDs: [model],
            endpointModelIDs: [model],
            endpointTypeModelIDs: [model],
            gitHubOAuthModelIDs: [model],
            apiKeyModelIDs: [model],
            valueDigests: WatchModelMetadataValueDigests(
                providers: [modelDigest: WatchModelIdentity.digest("openai")],
                endpoints: [modelDigest: WatchModelIdentity.digest("https://old.example")],
                endpointTypes: [modelDigest: WatchModelIdentity.digest("responses")],
                gitHubOAuth: [modelDigest: WatchModelIdentity.digest("false")],
                apiKeys: [modelDigest: WatchModelIdentity.digest("old-key")]
            )
        )
        let newInventory = WatchModelMetadataInventory(
            modelIDs: [model],
            providerModelIDs: [model],
            endpointModelIDs: [model],
            endpointTypeModelIDs: [model],
            gitHubOAuthModelIDs: [model],
            apiKeyModelIDs: [model],
            valueDigests: WatchModelMetadataValueDigests(
                providers: [modelDigest: WatchModelIdentity.digest("anthropic")],
                endpoints: [modelDigest: WatchModelIdentity.digest("https://new.example")],
                endpointTypes: [modelDigest: WatchModelIdentity.digest("messages")],
                gitHubOAuth: [modelDigest: WatchModelIdentity.digest("true")],
                apiKeys: [modelDigest: WatchModelIdentity.digest("new-key")]
            )
        )

        #expect(tracker.publication(inventory: oldInventory).isEmpty)
        let invalidations = tracker.publication(inventory: newInventory)

        #expect(invalidations.removedProviderDigests == [modelDigest])
        #expect(invalidations.removedEndpointDigests == [modelDigest])
        #expect(invalidations.removedEndpointTypeDigests == [modelDigest])
        #expect(invalidations.removedGitHubOAuthDigests == [modelDigest])
        #expect(invalidations.removedAPIKeyDigests == [modelDigest])
        #expect(tracker.publication(inventory: newInventory) == invalidations)

        var state = WatchModelMetadataState(
            selectedModel: model,
            availableModels: [model],
            customModels: [model],
            defaultProvider: "openai",
            modelProviders: [model: "openai"],
            modelEndpoints: [model: "https://old.example"],
            modelEndpointTypes: [model: "responses"],
            modelUsesGitHubOAuth: [model: false],
            modelAPIKeys: [model: "old-key"]
        )
        state.merge(WatchModelMetadataPage(
            removedModelProviderDigests: invalidations.removedProviderDigests,
            removedModelEndpointDigests: invalidations.removedEndpointDigests,
            removedModelEndpointTypeDigests: invalidations.removedEndpointTypeDigests,
            removedModelGitHubOAuthDigests: invalidations.removedGitHubOAuthDigests,
            removedModelAPIKeyDigests: invalidations.removedAPIKeyDigests
        ))

        #expect(state.modelProviders[model] == nil)
        #expect(state.modelEndpoints[model] == nil)
        #expect(state.modelEndpointTypes[model] == nil)
        #expect(state.modelUsesGitHubOAuth[model] == nil)
        #expect(state.modelAPIKeys[model] == nil)

        state.merge(WatchModelMetadataPage(
            modelProviders: [model: "anthropic"],
            modelEndpoints: [model: "https://new.example"],
            modelEndpointTypes: [model: "messages"],
            modelUsesGitHubOAuth: [model: true],
            modelAPIKeys: [model: "new-key"],
            removedModelProviderDigests: invalidations.removedProviderDigests,
            removedModelEndpointDigests: invalidations.removedEndpointDigests,
            removedModelEndpointTypeDigests: invalidations.removedEndpointTypeDigests,
            removedModelGitHubOAuthDigests: invalidations.removedGitHubOAuthDigests,
            removedModelAPIKeyDigests: invalidations.removedAPIKeyDigests
        ))

        #expect(state.modelProviders[model] == "anthropic")
        #expect(state.modelEndpoints[model] == "https://new.example")
        #expect(state.modelEndpointTypes[model] == "messages")
        #expect(state.modelUsesGitHubOAuth[model] == true)
        #expect(state.modelAPIKeys[model] == "new-key")
    }

    @Test
    func `provisional metadata removes retired model credentials immediately`() {
        let removedModel = "removed-model"
        let retainedModel = "retained-model"
        var state = WatchModelMetadataState(
            selectedModel: removedModel,
            availableModels: [removedModel, retainedModel],
            customModels: [removedModel, retainedModel],
            defaultProvider: "openai",
            modelProviders: [removedModel: "openai", retainedModel: "anthropic"],
            modelEndpoints: [removedModel: "https://removed.example", retainedModel: "https://retained.example"],
            modelEndpointTypes: [removedModel: "responses", retainedModel: "messages"],
            modelUsesGitHubOAuth: [removedModel: false, retainedModel: false],
            modelAPIKeys: [removedModel: "revoked-key", retainedModel: "retained-key"]
        )
        let epoch = UUID()
        let pageContext: [String: Any] = [
            WatchContextKeys.selectedModel: retainedModel,
            WatchContextKeys.removedModelDigests: [WatchModelIdentity.digest(removedModel)],
            WatchContextKeys.modelMetadataEpoch: epoch.uuidString
        ]
        let page = WatchModelMetadataPage(context: pageContext)

        state.merge(page)

        #expect(state.selectedModel == retainedModel)
        #expect(state.availableModels == [retainedModel])
        #expect(state.customModels == [retainedModel])
        #expect(state.modelProviders[removedModel] == nil)
        #expect(state.modelEndpoints[removedModel] == nil)
        #expect(state.modelEndpointTypes[removedModel] == nil)
        #expect(state.modelUsesGitHubOAuth[removedModel] == nil)
        #expect(state.modelAPIKeys[removedModel] == nil)
        #expect(state.modelAPIKeys[retainedModel] == "retained-key")
        #expect(pageContext[WatchContextKeys.modelMetadataEpoch] as? String == epoch.uuidString)

        state.resetModelSpecificState()
        #expect(state.selectedModel.isEmpty)
        #expect(state.availableModels.isEmpty)
        #expect(state.modelAPIKeys.isEmpty)
    }

    @Test
    func `provisional metadata revokes fields while retaining the model`() {
        let model = "retained-model"
        var tracker = WatchModelRemovalTracker()
        _ = tracker.publication(inventory: WatchModelMetadataInventory(
            modelIDs: [model],
            providerModelIDs: [model],
            endpointModelIDs: [model],
            endpointTypeModelIDs: [model],
            gitHubOAuthModelIDs: [model],
            apiKeyModelIDs: [model]
        ))
        let removals = tracker.publication(inventory: WatchModelMetadataInventory(
            modelIDs: [model],
            providerModelIDs: [model],
            endpointModelIDs: [],
            endpointTypeModelIDs: [],
            gitHubOAuthModelIDs: [],
            apiKeyModelIDs: []
        ))
        var state = WatchModelMetadataState(
            selectedModel: model,
            availableModels: [model],
            customModels: [model],
            defaultProvider: "openai",
            modelProviders: [model: "openai"],
            modelEndpoints: [model: "https://removed.example"],
            modelEndpointTypes: [model: "responses"],
            modelUsesGitHubOAuth: [model: true],
            modelAPIKeys: [model: "revoked-key"]
        )
        state.merge(WatchModelMetadataPage(context: [
            WatchContextKeys.selectedModel: model,
            WatchContextKeys.availableModels: [model],
            WatchContextKeys.customModels: [model],
            WatchContextKeys.modelProviders: [model: "openai"],
            WatchContextKeys.removedModelEndpointDigests: removals.removedEndpointDigests,
            WatchContextKeys.removedModelEndpointTypeDigests: removals.removedEndpointTypeDigests,
            WatchContextKeys.removedModelGitHubOAuthDigests: removals.removedGitHubOAuthDigests,
            WatchContextKeys.removedModelAPIKeyDigests: removals.removedAPIKeyDigests
        ]))

        #expect(state.availableModels == [model])
        #expect(state.modelProviders[model] == "openai")
        #expect(state.modelEndpoints[model] == nil)
        #expect(state.modelEndpointTypes[model] == nil)
        #expect(state.modelUsesGitHubOAuth[model] == nil)
        #expect(state.modelAPIKeys[model] == nil)
    }

    private func modelInventory(_ models: [String]) -> WatchModelMetadataInventory {
        WatchModelMetadataInventory(
            modelIDs: models,
            providerModelIDs: [],
            endpointModelIDs: [],
            endpointTypeModelIDs: [],
            gitHubOAuthModelIDs: [],
            apiKeyModelIDs: []
        )
    }
}

@Suite("Watch page cycle coordinator tests", .tags(.fast))
struct WatchPageCycleCoordinatorTests {
    @Test
    func `phone continuation does not skip an unacknowledged page and repeats exact prior pages`() {
        let cycleID = UUID()
        let sourceID = UUID()
        let firstCursor = WatchSyncPageCycleCursor.initial
        let expectedSecondCursor = WatchSyncPageCycleCursor(
            pageIndex: 1,
            manifestOffset: 32,
            configurationOffset: 32,
            tombstoneOffset: 32
        )
        var coordinator = WatchPhonePageCycleCoordinator()

        #expect(coordinator.beginCycle(id: cycleID) == firstCursor)
        coordinator.recordPublished(
            WatchSyncPageCycleMetadata(
                cycleID: cycleID,
                sourceID: sourceID,
                snapshotRevision: 10,
                cursor: firstCursor,
                manifest: WatchSyncPageSection(
                    offset: 0,
                    itemCount: 32,
                    totalCount: 80
                ),
                configurations: WatchSyncPageSection(
                    offset: 0,
                    itemCount: 32,
                    totalCount: 80
                ),
                tombstones: WatchSyncPageSection(
                    offset: 0,
                    itemCount: 32,
                    totalCount: 70
                )
            )
        )

        let skipped = WatchSyncPageCycleRequest(
            cycleID: cycleID,
            cursor: WatchSyncPageCycleCursor(
                pageIndex: 2,
                manifestOffset: 64,
                configurationOffset: 64,
                tombstoneOffset: 64
            )
        )
        let repeated = WatchSyncPageCycleRequest(cycleID: cycleID, cursor: firstCursor)
        let exact = WatchSyncPageCycleRequest(cycleID: cycleID, cursor: expectedSecondCursor)

        #expect(coordinator.publication(for: skipped) == expectedSecondCursor)
        #expect(coordinator.publication(for: repeated) == firstCursor)
        #expect(coordinator.publication(for: exact) == expectedSecondCursor)
    }

    @Test
    func `new state cycle retires continuation requests from the prior cycle`() {
        let oldCycleID = UUID()
        let newCycleID = UUID()
        let oldFirst = WatchSyncPageCycleCursor.initial
        let oldSecond = WatchSyncPageCycleCursor(
            pageIndex: 1,
            manifestOffset: 32,
            configurationOffset: 32,
            tombstoneOffset: 32
        )
        var coordinator = WatchPhonePageCycleCoordinator()
        _ = coordinator.beginCycle(id: oldCycleID)
        coordinator.recordPublished(
            makePageCycleMetadata(
                cycleID: oldCycleID,
                sourceID: UUID(),
                revision: 1,
                cursor: oldFirst,
                itemCount: 32,
                totalCount: 80
            )
        )

        #expect(coordinator.beginCycle(id: newCycleID) == .initial)
        let staleRequest = WatchSyncPageCycleRequest(
            cycleID: oldCycleID,
            cursor: oldSecond
        )

        #expect(coordinator.publicationRequest(for: staleRequest) == WatchSyncPageCycleRequest(
            cycleID: newCycleID,
            cursor: .initial
        ))
    }

    @Test
    func `durable page one after restart requests one fresh cycle`() throws {
        let cycleID = UUID()
        let sourceID = UUID()
        let pageZero = makePageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            revision: 40,
            cursor: .initial,
            itemCount: 32,
            totalCount: 80
        )
        let pageOneCursor = try #require(pageZero.nextCursor)
        let pageOne = makePageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            revision: 41,
            cursor: pageOneCursor,
            itemCount: 32,
            totalCount: 80
        )
        var beforeRestart = WatchPageCycleCoordinator()

        #expect(beforeRestart.receive(pageZero, after: .applied).acceptedPage)
        #expect(beforeRestart.receive(pageOne, after: .applied).acceptedPage)

        var afterRestart = WatchPageCycleCoordinator()
        let recovery = afterRestart.receive(pageOne, after: .alreadyDurable)

        #expect(!recovery.acceptedPage)
        #expect(recovery.pendingRequest == nil)
        #expect(recovery.requiresFreshCycle)

        let repeatedContext = afterRestart.receive(pageOne, after: .alreadyDurable)
        #expect(!repeatedContext.requiresFreshCycle)
        #expect(repeatedContext.pendingRequest == nil)
    }

    @Test
    func `watch requests the missing exact page and stops only after cycle completion`() throws {
        let cycleID = UUID()
        let sourceID = UUID()
        let first = makePageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            revision: 20,
            cursor: .initial,
            itemCount: 32,
            totalCount: 80
        )
        let secondCursor = try #require(first.nextCursor)
        let second = makePageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            revision: 23,
            cursor: secondCursor,
            itemCount: 32,
            totalCount: 80
        )
        let thirdCursor = try #require(second.nextCursor)
        let skippedThird = makePageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            revision: 21,
            cursor: thirdCursor,
            itemCount: 16,
            totalCount: 80
        )
        let repeatedFirst = makePageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            revision: 22,
            cursor: .initial,
            itemCount: 32,
            totalCount: 80
        )
        let finalThird = makePageCycleMetadata(
            cycleID: cycleID,
            sourceID: sourceID,
            revision: 24,
            cursor: thirdCursor,
            itemCount: 16,
            totalCount: 80
        )
        var coordinator = WatchPageCycleCoordinator()

        #expect(coordinator.receive(first) == WatchSyncPageCycleRequest(
            cycleID: cycleID,
            cursor: secondCursor
        ))
        #expect(coordinator.receive(skippedThird) == WatchSyncPageCycleRequest(
            cycleID: cycleID,
            cursor: secondCursor
        ))
        #expect(coordinator.receive(repeatedFirst) == WatchSyncPageCycleRequest(
            cycleID: cycleID,
            cursor: secondCursor
        ))
        #expect(coordinator.receive(second) == WatchSyncPageCycleRequest(
            cycleID: cycleID,
            cursor: thirdCursor
        ))
        #expect(coordinator.receive(finalThird) == nil)
        #expect(coordinator.pendingRequest == nil)
    }

    @Test
    func `watch page cycle keeps stale revision fences while accepting a new source`() throws {
        let originalCycleID = UUID()
        let replacementCycleID = UUID()
        let originalSourceID = UUID()
        let replacementSourceID = UUID()
        let original = makePageCycleMetadata(
            cycleID: originalCycleID,
            sourceID: originalSourceID,
            revision: 50,
            cursor: .initial,
            itemCount: 32,
            totalCount: 80
        )
        let stale = makePageCycleMetadata(
            cycleID: UUID(),
            sourceID: originalSourceID,
            revision: 49,
            cursor: .initial,
            itemCount: 32,
            totalCount: 80
        )
        let replacement = makePageCycleMetadata(
            cycleID: replacementCycleID,
            sourceID: replacementSourceID,
            revision: 1,
            cursor: .initial,
            itemCount: 32,
            totalCount: 80
        )
        var coordinator = WatchPageCycleCoordinator()
        let originalRequest = coordinator.receive(original)

        #expect(coordinator.receive(stale) == originalRequest)
        #expect(try coordinator.receive(replacement) == WatchSyncPageCycleRequest(
            cycleID: replacementCycleID,
            cursor: #require(replacement.nextCursor)
        ))
    }

    @Test
    func `eighty conversations configurations and tombstones complete one explicit page cycle`() throws {
        let conversations = (0 ..< 80).map { index in
            Conversation(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0005-0000-%012d",
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
                    format: "00000000-0000-0006-0000-%012d",
                    index + 1
                ))!,
                WatchSyncRevision(index + 1)
            )
        })
        let state = PhoneWatchSyncState(
            conversations: conversations,
            tombstoneRevisions: tombstones
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumManifestConversationIDs = 32
        configuration.maximumConversationConfigurations = 32
        configuration.maximumTombstones = 32
        configuration.byteBudget = 30000
        let cycleID = UUID()
        let sourceID = UUID()
        var phone = WatchPhonePageCycleCoordinator()
        var watch = WatchPageCycleCoordinator()
        var publication = WatchSyncPageCycleRequest(
            cycleID: cycleID,
            cursor: phone.beginCycle(id: cycleID)
        )
        var revision: WatchSyncRevision = 100
        var revisions: [WatchSyncRevision] = []
        var manifestIDs: Set<UUID> = []
        var configurationIDs: Set<UUID> = []
        var tombstoneIDs: Set<UUID> = []

        for _ in 0 ..< 10 {
            let page = try WatchSyncPayloadBuilder.buildPageCycle(
                state: state,
                sourceID: sourceID,
                snapshotRevision: revision,
                cycleID: publication.cycleID,
                cursor: publication.cursor,
                configuration: configuration
            )
            revisions.append(page.snapshot.revision)
            manifestIDs.formUnion(page.snapshot.authoritativeConversationIDs)
            configurationIDs.formUnion(page.snapshot.conversationConfigurations.map(\.id))
            tombstoneIDs.formUnion(page.snapshot.tombstones.map(\.conversationID))
            phone.recordPublished(page.metadata)

            guard let request = watch.receive(page.metadata) else { break }
            publication = try #require(phone.publicationRequest(for: request))
            revision += 1
        }

        #expect(manifestIDs == Set(conversations.map(\.id)))
        #expect(configurationIDs == Set(conversations.map(\.id)))
        #expect(tombstoneIDs == Set(tombstones.keys))
        #expect(revisions == [100, 101, 102])
        #expect(watch.pendingRequest == nil)
    }

    @Test
    func `completed shorter sections stay empty while longer sections continue`() throws {
        let conversations = (0 ..< 80).map { index in
            Conversation(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0007-0000-%012d",
                    index + 1
                ))!,
                title: "Conversation \(index)",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                model: "model"
            )
        }
        let tombstones = Dictionary(uniqueKeysWithValues: (0 ..< 33).map { index in
            (
                UUID(uuidString: String(
                    format: "00000000-0000-0008-0000-%012d",
                    index + 1
                ))!,
                WatchSyncRevision(index + 1)
            )
        })
        let state = PhoneWatchSyncState(
            conversations: conversations,
            tombstoneRevisions: tombstones
        )
        var configuration = WatchSyncPayloadConfiguration.default
        configuration.maximumConversations = 0
        configuration.maximumManifestConversationIDs = 32
        configuration.maximumConversationConfigurations = 32
        configuration.maximumTombstones = 32
        configuration.byteBudget = 30000
        let cycleID = UUID()
        let sourceID = UUID()
        var phone = WatchPhonePageCycleCoordinator()
        var watch = WatchPageCycleCoordinator()
        var publication = WatchSyncPageCycleRequest(
            cycleID: cycleID,
            cursor: phone.beginCycle(id: cycleID)
        )
        var revision: WatchSyncRevision = 200
        var finalPage: WatchSyncPageCyclePayload?

        for _ in 0 ..< 10 {
            let page = try WatchSyncPayloadBuilder.buildPageCycle(
                state: state,
                sourceID: sourceID,
                snapshotRevision: revision,
                cycleID: publication.cycleID,
                cursor: publication.cursor,
                configuration: configuration
            )
            finalPage = page
            phone.recordPublished(page.metadata)
            guard let request = watch.receive(page.metadata) else { break }
            publication = try #require(phone.publicationRequest(for: request))
            revision += 1
        }

        let completed = try #require(finalPage)
        #expect(completed.metadata.cursor.pageIndex == 2)
        #expect(completed.metadata.tombstones.offset == 33)
        #expect(completed.snapshot.tombstones.isEmpty)
        #expect(completed.metadata.tombstones.itemCount == 0)
        #expect(watch.pendingRequest == nil)
    }
}

@Suite("Watch page cycle handshake tests", .tags(.fast))
struct WatchPageCycleHandshakeTests {
    @Test
    func `standalone identity preserves retries and page cycles reset the fence`() {
        let firstSource = UUID()
        let replacementSource = UUID()
        var tracker = WatchPageCycleHandshakeTracker()

        let first = tracker.disposition(
            sourceID: firstSource,
            snapshotRevision: 1,
            pendingRequest: nil
        )
        let duplicateWithRetry = tracker.disposition(
            sourceID: firstSource,
            snapshotRevision: 1,
            pendingRequest: .freshCycle
        )
        let duplicateWithoutRetry = tracker.disposition(
            sourceID: firstSource,
            snapshotRevision: 1,
            pendingRequest: nil
        )
        let replacementSourceSameRevision = tracker.disposition(
            sourceID: replacementSource,
            snapshotRevision: 1,
            pendingRequest: nil
        )
        tracker.pageCycleReceived()
        let afterPage = tracker.disposition(
            sourceID: replacementSource,
            snapshotRevision: 1,
            pendingRequest: nil
        )
        tracker.reset()
        let afterReset = tracker.disposition(
            sourceID: replacementSource,
            snapshotRevision: 1,
            pendingRequest: nil
        )

        #expect(first == .requestFreshCycle)
        #expect(duplicateWithRetry == .preservePendingFreshCycle)
        #expect(duplicateWithoutRetry == .retireWithoutRequest)
        #expect(replacementSourceSameRevision == .requestFreshCycle)
        #expect(afterPage == .requestFreshCycle)
        #expect(afterReset == .requestFreshCycle)
    }
}

@Suite("Watch page cycle retry tests", .tags(.fast))
@MainActor
struct WatchPageCycleRetryTests {
    @Test
    func `lost publication repeats one exact request with bounded backoff until cancellation`() async {
        let sleeper = TestPageCycleRetrySleeper()
        let controller = WatchPageCycleRequestRetryController { delay in
            try await sleeper.sleep(for: delay)
        }
        let request = WatchSyncPageCycleRequest(
            cycleID: UUID(),
            cursor: WatchSyncPageCycleCursor(
                pageIndex: 2,
                manifestOffset: 64,
                configurationOffset: 48,
                tombstoneOffset: 32
            )
        )
        let requestIdentity = WatchSyncRequestIdentity.pageCycle(request)
        var resentRequests: [WatchSyncRequestIdentity] = []
        let resend: @MainActor @Sendable (WatchSyncRequestIdentity) -> Void = { request in
            resentRequests.append(request)
        }

        controller.retain(requestIdentity, resend: resend)
        await sleeper.waitForPendingSleepCount(1)
        controller.retain(requestIdentity, resend: resend)

        #expect(sleeper.delays == [5])
        #expect(sleeper.pendingSleepCount == 1)

        sleeper.resumeNext()
        await sleeper.waitForPendingSleepCount(1)
        await waitUntil { resentRequests.count == 1 }

        #expect(resentRequests == [requestIdentity])
        #expect(sleeper.delays == [5, 10])

        sleeper.resumeNext()
        await sleeper.waitForPendingSleepCount(1)
        await waitUntil { resentRequests.count == 2 }

        #expect(resentRequests == [requestIdentity, requestIdentity])
        #expect(sleeper.delays == [5, 10, 20])

        controller.retain(nil, resend: resend)
        sleeper.resumeAll()
        await Task.yield()

        #expect(controller.pendingRequest == nil)
        #expect(resentRequests == [requestIdentity, requestIdentity])
        #expect(WatchPageCycleRetryBackoff.seconds(forAttempt: 20) == 60)
    }

    @Test
    func `lost fresh-cycle publication retries until the first page replaces the handshake`() async {
        let sleeper = TestPageCycleRetrySleeper()
        let controller = WatchPageCycleRequestRetryController { delay in
            try await sleeper.sleep(for: delay)
        }
        let freshCycle = WatchSyncRequestIdentity.freshCycle
        let nextPage = WatchSyncRequestIdentity.pageCycle(WatchSyncPageCycleRequest(
            cycleID: UUID(),
            cursor: WatchSyncPageCycleCursor(
                pageIndex: 1,
                manifestOffset: 32,
                configurationOffset: 32,
                tombstoneOffset: 0
            )
        ))
        var resentRequests: [WatchSyncRequestIdentity] = []
        let resend: @MainActor @Sendable (WatchSyncRequestIdentity) -> Void = { request in
            resentRequests.append(request)
        }

        controller.retain(freshCycle, resend: resend)
        await sleeper.waitForPendingSleepCount(1)
        sleeper.resumeNext()
        await sleeper.waitForPendingSleepCount(1)
        await waitUntil { resentRequests == [freshCycle] }

        controller.retain(nextPage, resend: resend)
        await sleeper.waitForPendingSleepCount(2)
        sleeper.resumeNext()
        await Task.yield()

        #expect(resentRequests == [freshCycle])
        #expect(controller.pendingRequest == nextPage)

        sleeper.resumeNext()
        await sleeper.waitForPendingSleepCount(1)
        await waitUntil { resentRequests == [freshCycle, nextPage] }

        #expect(sleeper.delays == [5, 10, 5, 10])

        controller.cancel()
        sleeper.resumeAll()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }
}

@Suite("Watch legacy message paging tests", .tags(.fast))
struct WatchLegacyMessagePagingTests {
    @Test
    @MainActor
    func `legacy message deltas page behind durable echoes without duplicate sends`() throws {
        let suiteName = "WatchLegacyMessagePagingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let conversationID = UUID()
        let messages = (0 ..< 25).map { index in
            WatchMessage(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    index + 1
                ))!,
                role: Message.Role.user.rawValue,
                content: "message-\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }
        let conversation = WatchConversation(
            id: conversationID,
            title: "Paged legacy messages",
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 25),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 25
        )
        let mutation = WatchConversationMutation(
            revision: 25,
            conversation: conversation,
            fields: [.messages],
            messageChanges: messages,
            messageChangeRevisions: Dictionary(
                uniqueKeysWithValues: messages.enumerated().map { index, message in
                    (message.id, WatchSyncRevision(index + 1))
                }
            )
        )

        let firstSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let firstComponentIDs = firstSend.userInfos.compactMap {
            $0[WatchMessageKeys.legacyComponentId] as? String
        }
        #expect(firstComponentIDs.count == 20)
        #expect(firstSend.userInfos.compactMap {
            $0[WatchMessageKeys.messageId] as? String
        } == messages.prefix(20).map(\.id.uuidString))

        for componentID in firstComponentIDs.prefix(20) {
            tracker.recordTransferCompletion(componentID: componentID, succeeded: true)
        }
        let beforeFirstEcho = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        #expect(beforeFirstEcho.userInfos.isEmpty)
        #expect(beforeFirstEcho.awaitingEchoComponentIDs == Set(firstComponentIDs.prefix(20)))

        var firstEcho = conversation
        firstEcho.messages = Array(messages.prefix(20))
        let firstReconciliation = tracker.reconcile(
            mutation,
            echoedConversations: [firstEcho]
        )
        var cumulativeCoverage = WatchMutationDeliveryCoverage()
        for component in firstReconciliation.matchedComponents {
            tracker.confirm(component.deliveryUserInfo(for: mutation))
            if case let .message(messageID, revision) = component {
                cumulativeCoverage.messageRevisions[messageID] = revision
            }
        }
        #expect(!WatchLegacyEchoReconciler.canAcknowledge(
            mutation,
            currentMatches: firstReconciliation.matchedComponents,
            durableCoverage: cumulativeCoverage
        ))

        let secondSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let secondComponentIDs = secondSend.userInfos.compactMap {
            $0[WatchMessageKeys.legacyComponentId] as? String
        }
        #expect(secondComponentIDs.count == 5)
        #expect(secondSend.userInfos.compactMap {
            $0[WatchMessageKeys.messageId] as? String
        } == messages.suffix(5).map(\.id.uuidString))
        let allSentComponentIDs = firstComponentIDs + secondComponentIDs
        #expect(Set(allSentComponentIDs).count == allSentComponentIDs.count)

        for componentID in secondComponentIDs {
            tracker.recordTransferCompletion(componentID: componentID, succeeded: true)
        }
        let beforeSecondEcho = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        #expect(beforeSecondEcho.userInfos.isEmpty)
        #expect(beforeSecondEcho.awaitingEchoComponentIDs == Set(secondComponentIDs))

        var secondEcho = conversation
        secondEcho.messages = Array(messages.suffix(20))
        let secondReconciliation = tracker.reconcile(
            mutation,
            echoedConversations: [secondEcho]
        )
        for component in secondReconciliation.matchedComponents {
            tracker.confirm(component.deliveryUserInfo(for: mutation))
            if case let .message(messageID, revision) = component {
                cumulativeCoverage.messageRevisions[messageID] = revision
            }
        }

        #expect(WatchLegacyEchoReconciler.canAcknowledge(
            mutation,
            currentMatches: secondReconciliation.matchedComponents,
            durableCoverage: cumulativeCoverage
        ))
        let afterCumulativeEcho = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        #expect(afterCumulativeEcho.userInfos.isEmpty)
        #expect(afterCumulativeEcho.awaitingEchoComponentIDs.isEmpty)
    }

    @Test
    @MainActor
    func `legacy batching advances past an early awaiting echo without retransmission`() throws {
        let suiteName = "WatchLegacyMessagePagingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let tracker = WatchLegacyDeliveryTracker(
            userDefaults: defaults,
            persistenceKey: "state"
        )
        let messages = (0 ..< 25).map { index in
            WatchMessage(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0000-0001-%012d",
                    index + 1
                ))!,
                role: Message.Role.user.rawValue,
                content: "message-\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }
        let conversation = WatchConversation(
            id: UUID(),
            title: "Bounded suffix",
            model: "model",
            updatedAt: Date(timeIntervalSince1970: 25),
            createdAt: Date(timeIntervalSince1970: 1),
            watchRevision: 25
        )
        let mutation = WatchConversationMutation(
            revision: 25,
            conversation: conversation,
            fields: [.messages],
            messageChanges: messages,
            messageChangeRevisions: Dictionary(
                uniqueKeysWithValues: messages.enumerated().map { index, message in
                    (message.id, WatchSyncRevision(index + 1))
                }
            )
        )

        let firstSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let firstComponentIDs = firstSend.userInfos.compactMap {
            $0[WatchMessageKeys.legacyComponentId] as? String
        }
        #expect(firstComponentIDs.count == 20)
        for componentID in firstComponentIDs {
            tracker.recordTransferCompletion(componentID: componentID, succeeded: true)
        }
        for index in 1 ..< 20 {
            tracker.confirm(WatchLegacyEchoComponent.message(
                id: messages[index].id,
                revision: WatchSyncRevision(index + 1)
            ).deliveryUserInfo(for: mutation))
        }

        let nextSend = try WatchLegacyMutationSender.prepare(mutation, tracker: tracker)
        let nextMessageIDs = nextSend.userInfos.compactMap {
            $0[WatchMessageKeys.messageId] as? String
        }

        #expect(nextMessageIDs == messages.suffix(5).map(\.id.uuidString))
        #expect(nextSend.awaitingEchoComponentIDs == [firstComponentIDs[0]])
        #expect(!nextSend.componentIDs.contains(firstComponentIDs[0]))
        #expect(nextSend.userInfos.count + nextSend.awaitingEchoComponentIDs.count <= 20)
    }
}

@Suite("Watch mutation ingress validation tests", .tags(.fast))
struct WatchMutationIngressValidationTests {
    @Test
    func `mutation ingress accepts supported schemas and rejects malformed or future versions`() {
        for schemaVersion in 1 ... WatchSyncSnapshot.currentSchemaVersion {
            #expect(WatchMutationIngressValidator.validate(
                schemaVersion: NSNumber(value: schemaVersion),
                fields: [.messages]
            ) == .accepted(schemaVersion: schemaVersion))
        }

        let malformedSchemas: [Any?] = [
            nil,
            "1",
            true,
            NSNumber(value: 0),
            NSNumber(value: -1),
            NSNumber(value: 1.5)
        ]
        for schemaVersion in malformedSchemas {
            #expect(WatchMutationIngressValidator.validate(
                schemaVersion: schemaVersion,
                fields: [.messages]
            ) == .rejected(.malformedSchema))
        }

        let futureSchema = WatchSyncSnapshot.currentSchemaVersion + 1
        #expect(WatchMutationIngressValidator.validate(
            schemaVersion: NSNumber(value: futureSchema),
            fields: [.messages]
        ) == .rejected(.unsupportedSchema(futureSchema)))
    }

    @Test
    func `mutation ingress rejects an empty field mask before reduction`() {
        #expect(WatchMutationIngressValidator.validate(
            schemaVersion: NSNumber(value: WatchSyncSnapshot.currentSchemaVersion),
            fields: []
        ) == .rejected(.emptyFieldMask))
    }

    @Test
    func `mutation ingress rejects unknown field mask bits before reduction`() {
        let unknownBit: UInt8 = 1 << 7
        for fields in [
            WatchConversationMutationFields(rawValue: unknownBit),
            WatchConversationMutationFields.messages.union(
                WatchConversationMutationFields(rawValue: unknownBit)
            )
        ] {
            #expect(WatchMutationIngressValidator.validate(
                schemaVersion: NSNumber(value: WatchSyncSnapshot.currentSchemaVersion),
                fields: fields
            ) == .rejected(.unknownFieldMask(unknownBit)))
        }
    }

    @Test
    func `unsupported mutation reply cannot acknowledge the durable outbox`() {
        let mutation = makeLegacyMessageMutation(content: "Unsupported")

        let reply = WatchMutationReply.unsupported(for: mutation).message

        #expect(reply[WatchMessageKeys.status] as? String == "unsupported")
        #expect(reply[WatchMessageKeys.operationId] as? String == mutation.operationID.uuidString)
        #expect(reply[WatchMessageKeys.conversationId] as? String == mutation.conversationID.uuidString)
        #expect(reply[WatchMessageKeys.acknowledgedRevision] == nil)
    }
}

@Suite("Watch mutation file transport tests", .tags(.fast))
struct WatchMutationFileTransportTests {
    @Test
    func `stale sessions and malformed metadata are rejected before file inspection`() {
        let missingFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mutation = makeLegacyMessageMutation(content: "metadata fence")

        expectWatchMutationFileError(.staleSession) {
            _ = try WatchMutationFileTransport.receive(
                fileURL: missingFileURL,
                metadata: [:],
                sessionIsCurrent: false
            )
        }

        var malformedMetadata = mutationFileMetadata(for: mutation)
        malformedMetadata.removeValue(forKey: WatchMessageKeys.operationId)
        expectWatchMutationFileError(.invalidMetadata) {
            _ = try WatchMutationFileTransport.receive(
                fileURL: missingFileURL,
                metadata: malformedMetadata,
                sessionIsCurrent: true
            )
        }
    }

    @Test
    func `oversized mutation files are rejected from resource size`() throws {
        let mutation = makeLegacyMessageMutation(content: "oversized")
        let fileURL = try temporaryMutationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        #expect(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.truncate(
            atOffset: UInt64(WatchMutationFileTransport.maximumBytes + 1)
        )
        try fileHandle.close()

        expectWatchMutationFileError(.exceedsMaximum(
            actualBytes: WatchMutationFileTransport.maximumBytes + 1,
            maximumBytes: WatchMutationFileTransport.maximumBytes
        )) {
            _ = try WatchMutationFileTransport.receive(
                fileURL: fileURL,
                metadata: mutationFileMetadata(for: mutation),
                sessionIsCurrent: true
            )
        }
    }

    @Test
    func `malformed mutation files and metadata identity mismatches are rejected`() throws {
        let mutation = makeLegacyMessageMutation(content: "malformed")
        let malformedFileURL = try temporaryMutationFileURL()
        let mismatchedFileURL = try temporaryMutationFileURL()
        defer {
            try? FileManager.default.removeItem(at: malformedFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: mismatchedFileURL.deletingLastPathComponent())
        }

        try Data("not-json".utf8).write(to: malformedFileURL)
        expectWatchMutationFileError(.malformedPayload) {
            _ = try WatchMutationFileTransport.receive(
                fileURL: malformedFileURL,
                metadata: mutationFileMetadata(for: mutation),
                sessionIsCurrent: true
            )
        }

        try WatchSyncPayloadBuilder.encodeMutation(mutation).write(to: mismatchedFileURL)
        var mismatchedMetadata = mutationFileMetadata(for: mutation)
        mismatchedMetadata[WatchMessageKeys.operationId] = UUID().uuidString
        expectWatchMutationFileError(.metadataIdentityMismatch) {
            _ = try WatchMutationFileTransport.receive(
                fileURL: mismatchedFileURL,
                metadata: mismatchedMetadata,
                sessionIsCurrent: true
            )
        }
    }

    @Test
    func `valid mutation file at the hard boundary is accepted`() throws {
        let mutation = makeLegacyMessageMutation(content: "boundary")
        var data = try WatchSyncPayloadBuilder.encodeMutation(mutation)
        #expect(data.count < WatchMutationFileTransport.maximumBytes)
        data.append(Data(
            repeating: 0x20,
            count: WatchMutationFileTransport.maximumBytes - data.count
        ))
        let fileURL = try temporaryMutationFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try data.write(to: fileURL)

        let received = try WatchMutationFileTransport.receive(
            fileURL: fileURL,
            metadata: mutationFileMetadata(for: mutation),
            sessionIsCurrent: true
        )

        #expect(received.mutation == mutation)
        #expect(received.schemaVersion == WatchSyncSnapshot.currentSchemaVersion)
        #expect(received.byteCount == WatchMutationFileTransport.maximumBytes)
    }

    @Test
    func `outgoing mutation files enforce the ingress hard maximum`() throws {
        let mutation = makeLegacyMessageMutation(
            content: String(
                repeating: "x",
                count: WatchMutationFileTransport.maximumBytes + 1
            )
        )
        let encoded = try WatchSyncPayloadBuilder.encodeMutation(mutation)
        #expect(encoded.count > WatchMutationFileTransport.maximumBytes)

        expectWatchMutationFileError(.exceedsMaximum(
            actualBytes: encoded.count,
            maximumBytes: WatchMutationFileTransport.maximumBytes
        )) {
            _ = try WatchMutationFileTransport.encodedData(for: mutation)
        }
    }
}

private func modelMetadataState(model: String, key: String) -> WatchModelMetadataState {
    WatchModelMetadataState(
        selectedModel: model,
        availableModels: [model],
        customModels: [model],
        defaultProvider: "openai",
        modelProviders: [model: "openai"],
        modelEndpoints: [model: "https://example.com/v1"],
        modelEndpointTypes: [model: "responses"],
        modelUsesGitHubOAuth: [model: false],
        modelAPIKeys: [model: key]
    )
}

private func makePageCycleMetadata(
    cycleID: UUID,
    sourceID: UUID,
    revision: WatchSyncRevision,
    cursor: WatchSyncPageCycleCursor,
    itemCount: Int,
    totalCount: Int
) -> WatchSyncPageCycleMetadata {
    let section = WatchSyncPageSection(
        offset: cursor.manifestOffset,
        itemCount: itemCount,
        totalCount: totalCount
    )
    return WatchSyncPageCycleMetadata(
        cycleID: cycleID,
        sourceID: sourceID,
        snapshotRevision: revision,
        cursor: cursor,
        manifest: section,
        configurations: WatchSyncPageSection(
            offset: cursor.configurationOffset,
            itemCount: itemCount,
            totalCount: totalCount
        ),
        tombstones: WatchSyncPageSection(
            offset: cursor.tombstoneOffset,
            itemCount: itemCount,
            totalCount: totalCount
        )
    )
}

private func makeLegacyMessageMutation(content: String) -> WatchConversationMutation {
    let message = WatchMessage(
        id: UUID(),
        role: Message.Role.user.rawValue,
        content: content,
        timestamp: Date(timeIntervalSince1970: 20)
    )
    let conversation = WatchConversation(
        id: UUID(),
        title: "Legacy",
        messages: [message],
        model: "model",
        updatedAt: Date(timeIntervalSince1970: 20),
        createdAt: Date(timeIntervalSince1970: 10),
        watchRevision: 1
    )
    return WatchConversationMutation(
        revision: 1,
        conversation: conversation,
        fields: [.messages],
        messageChanges: [message],
        messageChangeRevisions: [message.id: 1]
    )
}

private func mutationFileMetadata(
    for mutation: WatchConversationMutation
) -> [String: Any] {
    [
        WatchMessageKeys.type: WatchMessageKeys.typeMutationFile,
        WatchMessageKeys.operationId: mutation.operationID.uuidString,
        WatchMessageKeys.conversationId: mutation.conversationID.uuidString,
        WatchMessageKeys.schemaVersion: NSNumber(value: WatchSyncSnapshot.currentSchemaVersion)
    ]
}

private func temporaryMutationFileURL() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WatchMutationFileTransportTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
    )
    return directoryURL.appendingPathComponent("mutation.json")
}

private func expectWatchMutationFileError(
    _ expected: WatchMutationFileTransportError,
    performing operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected Watch mutation file error: \(expected)")
    } catch let error as WatchMutationFileTransportError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected Watch mutation file error: \(error)")
    }
}

private struct LegacyTitleDeliveryState: Codable {
    var createdConversationIDs: Set<UUID> = []
    var messageRevisions: [UUID: [UUID: WatchSyncRevision]] = [:]
    var titles: [UUID: String]
    var configurationRevisions: [UUID: WatchSyncRevision] = [:]
}

@MainActor
private final class PendingDestructiveOperationState {
    @Published var count: Int

    init(count: Int) {
        self.count = count
    }
}

@MainActor
private final class TestPageCycleRetrySleeper {
    private(set) var delays: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var pendingSleepCount: Int {
        continuations.count
    }

    func sleep(for delay: TimeInterval) async throws {
        delays.append(delay)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        try Task.checkCancellation()
    }

    func waitForPendingSleepCount(_ count: Int) async {
        for _ in 0 ..< 100 where pendingSleepCount < count {
            await Task.yield()
        }
        #expect(pendingSleepCount == count)
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
private final class TestAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
