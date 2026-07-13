// swiftlint:disable file_length
#if os(watchOS)

    // swiftlint:disable identifier_name type_body_length

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("Watch sync chat view model native tests")
    @MainActor
    struct WatchSyncChatViewModelNativeTests {
        @Test
        func `Request uses durable prompt, effective history, conversation model, and temperature`() async throws {
            let fixture = makeViewModelFixture()
            let callbacks = FlightTestBox<AIServiceResponseSimulationCallbacks?>(nil)
            let aiService = configuredAIService(model: fixture.conversation.model) { _, value in
                callbacks.value = value
            }
            var observed: WatchChatViewModel.RequestConfiguration?
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { observed = $0 }
            )
            WatchConnectivityService.shared.selectedModel = "different-global-model"
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Durable prompt")

            let request = try #require(observed)
            #expect(request.model == fixture.conversation.model)
            #expect(request.temperature == fixture.conversation.temperature)
            #expect(request.conversationID == fixture.conversation.id)
            #expect(request.messages.map(\.role) == [.system, .user])
            #expect(request.messages.first?.content == fixture.conversation.resolvedSystemPrompt)
            #expect(request.messages.last?.content == "Durable prompt")
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.model == request.model)

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            #expect(reloaded.conversation(for: fixture.conversation.id)?.messages.contains {
                $0.role == Message.Role.user.rawValue && $0.content == "Durable prompt"
            } == true)

            let response = try #require(callbacks.value)
            response.onChunk("Answer")
            response.onComplete()
            #expect(await waitUntil { !viewModel.isLoading })
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content == "Answer")
            #expect(fixture.store.pendingMutationsForSync.first?.revision == 2)
        }

        @Test
        func `Re-selecting the same conversation preserves generation and cancellation syncs partial once`() throws {
            let fixture = makeViewModelFixture()
            let callbacks = FlightTestBox<AIServiceResponseSimulationCallbacks?>(nil)
            let aiService = configuredAIService(model: fixture.conversation.model) { _, value in
                callbacks.value = value
            }
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Prompt")
            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.isLoading)

            let response = try #require(callbacks.value)
            response.onChunk("Partial")
            viewModel.cancelRequest()

            #expect(!viewModel.isLoading)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content == "Partial")
            let revisionAfterFirstCancel = fixture.store.pendingMutationsForSync.first?.revision
            #expect(revisionAfterFirstCancel == 2)

            viewModel.cancelRequest()
            #expect(fixture.store.pendingMutationsForSync.first?.revision == revisionAfterFirstCancel)
        }

        @Test
        func `Switching conversations cancels the owned generation`() {
            let fixture = makeViewModelFixture()
            let aiService = configuredAIService(model: fixture.conversation.model) { _, _ in }
            let other = WatchConversation(
                id: UUID(),
                title: "Other",
                model: fixture.conversation.model,
                updatedAt: Date(timeIntervalSince1970: 2),
                createdAt: Date(timeIntervalSince1970: 2)
            )
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [fixture.conversation, other],
                    authoritativeConversationIDs: [fixture.conversation.id, other.id]
                )
            )
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Prompt")
            #expect(viewModel.isLoading)
            viewModel.setConversation(other.id)

            #expect(!viewModel.isLoading)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.role == Message.Role.user.rawValue)
        }

        @Test
        func `Creating a new conversation finalizes and cancels the previous generation`() throws {
            let fixture = makeViewModelFixture()
            let callbacks = FlightTestBox<AIServiceResponseSimulationCallbacks?>(nil)
            let aiService = configuredAIService(model: fixture.conversation.model) { _, value in
                callbacks.value = value
            }
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.selectedModel = fixture.conversation.model
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Prompt")
            let response = try #require(callbacks.value)
            response.onChunk("Partial")

            let newConversationID = try #require(viewModel.createNewConversation())

            #expect(!viewModel.isLoading)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content == "Partial")
            #expect(fixture.store.pendingMutationsForSync.first {
                $0.conversationID == fixture.conversation.id
            }?.revision == 2)
            #expect(fixture.store.conversation(for: newConversationID) != nil)

            response.onChunk(" stale")
            response.onComplete()
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content == "Partial")
        }

        @Test
        func `Pre-output cancellation ignores historical tool activity`() {
            let historicalMessages = [
                WatchMessage(from: Message(role: .user, content: "Earlier prompt")),
                WatchMessage(from: Message(role: .assistant, content: "Earlier answer")),
                WatchMessage(from: Message(role: .tool, content: "Earlier tool result")),
            ]
            let fixture = makeViewModelFixture(messages: historicalMessages)
            let aiService = configuredAIService(model: fixture.conversation.model) { _, _ in }
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Current prompt")
            viewModel.cancelRequest()

            let conversation = fixture.store.conversation(for: fixture.conversation.id)
            #expect(conversation?.messages.count == historicalMessages.count + 1)
            #expect(conversation?.messages.last?.role == Message.Role.user.rawValue)
            #expect(conversation?.messages.last?.content == "Current prompt")
            #expect(fixture.store.pendingMutationsForSync.first {
                $0.conversationID == fixture.conversation.id
            }?.revision == 1)
        }

        @Test
        func `Cancellation preserves tool state from the current request turn`() throws {
            let fixture = makeViewModelFixture()
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Prompt")
            let request = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(request.onToolCallRequested)
            onToolCallRequested("current-call", "unavailable_watch_tool", [:])
            viewModel.cancelRequest()

            let conversation = fixture.store.conversation(for: fixture.conversation.id)
            #expect(conversation?.messages.last?.role == Message.Role.assistant.rawValue)
            #expect(conversation?.messages.last?.content.isEmpty == true)
            #expect(conversation?.messages.last?.toolCalls?.map(\.id) == ["current-call"])
            #expect(fixture.store.pendingMutationsForSync.first {
                $0.conversationID == fixture.conversation.id
            }?.revision == 2)
        }

        @Test
        func `Cancelled response promotion failure retries the same draft`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "Existing",
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "Partial")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let request = try #require(aiService.capturedRequests.value.first)
            request.onChunk("Partial")
            #expect(await waitUntil {
                fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content == "Partial"
            })
            let draft = try #require(fixture.store.conversation(for: fixture.conversation.id))
            let userMessageID = try #require(draft.messages.first?.id)
            let assistantMessageID = try #require(draft.messages.last?.id)

            viewModel.cancelRequest()

            #expect(persistence.rejectedWriteCount == 1)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
            let failedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(failedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(failedConversation.messages.last?.content == "Partial")
            #expect(!fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.id == assistantMessageID
            })

            viewModel.retryFailedMessage()

            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(aiService.capturedRequests.value.count == 1)
            let promotedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(promotedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(promotedConversation.messages.last?.content == "Partial")
            #expect(fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.id == assistantMessageID && $0.content == "Partial"
            })
        }

        @Test
        func `Cancellation flush failure retries full throttled content without another request`() throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "Existing",
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isDraftWrite(data, assistantContent: "First second")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let request = try #require(aiService.capturedRequests.value.first)
            let initialDraft = try #require(fixture.store.conversation(for: fixture.conversation.id))
            let userMessageID = try #require(initialDraft.messages.first?.id)
            let assistantMessageID = try #require(initialDraft.messages.last?.id)
            request.onChunk("First")
            request.onChunk(" second")

            viewModel.cancelRequest()

            #expect(persistence.rejectedWriteCount == 1)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
            #expect(aiService.capturedRequests.value.count == 1)
            let failedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(failedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(failedConversation.messages.last?.content == "First")
            #expect(!fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.id == assistantMessageID
            })

            viewModel.retryFailedMessage()

            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(aiService.capturedRequests.value.count == 1)
            let promotedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(promotedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(promotedConversation.messages.last?.content == "First second")
            let assistantChanges = fixture.store.pendingMutationsForSync
                .flatMap(\.messageChanges)
                .filter { $0.id == assistantMessageID }
            #expect(assistantChanges.count == 1)
            #expect(assistantChanges.first?.content == "First second")
        }

        @Test
        func `Provider error retry starts a new user turn after preserving partial output`() async throws {
            let fixture = makeViewModelFixture(title: "Existing")
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            firstRequest.onChunk("Partial")
            #expect(await waitUntil {
                fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content == "Partial"
            })
            firstRequest.onError(NSError(domain: "Provider", code: 1))
            #expect(await waitUntil { !viewModel.isLoading })

            let failedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(failedConversation.messages.map(\.role) == [
                Message.Role.user.rawValue,
                Message.Role.assistant.rawValue
            ])
            #expect(failedConversation.messages.last?.content == "Partial")

            viewModel.retryFailedMessage()

            #expect(aiService.capturedRequests.value.count == 2)
            let retryRequest = try #require(aiService.capturedRequests.value.last)
            #expect(retryRequest.messages.last?.role == .user)
            #expect(retryRequest.messages.last?.content == "Prompt")
            let retriedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(retriedConversation.messages.map(\.role) == [
                Message.Role.user.rawValue,
                Message.Role.assistant.rawValue,
                Message.Role.user.rawValue,
                Message.Role.assistant.rawValue
            ])
            #expect(retriedConversation.messages[0].id != retriedConversation.messages[2].id)
        }

        @Test
        func `Provider error promotion failure retries the same partial draft`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "Existing",
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "Partial")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let request = try #require(aiService.capturedRequests.value.first)
            request.onChunk("Partial")
            #expect(await waitUntil {
                fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content == "Partial"
            })
            let draft = try #require(fixture.store.conversation(for: fixture.conversation.id))
            let userMessageID = try #require(draft.messages.first?.id)
            let assistantMessageID = try #require(draft.messages.last?.id)
            request.onError(NSError(domain: "Provider", code: 1))

            #expect(await waitUntil { !viewModel.isLoading })
            #expect(persistence.rejectedWriteCount == 1)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
            let failedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(failedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(failedConversation.messages.last?.content == "Partial")

            viewModel.retryFailedMessage()

            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(aiService.capturedRequests.value.count == 1)
            let promotedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(promotedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(promotedConversation.messages.last?.content == "Partial")
            #expect(fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.id == assistantMessageID && $0.content == "Partial"
            })
        }

        @Test
        func `Missing conversation during a tool callback surfaces retry state`() async throws {
            let fixture = makeViewModelFixture(title: "Existing")
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let request = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(request.onToolCallRequested)
            #expect(fixture.store.deleteConversation(fixture.conversation.id))

            onToolCallRequested("missing-conversation", "unavailable_watch_tool", [:])

            #expect(await waitUntil { !viewModel.isLoading })
            #expect(viewModel.errorMessage == "Failed to update conversation. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
        }

        @Test
        func `Message persistence failure rejects the request`() {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(persistenceWriter: { persistence.write($0) })
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            var request: WatchChatViewModel.RequestConfiguration?
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { request = $0 }
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isConversationMessageWrite(
                    data,
                    role: Message.Role.user.rawValue,
                    content: "Prompt"
                )
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .notConsumed)

            #expect(request == nil)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.isEmpty == true)
            #expect(viewModel.errorMessage != nil)

            viewModel.retryFailedMessage()
            #expect(request != nil)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.count {
                $0.role == Message.Role.user.rawValue
            } == 1)
            viewModel.cancelRequest()
        }

        @Test
        func `Assistant draft persistence failure rejects the request`() {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(persistenceWriter: { persistence.write($0) })
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            var request: WatchChatViewModel.RequestConfiguration?
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { request = $0 }
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isDraftWrite(data, assistantContent: "")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .consumed)

            #expect(request == nil)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.map(\.role) == [
                Message.Role.user.rawValue,
            ])
            #expect(viewModel.errorMessage != nil)

            viewModel.retryFailedMessage()
            #expect(request != nil)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.count {
                $0.role == Message.Role.user.rawValue
            } == 1)
            viewModel.cancelRequest()
        }

        @Test
        func `Final response promotion failure stays retryable without generating a title`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "New Chat",
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "Answer")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let generationRequest = try #require(aiService.capturedRequests.value.first)
            generationRequest.onChunk("Answer")
            generationRequest.onComplete()

            #expect(await waitUntil { !viewModel.isLoading })
            #expect(persistence.rejectedWriteCount == 1)
            #expect(aiService.capturedRequests.value.count == 1)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
            let failedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(failedConversation.messages.map(\.role) == [
                Message.Role.user.rawValue,
                Message.Role.assistant.rawValue,
            ])
            #expect(failedConversation.messages.last?.content == "Answer")
            #expect(!fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.role == Message.Role.assistant.rawValue
            })

            viewModel.retryFailedMessage()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            let promotedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(promotedConversation.messages.map(\.role) == [
                Message.Role.user.rawValue,
                Message.Role.assistant.rawValue,
            ])
            #expect(promotedConversation.messages.last?.content == "Answer")
            #expect(fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.role == Message.Role.assistant.rawValue && $0.content == "Answer"
            })
        }

        @Test
        func `Failed final response promotion follows its conversation across switches`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "New Chat",
                persistenceWriter: { persistence.write($0) }
            )
            let otherConversation = WatchConversation(
                id: UUID(),
                title: "Other",
                model: fixture.conversation.model,
                updatedAt: Date(timeIntervalSince1970: 2),
                createdAt: Date(timeIntervalSince1970: 2)
            )
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [fixture.conversation, otherConversation],
                    authoritativeConversationIDs: [fixture.conversation.id, otherConversation.id]
                )
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            var generationRequests: [WatchChatViewModel.RequestConfiguration] = []
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { generationRequests.append($0) }
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "Answer")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let generationRequest = try #require(aiService.capturedRequests.value.first)
            generationRequest.onChunk("Answer")
            generationRequest.onComplete()

            #expect(await waitUntil { !viewModel.isLoading })
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
            #expect(generationRequests.count == 1)

            viewModel.setConversation(otherConversation.id)

            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)

            viewModel.setConversation(fixture.conversation.id)

            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")

            viewModel.retryFailedMessage()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            #expect(generationRequests.count == 1)
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            let promotedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(promotedConversation.messages.map(\.role) == [
                Message.Role.user.rawValue,
                Message.Role.assistant.rawValue,
            ])
            #expect(promotedConversation.messages.last?.content == "Answer")

            let titleRequest = try #require(aiService.capturedRequests.value.last)
            titleRequest.onChunk("Recovered Title")
            #expect(await waitUntil {
                fixture.store.conversation(for: fixture.conversation.id)?.title == "Recovered Title"
            })
        }

        @Test
        func `Successful promotion retry clears only the selected conversation retry`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "First",
                persistenceWriter: { persistence.write($0) }
            )
            let otherConversation = WatchConversation(
                id: UUID(),
                title: "Second",
                model: fixture.conversation.model,
                updatedAt: Date(timeIntervalSince1970: 2),
                createdAt: Date(timeIntervalSince1970: 2)
            )
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [fixture.conversation, otherConversation],
                    authoritativeConversationIDs: [fixture.conversation.id, otherConversation.id]
                )
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "First answer")
            }
            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("First prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            firstRequest.onChunk("First answer")
            firstRequest.onComplete()
            #expect(await waitUntil { !viewModel.isLoading })

            viewModel.setConversation(otherConversation.id)
            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "Second answer")
            }
            #expect(viewModel.sendMessage("Second prompt") == .started)
            let secondRequest = try #require(aiService.capturedRequests.value.last)
            secondRequest.onChunk("Second answer")
            secondRequest.onComplete()
            #expect(await waitUntil { !viewModel.isLoading })

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.failedMessage == "First prompt")
            viewModel.retryFailedMessage()
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)

            viewModel.setConversation(otherConversation.id)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Second prompt")
            viewModel.retryFailedMessage()
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(aiService.capturedRequests.value.count == 2)
        }

        @Test
        func `Cancel and dismiss preserve durable promotion retry ownership`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "Existing",
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.selectedModel = fixture.conversation.model
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "Answer")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let request = try #require(aiService.capturedRequests.value.first)
            request.onChunk("Answer")
            request.onComplete()
            #expect(await waitUntil { !viewModel.isLoading })

            viewModel.cancelRequest()
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")

            viewModel.dismissError()
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)

            let newConversationID = try #require(viewModel.createNewConversation())
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(fixture.store.conversation(for: newConversationID) != nil)

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")

            viewModel.retryFailedMessage()
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(aiService.capturedRequests.value.count == 1)
            #expect(fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.role == Message.Role.assistant.rawValue && $0.content == "Answer"
            })
        }

        @Test
        func `Fallback model persistence failure rejects the request`() {
            let appleModel = "apple-intelligence"
            let configuredModel = "configured-model"
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                model: appleModel,
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: configuredModel)
            aiService.customModels = [appleModel, configuredModel]
            aiService.modelProviders = [
                appleModel: .appleIntelligence,
                configuredModel: .openai,
            ]
            aiService.modelEndpoints = [configuredModel: "http://localhost:11434"]
            aiService.modelAPIKeys = [:]
            var request: WatchChatViewModel.RequestConfiguration?
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { request = $0 }
            )
            WatchConnectivityService.shared.availableModels = [configuredModel]
            persistence.rejectNextWrite { data in
                isConversationModelWrite(
                    data,
                    conversationID: fixture.conversation.id,
                    model: configuredModel
                )
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .consumed)

            #expect(request == nil)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.model == appleModel)
            #expect(viewModel.errorMessage != nil)
        }

        @Test
        func `Apple Intelligence fallback skips unconfigured models`() {
            let appleModel = "apple-intelligence"
            let unconfiguredModel = "unconfigured-model"
            let configuredModel = "configured-model"
            let fixture = makeViewModelFixture(model: appleModel)
            let aiService = configuredCapturingAIService(model: configuredModel)
            aiService.customModels = [appleModel, unconfiguredModel, configuredModel]
            aiService.modelProviders = [
                appleModel: .appleIntelligence,
                unconfiguredModel: .openai,
                configuredModel: .openai,
            ]
            aiService.modelEndpoints = [configuredModel: "http://localhost:11434"]
            aiService.modelAPIKeys = [:]
            var request: WatchChatViewModel.RequestConfiguration?
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { request = $0 }
            )
            WatchConnectivityService.shared.availableModels = [unconfiguredModel, configuredModel]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)

            #expect(request?.model == configuredModel)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.model == configuredModel)
            viewModel.cancelRequest()
        }

        @Test
        func `Conversation creation persistence failure is surfaced without a phantom selection`() throws {
            let persistence = PersistenceTestWriter()
            persistence.rejectWrite(number: 1)
            let suiteName = "WatchConversationCreationFailure.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            let store = WatchConversationStore(
                userDefaults: defaults,
                persistenceKey: "state",
                persistenceWriter: { persistence.write($0) },
                mutationEnqueuer: { _ in }
            )
            let model = "configured-model"
            let aiService = configuredCapturingAIService(model: model)
            let viewModel = WatchChatViewModel(
                conversationStore: store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.selectedModel = model
            WatchConnectivityService.shared.availableModels = [model]

            let conversationID = viewModel.createNewConversation()

            #expect(conversationID == nil)
            #expect(store.conversations.isEmpty)
            #expect(viewModel.errorMessage != nil)
        }

        @Test
        func `Apple Intelligence conversation keeps its model when no fallback is configured`() {
            let appleModel = "apple-intelligence"
            let unconfiguredModel = "unconfigured-model"
            let fixture = makeViewModelFixture(model: appleModel)
            let aiService = configuredCapturingAIService(model: unconfiguredModel)
            aiService.customModels = [appleModel, unconfiguredModel]
            aiService.modelProviders = [
                appleModel: .appleIntelligence,
                unconfiguredModel: .openai,
            ]
            aiService.modelEndpoints = [:]
            aiService.modelAPIKeys = [:]
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [unconfiguredModel]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .consumed)

            #expect(aiService.capturedRequests.value.isEmpty)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.model == appleModel)
        }

        @Test
        func `Tool continuation includes final throttled assistant content`() async throws {
            let fixture = makeViewModelFixture()
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            var requests: [WatchChatViewModel.RequestConfiguration] = []
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { requests.append($0) }
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(firstRequest.onToolCallRequested)
            firstRequest.onChunk("First")
            firstRequest.onChunk(" second")
            onToolCallRequested("current-call", "unavailable_watch_tool", [:])
            firstRequest.onComplete()

            #expect(await waitUntil { requests.count == 2 })
            let continuation = try #require(requests.last)
            #expect(continuation.messages.first { $0.role == .assistant }?.content == "First second")
            viewModel.cancelRequest()
        }

        @Test
        func `Tool continuation flush failure retries full throttled content without another request`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "Existing",
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            defer { viewModel.cancelOwnedRequest() }
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]
            persistence.rejectNextWrite { data in
                isDraftWrite(data, assistantContent: "First second")
            }

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(firstRequest.onToolCallRequested)
            let initialDraft = try #require(fixture.store.conversation(for: fixture.conversation.id))
            let userMessageID = try #require(initialDraft.messages.first?.id)
            let assistantMessageID = try #require(initialDraft.messages.last?.id)
            firstRequest.onChunk("First")
            firstRequest.onChunk(" second")
            onToolCallRequested("current-call", "unavailable_watch_tool", [:])
            firstRequest.onComplete()

            #expect(await waitUntil {
                !viewModel.isLoading || aiService.capturedRequests.value.count > 1
            })
            #expect(persistence.rejectedWriteCount == 1)
            #expect(!viewModel.isLoading)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
            #expect(aiService.capturedRequests.value.count == 1)
            let failedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(failedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(failedConversation.messages.last?.content == "First")
            #expect(failedConversation.messages.last?.toolCalls?.map(\.id) == ["current-call"])
            #expect(!failedConversation.messages.contains { $0.role == Message.Role.tool.rawValue })
            #expect(!fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.id == assistantMessageID
            })

            viewModel.retryFailedMessage()

            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(aiService.capturedRequests.value.count == 1)
            let promotedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(promotedConversation.messages.map(\.id) == [userMessageID, assistantMessageID])
            #expect(promotedConversation.messages.last?.content == "First second")
            #expect(promotedConversation.messages.last?.toolCalls?.map(\.id) == ["current-call"])
            #expect(!promotedConversation.messages.contains { $0.role == Message.Role.tool.rawValue })
            let assistantChanges = fixture.store.pendingMutationsForSync
                .flatMap(\.messageChanges)
                .filter { $0.id == assistantMessageID }
            #expect(assistantChanges.count == 1)
            #expect(assistantChanges.first?.content == "First second")
        }

        @Test
        func `Tool continuation persistence failure stops before another request`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(persistenceWriter: { persistence.write($0) })
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            var requests: [WatchChatViewModel.RequestConfiguration] = []
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { requests.append($0) }
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(firstRequest.onToolCallRequested)
            firstRequest.onChunk("First")
            firstRequest.onChunk(" second")
            onToolCallRequested("current-call", "unavailable_watch_tool", [:])
            #expect(await waitUntil {
                fixture.store.conversation(for: fixture.conversation.id)?.messages.contains {
                    $0.toolCalls?.contains(where: { $0.id == "current-call" }) == true
                } == true
            })
            persistence.rejectWrite(number: persistence.writeCount + 2)

            firstRequest.onComplete()

            #expect(await waitUntil { !viewModel.isLoading })
            #expect(requests.count == 1)
            #expect(viewModel.errorMessage != nil)
            let conversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(!conversation.messages.contains { $0.role == Message.Role.tool.rawValue })
        }

        @Test
        func `Repeated tool callback ID executes only once`() async throws {
            let fixture = makeViewModelFixture()
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            var requests: [WatchChatViewModel.RequestConfiguration] = []
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService,
                requestObserver: { requests.append($0) }
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(firstRequest.onToolCallRequested)
            onToolCallRequested("duplicate-call", "unavailable_watch_tool", [:])
            onToolCallRequested("duplicate-call", "unavailable_watch_tool", [:])
            firstRequest.onComplete()

            #expect(await waitUntil { requests.count == 2 })
            let continuation = try #require(requests.last)
            #expect(continuation.messages.count { $0.role == .tool } == 1)
            viewModel.cancelRequest()
        }

        @Test
        func `Provider tool call IDs may be reused in later request rounds`() async throws {
            let fixture = makeViewModelFixture()
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            let firstToolCallback = try #require(firstRequest.onToolCallRequested)
            firstToolCallback("reused-call", "unavailable_watch_tool", ["round": 1])
            firstRequest.onComplete()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            let secondRequest = try #require(aiService.capturedRequests.value.last)
            let secondToolCallback = try #require(secondRequest.onToolCallRequested)
            secondToolCallback("reused-call", "unavailable_watch_tool", ["round": 2])
            secondRequest.onComplete()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 3 })
            let continuation = try #require(aiService.capturedRequests.value.last)
            let resultCalls = continuation.messages
                .filter { $0.role == .tool }
                .compactMap { $0.toolCalls?.first }
            #expect(resultCalls.map(\.id) == ["reused-call", "reused-call"])
            #expect(resultCalls.compactMap { $0.arguments["round"]?.value as? Int } == [1, 2])
            viewModel.cancelRequest()
        }

        @Test
        func `Multiple ID-less tool calls persist distinct ordered synthetic IDs`() async throws {
            let fixture = makeViewModelFixture()
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(firstRequest.onToolCallRequested)
            onToolCallRequested("", "unavailable_watch_tool", ["position": 1])
            onToolCallRequested("   ", "unavailable_watch_tool", ["position": 2])
            onToolCallRequested("", "unavailable_watch_tool", ["position": 1])
            firstRequest.onComplete()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            let continuation = try #require(aiService.capturedRequests.value.last)
            let resultCalls = continuation.messages
                .filter { $0.role == .tool }
                .compactMap { $0.toolCalls?.first }
            let resultIDs = resultCalls.map(\.id)
            #expect(resultCalls.compactMap { $0.arguments["position"]?.value as? Int } == [1, 2])
            #expect(resultIDs.count == 2)
            #expect(resultIDs.allSatisfy { !$0.isEmpty })
            #expect(Set(resultIDs).count == 2)

            let assistantIDs = continuation.messages
                .filter { $0.role == .assistant }
                .flatMap { $0.toolCalls ?? [] }
                .map(\.id)
            #expect(assistantIDs == resultIDs)

            let reloaded = WatchConversationStore(
                userDefaults: fixture.defaults,
                persistenceKey: fixture.key,
                mutationEnqueuer: { _ in }
            )
            let reloadedIDs = reloaded.conversation(for: fixture.conversation.id)?.messages
                .filter { $0.role == Message.Role.assistant.rawValue }
                .flatMap { $0.toolCalls ?? [] }
                .map(\.id)
            #expect(reloadedIDs == resultIDs)
            viewModel.cancelRequest()
        }

        @Test
        func `Tool depth promotion failure retries the same partial draft`() async throws {
            let persistence = PersistenceTestWriter()
            let fixture = makeViewModelFixture(
                title: "Existing",
                persistenceWriter: { persistence.write($0) }
            )
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            for round in 0 ..< 5 {
                let requests = aiService.capturedRequests.value
                try #require(requests.indices.contains(round))
                let request = requests[round]
                let onToolCallRequested = try #require(request.onToolCallRequested)
                onToolCallRequested("call-\(round)", "unavailable_watch_tool", [:])
                request.onComplete()
                #expect(await waitUntil { aiService.capturedRequests.value.count == round + 2 })
            }

            let depthRequest = try #require(aiService.capturedRequests.value.last)
            depthRequest.onChunk("Depth partial")
            #expect(await waitUntil {
                fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content ==
                    "Depth partial"
            })
            let draft = try #require(fixture.store.conversation(for: fixture.conversation.id))
            let messageIDs = draft.messages.map(\.id)
            let assistantMessageID = try #require(draft.messages.last?.id)
            persistence.rejectNextWrite { data in
                isPromotionWrite(data, assistantContent: "Depth partial")
            }

            let onToolCallRequested = try #require(depthRequest.onToolCallRequested)
            onToolCallRequested("depth-limit-call", "unavailable_watch_tool", [:])

            #expect(await waitUntil { !viewModel.isLoading })
            #expect(persistence.rejectedWriteCount == 1)
            #expect(viewModel.errorMessage == "Failed to save response. Please try again.")
            #expect(viewModel.failedMessage == "Prompt")
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.map(\.id) == messageIDs)

            viewModel.retryFailedMessage()

            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.failedMessage == nil)
            #expect(aiService.capturedRequests.value.count == 6)
            let promotedConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(promotedConversation.messages.map(\.id) == messageIDs)
            #expect(promotedConversation.messages.last?.content == "Depth partial")
            #expect(fixture.store.pendingMutationsForSync.flatMap(\.messageChanges).contains {
                $0.id == assistantMessageID && $0.content == "Depth partial"
            })
        }

        @Test
        func `Continuation failure preserves completed tool state without empty placeholder`() async throws {
            let fixture = makeViewModelFixture()
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Prompt")
            let firstRequest = try #require(aiService.capturedRequests.value.first)
            let onToolCallRequested = try #require(firstRequest.onToolCallRequested)
            onToolCallRequested("current-call", "unavailable_watch_tool", [:])
            firstRequest.onComplete()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            let continuation = try #require(aiService.capturedRequests.value.last)
            continuation.onError(NSError(domain: "WatchContinuation", code: 1))

            #expect(await waitUntil { !viewModel.isLoading })
            let conversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            #expect(conversation.messages.contains {
                $0.toolCalls?.contains(where: { $0.id == "current-call" }) == true
            })
            #expect(conversation.messages.contains { $0.role == Message.Role.tool.rawValue })
            #expect(conversation.messages.last?.role == Message.Role.tool.rawValue)
            #expect(fixture.store.pendingMutationsForSync.first {
                $0.conversationID == fixture.conversation.id
            }?.revision == 2)
        }

        @Test
        func `Detached generation callbacks preserve order and complete safely`() async throws {
            let fixture = makeViewModelFixture()
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Prompt")
            let request = try #require(aiService.capturedRequests.value.first)

            await Task.detached {
                request.onChunk("Detached")
                request.onChunk(" callback")
                request.onComplete()
            }.value

            #expect(await waitUntil { !viewModel.isLoading })
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.messages.last?.content ==
                "Detached callback")
            #expect(fixture.store.pendingMutationsForSync.first {
                $0.conversationID == fixture.conversation.id
            }?.revision == 2)
        }

        @Test
        func `Later manual title edit wins over generated title callbacks`() async throws {
            let fixture = makeViewModelFixture(title: "New Chat")
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let generationRequest = try #require(aiService.capturedRequests.value.first)
            generationRequest.onChunk("Answer")
            generationRequest.onComplete()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            let titleRequest = try #require(aiService.capturedRequests.value.last)
            let manualTitle = "Manual Phone Title"
            #expect(fixture.store.renameConversation(fixture.conversation.id, newTitle: manualTitle))

            await Task.detached {
                titleRequest.onChunk("Generated Title")
                titleRequest.onError(NSError(domain: "Title", code: 1))
            }.value

            let titleWasOverwritten = await waitUntil(timeout: .milliseconds(100)) {
                fixture.store.conversation(for: fixture.conversation.id)?.title != manualTitle
            }
            #expect(!titleWasOverwritten)
            #expect(fixture.store.conversation(for: fixture.conversation.id)?.title == manualTitle)
        }

        @Test
        func `Phone title ABA snapshots fence detached title callbacks`() async throws {
            let fixture = makeViewModelFixture(title: "New Chat")
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            #expect(viewModel.sendMessage("Prompt") == .started)
            let generationRequest = try #require(aiService.capturedRequests.value.first)
            generationRequest.onChunk("Answer")
            generationRequest.onComplete()

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            let titleRequest = try #require(aiService.capturedRequests.value.last)
            var phoneConversation = try #require(fixture.store.conversation(for: fixture.conversation.id))
            let titleRequestRevision = phoneConversation.watchRevision
            let titleRequestUpdatedAt = phoneConversation.updatedAt

            phoneConversation.title = "Manual Phone Title"
            phoneConversation.updatedAt = titleRequestUpdatedAt.addingTimeInterval(1)
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 2,
                    conversations: [phoneConversation],
                    authoritativeConversationIDs: [phoneConversation.id]
                )
            )
            #expect(fixture.store.conversation(for: phoneConversation.id)?.title == "Manual Phone Title")

            phoneConversation.title = "New Chat"
            phoneConversation.updatedAt = titleRequestUpdatedAt.addingTimeInterval(2)
            fixture.store.applySyncSnapshot(
                WatchSyncSnapshot(
                    revision: 3,
                    conversations: [phoneConversation],
                    authoritativeConversationIDs: [phoneConversation.id]
                )
            )

            let manuallyRestoredConversation = try #require(fixture.store.conversation(for: phoneConversation.id))
            #expect(manuallyRestoredConversation.title == "New Chat")
            #expect(manuallyRestoredConversation.watchRevision == titleRequestRevision)
            #expect(manuallyRestoredConversation.updatedAt == phoneConversation.updatedAt)

            await Task.detached {
                titleRequest.onChunk("Generated Title")
                titleRequest.onComplete()
            }.value
            viewModel.cancelOwnedRequest()
            await Task.yield()

            let fencedConversation = try #require(fixture.store.conversation(for: phoneConversation.id))
            #expect(fencedConversation.title == "New Chat")
            #expect(fencedConversation.updatedAt == phoneConversation.updatedAt)
        }

        @Test
        func `Detached title callbacks hop safely to the main actor`() async throws {
            let fixture = makeViewModelFixture(title: "New Chat")
            let aiService = configuredCapturingAIService(model: fixture.conversation.model)
            let viewModel = WatchChatViewModel(
                conversationStore: fixture.store,
                connectivityService: .shared,
                aiService: aiService
            )
            WatchConnectivityService.shared.availableModels = [fixture.conversation.model]

            viewModel.setConversation(fixture.conversation.id)
            viewModel.sendMessage("Prompt")
            let generationRequest = try #require(aiService.capturedRequests.value.first)
            await Task.detached {
                generationRequest.onChunk("Answer")
                generationRequest.onComplete()
            }.value

            #expect(await waitUntil { aiService.capturedRequests.value.count == 2 })
            let titleRequest = try #require(aiService.capturedRequests.value.last)
            await Task.detached {
                titleRequest.onChunk("\"Detached Title\"\n")
            }.value

            #expect(await waitUntil {
                fixture.store.conversation(for: fixture.conversation.id)?.title == "Detached Title"
            })
            await Task.detached {
                titleRequest.onComplete()
            }.value
        }
    }

    @MainActor
    private struct ViewModelFixture {
        let defaults: UserDefaults
        let key: String
        let store: WatchConversationStore
        let conversation: WatchConversation
    }

    @MainActor
    private func makeViewModelFixture(
        title: String = "Synced",
        messages: [WatchMessage] = [],
        model: String = "conversation-model",
        persistenceWriter: ((Data) -> Bool)? = nil
    ) -> ViewModelFixture {
        let suiteName = "WatchChatViewModelNativeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let key = "state"
        let store = WatchConversationStore(
            userDefaults: defaults,
            persistenceKey: key,
            now: { Date(timeIntervalSince1970: 100) },
            persistenceWriter: persistenceWriter,
            mutationEnqueuer: { _ in }
        )
        let date = Date(timeIntervalSince1970: 1)
        let conversation = WatchConversation(
            id: UUID(),
            title: title,
            messages: messages,
            model: model,
            updatedAt: date,
            createdAt: date,
            temperature: 0.15,
            resolvedSystemPrompt: "System prompt"
        )
        store.applySyncSnapshot(
            WatchSyncSnapshot(
                revision: 1,
                conversations: [conversation],
                authoritativeConversationIDs: [conversation.id]
            )
        )
        return ViewModelFixture(
            defaults: defaults,
            key: key,
            store: store,
            conversation: conversation
        )
    }

    @MainActor
    private final class PersistenceTestWriter {
        private(set) var writeCount = 0
        private(set) var rejectedWriteCount = 0
        private var rejectedWriteNumber: Int?
        private var rejectedWritePredicate: ((Data) -> Bool)?

        func rejectWrite(number: Int) {
            rejectedWriteNumber = number
        }

        func rejectNextWrite(where predicate: @escaping (Data) -> Bool) {
            rejectedWritePredicate = predicate
        }

        func write(_ data: Data) -> Bool {
            writeCount += 1
            let rejectsNumber = writeCount == rejectedWriteNumber
            let rejectsPredicate = rejectedWritePredicate?(data) == true
            guard !rejectsNumber, !rejectsPredicate else {
                rejectedWriteCount += 1
                if rejectsPredicate {
                    rejectedWritePredicate = nil
                }
                return false
            }
            return true
        }
    }

    private func isConversationMessageWrite(
        _ data: Data,
        role: String,
        content: String
    ) -> Bool {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversations = state["conversations"] as? [[String: Any]]
        else {
            return false
        }
        return conversations.contains { conversation in
            guard let messages = conversation["messages"] as? [[String: Any]] else { return false }
            return messages.contains { message in
                message["role"] as? String == role && message["content"] as? String == content
            }
        }
    }

    private func isConversationModelWrite(
        _ data: Data,
        conversationID: UUID,
        model: String
    ) -> Bool {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversations = state["conversations"] as? [[String: Any]]
        else {
            return false
        }
        return conversations.contains { conversation in
            conversation["id"] as? String == conversationID.uuidString
                && conversation["model"] as? String == model
        }
    }

    private func isDraftWrite(_ data: Data, assistantContent: String) -> Bool {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pendingDrafts = state["pendingDrafts"] as? [[String: Any]]
        else {
            return false
        }
        return pendingDrafts.contains { draft in
            guard let conversation = draft["conversation"] as? [String: Any],
                  let messages = conversation["messages"] as? [[String: Any]]
            else {
                return false
            }
            return messages.contains { message in
                message["role"] as? String == Message.Role.assistant.rawValue &&
                    message["content"] as? String == assistantContent
            }
        }
    }

    private func isPromotionWrite(_ data: Data, assistantContent: String) -> Bool {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pendingMutations = state["pendingMutations"] as? [[String: Any]]
        else {
            return false
        }
        return pendingMutations.contains { mutation in
            guard let messageChanges = mutation["messageChanges"] as? [[String: Any]] else {
                return false
            }
            return messageChanges.contains { message in
                message["role"] as? String == Message.Role.assistant.rawValue &&
                    message["content"] as? String == assistantContent
            }
        }
    }

    @MainActor
    private func configuredAIService(
        model: String,
        responseSimulator: @escaping AIServiceResponseSimulator
    ) -> AIService {
        let service = AIService(responseSimulator: responseSimulator)
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-watch-test"
        return service
    }

    @MainActor
    private func configuredCapturingAIService(model: String) -> CallbackCapturingAIService {
        let service = CallbackCapturingAIService()
        service.customModels = [model]
        service.selectedModel = model
        service.modelProviders[model] = .openai
        service.modelAPIKeys[model] = "sk-watch-test"
        return service
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private struct CapturedAIServiceRequest: @unchecked Sendable {
        let messages: [Message]
        let onChunk: @Sendable (String) -> Void
        let onComplete: @Sendable () -> Void
        let onError: @Sendable (Error) -> Void
        let onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?
    }

    @MainActor
    private final class CallbackCapturingAIService: AIService {
        let capturedRequests = FlightTestBox<[CapturedAIServiceRequest]>([])

        init() {
            super.init(responseSimulator: { _, _ in })
        }

        override func sendMessage(
            messages: [Message],
            model: String?,
            temperature: Double?,
            stream: Bool,
            tools: [[String: Any]]?,
            conversationId: UUID?,
            isMultiModelRequest: Bool,
            onChunk: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            preparedAPIKey: String?,
            requestFlightID: RequestFlightID?
        ) -> AITextRequest {
            capturedRequests.update {
                $0.append(
                    CapturedAIServiceRequest(
                        messages: messages,
                        onChunk: onChunk,
                        onComplete: onComplete,
                        onError: onError,
                        onToolCallRequested: onToolCallRequested
                    )
                )
            }
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                preparedAPIKey: preparedAPIKey,
                requestFlightID: requestFlightID
            )
        }
    }

    // swiftlint:enable identifier_name type_body_length

#endif
