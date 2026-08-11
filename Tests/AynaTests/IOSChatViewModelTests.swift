#if os(iOS)

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("iOS Chat View Model Tests", .tags(.viewModel), .serialized)
    @MainActor
    struct IOSChatViewModelTests {
        @Test(.timeLimit(.minutes(1)))
        func `single-model send waits for lazy history and includes it in the request`() async throws {
            let priorUser = Message(role: .user, content: "Prior question")
            let priorAssistant = Message(role: .assistant, content: "Prior answer")
            let conversation = Conversation(
                messages: [priorUser, priorAssistant],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "New question"

            viewModel.sendMessage()
            await gate.waitUntilStarted()

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.isEmpty == true)
            #expect(viewModel.messageText == "New question")
            viewModel.messageText = "Later draft"

            await gate.release()
            #expect(await waitUntil { aiService.singleModelRequests.count == 1 })

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.role) == [.user, .assistant, .user])
            #expect(request.map(\.content) == ["Prior question", "Prior answer", "New question"])
            #expect(!request.contains { $0.role == .assistant && $0.content.isEmpty })
            #expect(viewModel.messageText == "Later draft")
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `multi-model send waits for lazy history and includes it in the request`() async throws {
            let priorUser = Message(role: .user, content: "Prior question")
            let priorAssistant = Message(role: .assistant, content: "Prior answer")
            let models = ["model-a", "model-b"]
            let conversation = Conversation(
                messages: [priorUser, priorAssistant],
                model: models[0],
                systemPromptMode: .disabled,
                multiModelEnabled: true,
                activeModels: models
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: models)
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.selectedModels = Set(models)
            viewModel.messageText = "New comparison"

            viewModel.sendMessage()
            await gate.waitUntilStarted()

            #expect(aiService.multiModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.isEmpty == true)
            #expect(viewModel.messageText == "New comparison")
            viewModel.messageText = "Later comparison draft"
            viewModel.selectedModels = [models[0]]

            await gate.release()
            #expect(await waitUntil { aiService.multiModelRequests.count == 1 })

            let request = try #require(aiService.multiModelRequests.first)
            #expect(request.map(\.role) == [.user, .assistant, .user])
            #expect(request.map(\.content) == ["Prior question", "Prior answer", "New comparison"])
            #expect(!request.contains { $0.role == .assistant && $0.content.isEmpty })
            #expect(viewModel.messageText == "Later comparison draft")
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `multi-model reasoning routes by model and rejects stale operation callbacks`() async throws {
            let models = ["model-a", "model-b"]
            let conversation = Conversation(
                model: models[0],
                systemPromptMode: .disabled,
                multiModelEnabled: true,
                activeModels: models
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = MultiModelReasoningCapturingAIService()
            configure(aiService, models: models)
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.selectedModels = Set(models)
            viewModel.messageText = "First comparison"

            viewModel.sendMessage()
            #expect(aiService.reasoningCallbackCount == 1)
            let firstGroup = try #require(manager.conversation(byId: conversation.id)?.responseGroups.last)
            let firstA = try #require(firstGroup.responses.first(where: { $0.modelName == models[0] }))
            let firstB = try #require(firstGroup.responses.first(where: { $0.modelName == models[1] }))

            aiService.emitReasoning(requestIndex: 0, model: models[0], reasoning: "first-a")
            aiService.emitReasoning(requestIndex: 0, model: models[1], reasoning: "first-b")
            #expect(await waitUntil {
                let messages = manager.conversation(byId: conversation.id)?.messages ?? []
                return messages.first(where: { $0.id == firstA.id })?.reasoning == "first-a"
                    && messages.first(where: { $0.id == firstB.id })?.reasoning == "first-b"
            })

            viewModel.cancelGeneration()
            viewModel.messageText = "Replacement comparison"
            viewModel.sendMessage()
            #expect(aiService.reasoningCallbackCount == 2)
            let secondGroup = try #require(manager.conversation(byId: conversation.id)?.responseGroups.last)
            #expect(secondGroup.id != firstGroup.id)
            let secondA = try #require(secondGroup.responses.first(where: { $0.modelName == models[0] }))
            let secondB = try #require(secondGroup.responses.first(where: { $0.modelName == models[1] }))

            aiService.emitReasoning(requestIndex: 0, model: models[0], reasoning: "-stale")
            aiService.emitReasoning(requestIndex: 1, model: models[0], reasoning: "second-a")
            #expect(await waitUntil {
                manager.conversation(byId: conversation.id)?.messages.first(where: { $0.id == secondA.id })?.reasoning
                    == "second-a"
            })

            let messages = try #require(manager.conversation(byId: conversation.id)?.messages)
            #expect(messages.first(where: { $0.id == firstA.id })?.reasoning == "first-a")
            #expect(messages.first(where: { $0.id == firstB.id })?.reasoning == "first-b")
            #expect(messages.first(where: { $0.id == secondB.id })?.reasoning == nil)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `single-model reasoning streams into the active assistant and rejects stale callbacks`() async throws {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SingleModelReasoningCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "First question"

            viewModel.sendMessage()

            #expect(aiService.reasoningCallbackCount == 1)
            let firstAssistantID = try #require(
                manager.conversation(byId: conversation.id)?.messages.last(where: { $0.role == .assistant })?.id
            )
            aiService.emitReasoning(requestIndex: 0, reasoning: "first ")
            aiService.emitReasoning(requestIndex: 0, reasoning: "reasoning")
            #expect(await waitUntil {
                manager.conversation(byId: conversation.id)?.messages.first(where: {
                    $0.id == firstAssistantID
                })?.reasoning == "first reasoning"
            })

            viewModel.cancelGeneration()
            viewModel.messageText = "Replacement question"
            viewModel.sendMessage()

            #expect(aiService.reasoningCallbackCount == 2)
            let secondAssistantID = try #require(
                manager.conversation(byId: conversation.id)?.messages.last(where: { $0.role == .assistant })?.id
            )
            #expect(secondAssistantID != firstAssistantID)

            aiService.emitReasoning(requestIndex: 0, reasoning: "-stale")
            aiService.emitReasoning(requestIndex: 1, reasoning: "replacement reasoning")
            #expect(await waitUntil {
                manager.conversation(byId: conversation.id)?.messages.first(where: {
                    $0.id == secondAssistantID
                })?.reasoning == "replacement reasoning"
            })

            let messages = try #require(manager.conversation(byId: conversation.id)?.messages)
            #expect(messages.first(where: { $0.id == firstAssistantID })?.reasoning == "first reasoning")
            viewModel.cancelOwnedOperations()
        }

        @Test
        func `hydrated conversation send remains synchronous`() throws {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Send now"

            viewModel.sendMessage()

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.content) == ["Send now"])
            viewModel.cancelOwnedOperations()
        }

        @Test
        func `existing conversation reasoning updates persist and dispatch`() {
            let originalConfiguration = ModelReasoningConfiguration(
                activation: .enabled,
                effort: .medium
            )
            let conversation = Conversation(
                model: "model-a",
                systemPromptMode: .disabled,
                reasoningConfiguration: originalConfiguration
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            #expect(viewModel.selectedModel == conversation.model)
            #expect(viewModel.selectedModels == [conversation.model])
            #expect(viewModel.reasoningConfiguration == originalConfiguration)

            let updatedConfiguration = ModelReasoningConfiguration(
                activation: .enabled,
                effort: .high,
                summary: .concise
            )
            viewModel.updateReasoningConfiguration(updatedConfiguration)

            #expect(manager.conversation(byId: conversation.id)?.reasoningConfiguration == updatedConfiguration)

            viewModel.messageText = "Use the configured effort"
            viewModel.sendMessage()

            #expect(aiService.singleModelReasoningConfigurations == [updatedConfiguration])
            viewModel.cancelOwnedOperations()
        }

        @Test
        func `new multi-model conversation persists and dispatches reasoning`() throws {
            let models = ["model-a", "model-b"]
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: models)
            let viewModel = IOSChatViewModel(
                conversationManager: manager,
                aiService: aiService
            )
            let configuration = ModelReasoningConfiguration(
                activation: .enabled,
                effort: .low
            )
            viewModel.selectedModel = models[0]
            viewModel.selectedModels = Set(models)
            viewModel.updateReasoningConfiguration(configuration)
            viewModel.messageText = "Compare the options"

            viewModel.sendMessage()

            let conversation = try #require(manager.conversations.first)
            #expect(conversation.reasoningConfiguration == configuration)
            #expect(aiService.multiModelReasoningConfigurations == [configuration])
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `tool continuation keeps the reasoning configuration captured by the initial send`() async {
            let initialConfiguration = ModelReasoningConfiguration(
                activation: .enabled,
                effort: .high
            )
            let conversation = Conversation(
                model: "model-a",
                systemPromptMode: .disabled,
                reasoningConfiguration: initialConfiguration
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]
            let aiService = ToolReasoningCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                executeBuiltInTool: { _, _ in ("Tool result", nil) }
            )
            viewModel.messageText = "Use a tool"

            viewModel.sendMessage()
            #expect(aiService.reasoningConfigurations == [initialConfiguration])

            viewModel.updateReasoningConfiguration(
                ModelReasoningConfiguration(activation: .disabled)
            )
            aiService.emitToolRequest(
                requestIndex: 0,
                id: "tool-call-1",
                name: "web_search"
            )
            aiService.emitCompletion(requestIndex: 0)

            #expect(await waitUntil { aiService.reasoningConfigurations.count == 2 })
            #expect(aiService.reasoningConfigurations == [
                initialConfiguration,
                initialConfiguration,
            ])
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `failed lazy history load keeps the draft and attachments without sending`() async {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let gate = IOSConversationLoadGate(result: nil)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            let attachment = URL(fileURLWithPath: "/tmp/unsent-attachment.txt")
            viewModel.messageText = "Keep this draft"
            viewModel.attachedFiles = [attachment]

            viewModel.sendMessage()
            await gate.waitUntilStarted()
            await gate.release()
            #expect(await waitUntil { !viewModel.isGenerating })

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.isEmpty == true)
            #expect(viewModel.messageText == "Keep this draft")
            #expect(viewModel.attachedFiles == [attachment])
            #expect(viewModel.errorMessage != nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func `failed auto-send hydration restores the durable prompt`() async throws {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let gate = IOSConversationLoadGate(result: nil)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            let index = try #require(manager.conversations.firstIndex(where: {
                $0.id == conversation.id
            }))
            manager.conversations[index].pendingAutoSendPrompt = "Deep-link prompt"

            viewModel.configure(with: manager, conversationId: conversation.id)
            await gate.waitUntilStarted()
            await gate.release()
            #expect(await waitUntil { viewModel.errorMessage != nil })

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(viewModel.messageText == "Deep-link prompt")
            #expect(manager.conversation(byId: conversation.id)?.pendingAutoSendPrompt == "Deep-link prompt")
        }

        @Test(.timeLimit(.minutes(1)))
        func `newer auto-send prompt replaces a claim waiting for hydration`() async throws {
            let metadataConversation = Conversation(
                messages: [Message(role: .user, content: "Prior question")],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let storedConversation = metadataConversation
            let gate = IOSConversationLoadGate(result: storedConversation)
            let manager = makeMetadataManager(conversation: metadataConversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [metadataConversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: metadataConversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            let index = try #require(manager.conversations.firstIndex(where: {
                $0.id == metadataConversation.id
            }))
            manager.conversations[index].pendingAutoSendPrompt = "First prompt"

            viewModel.configure(with: manager, conversationId: metadataConversation.id)
            await gate.waitUntilStarted()

            manager.conversations[index].pendingAutoSendPrompt = "Second prompt"
            viewModel.configure(with: manager, conversationId: metadataConversation.id)

            await gate.release()
            #expect(await waitUntil { aiService.singleModelRequests.count == 1 })

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.content) == ["Prior question", "Second prompt"])
            #expect(manager.conversation(byId: metadataConversation.id)?.pendingAutoSendPrompt == nil)
            #expect(!manager.conversations[index].messages.contains { $0.content == "First prompt" })
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `newer auto-send prompt does not cancel a manual send waiting for hydration`() async throws {
            let conversation = Conversation(
                messages: [Message(role: .user, content: "Prior question")],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Manual prompt"

            viewModel.sendMessage()
            await gate.waitUntilStarted()

            let index = try #require(manager.conversations.firstIndex(where: { $0.id == conversation.id }))
            manager.conversations[index].pendingAutoSendPrompt = "Later deep-link prompt"
            viewModel.configure(with: manager, conversationId: conversation.id)

            await gate.release()
            #expect(await waitUntil { aiService.singleModelRequests.count == 1 })

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.content) == ["Prior question", "Manual prompt"])
            #expect(manager.conversation(byId: conversation.id)?.pendingAutoSendPrompt == "Later deep-link prompt")
            #expect(!manager.conversations[index].messages.contains { $0.content == "Later deep-link prompt" })
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `cancelling lazy history preparation keeps the draft without sending`() async {
            let conversation = Conversation(
                messages: [Message(role: .user, content: "Prior question")],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Do not send"
            let completion = IOSSendPreparationCompletionProbe()
            viewModel.sendPreparationDidFinish = {
                completion.finish()
            }

            viewModel.sendMessage()
            await gate.waitUntilStarted()
            viewModel.cancelGeneration()
            await gate.release()
            await completion.wait()

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.contains { message in
                message.role == .user && message.content == "Do not send"
            } == false)
            #expect(viewModel.messageText == "Do not send")
            #expect(!viewModel.isGenerating)
            viewModel.sendPreparationDidFinish = nil
        }

        @Test
        func `retry sends the selected response model and provider`() async throws {
            AIService.keychain = InMemoryKeychainStorage()
            let conversationModel = "conversation-default"
            let retryModel = "selected-response"
            let userMessage = Message(role: .user, content: "Compare these models")
            let assistantMessage = Message(
                role: .assistant,
                content: "Selected response",
                model: retryModel
            )
            let conversation = Conversation(
                messages: [userMessage, assistantMessage],
                model: conversationModel,
                systemPromptMode: .disabled
            )
            let store = ScriptedConversationStore()
            let manager = ConversationManager(store: store, saveDebounceDuration: .zero)
            await manager.loadingTask?.value
            manager.conversations = [conversation]

            let aiService = RetryCapturingAIService()
            aiService.customModels = [conversationModel, retryModel]
            aiService.selectedModel = conversationModel
            aiService.modelProviders[conversationModel] = .openai
            aiService.modelProviders[retryModel] = .anthropic
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )

            viewModel.retryMessage(beforeMessage: assistantMessage)

            let request = try #require(aiService.capturedRequests.first)
            #expect(request.model == retryModel)
            #expect(request.provider == .anthropic)
            #expect(manager.conversation(byId: conversation.id)?.messages.last?.model == retryModel)
            viewModel.cancelOwnedOperations()
        }

        private func makeMetadataManager(
            conversation: Conversation,
            gate: IOSConversationLoadGate
        ) -> ConversationManager {
            ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                conversationLoader: { conversationId in
                    await gate.load(conversationId)
                },
                conversationMetadataLoader: {
                    [ConversationMetadata(conversation: conversation)]
                },
                searchIndexWarmupEnabled: false
            )
        }

        private func configure(_ service: AIService, models: [String]) {
            service.customModels = models
            service.selectedModel = models[0]
            for model in models {
                service.modelProviders[model] = .openai
                service.modelAPIKeys[model] = "sk-unit-test"
            }
        }

        private func waitUntil(
            timeout: Duration = .seconds(1),
            condition: @MainActor () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !condition() {
                guard clock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
    }

    private actor IOSConversationLoadGate {
        private let result: Conversation?
        private var started = false
        private var released = false
        private var startedContinuations: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        init(result: Conversation?) {
            self.result = result
        }

        func load(_ conversationId: UUID) async -> Conversation? {
            guard conversationId == result?.id || result == nil else { return nil }
            started = true
            for continuation in startedContinuations {
                continuation.resume()
            }
            startedContinuations.removeAll()

            if !released {
                await withCheckedContinuation { continuation in
                    releaseContinuations.append(continuation)
                }
            }
            return result
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startedContinuations.append(continuation)
            }
        }

        func release() {
            released = true
            for continuation in releaseContinuations {
                continuation.resume()
            }
            releaseContinuations.removeAll()
        }
    }

    @MainActor
    private final class IOSSendPreparationCompletionProbe {
        private var isFinished = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isFinished else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish() {
            isFinished = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct CapturedRetryRequest {
        let model: String
        let provider: AIProvider
    }

    @MainActor
    private final class RetryCapturingAIService: AIService {
        private(set) var capturedRequests: [CapturedRetryRequest] = []

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
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            onReasoningContinuation: (@Sendable (ReasoningContinuationState) -> Void)?,
            requestFlightID: RequestFlightID?,
            reasoningConfiguration: ModelReasoningConfiguration?,
            reasoningSnapshot: AIReasoningRequestSnapshot?
        ) -> AITextRequest {
            let requestModel = model ?? selectedModel
            capturedRequests.append(
                CapturedRetryRequest(
                    model: requestModel,
                    provider: modelProviders[requestModel] ?? provider
                )
            )
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                onReasoningContinuation: onReasoningContinuation,
                requestFlightID: requestFlightID,
                reasoningConfiguration: reasoningConfiguration,
                reasoningSnapshot: reasoningSnapshot
            )
        }
    }

    @MainActor
    private final class SendHistoryCapturingAIService: AIService {
        private(set) var singleModelRequests: [[Message]] = []
        private(set) var multiModelRequests: [[Message]] = []
        private(set) var singleModelReasoningConfigurations: [ModelReasoningConfiguration?] = []
        private(set) var multiModelReasoningConfigurations: [ModelReasoningConfiguration?] = []

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
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            onReasoningContinuation: (@Sendable (ReasoningContinuationState) -> Void)?,
            requestFlightID: RequestFlightID?,
            reasoningConfiguration: ModelReasoningConfiguration?,
            reasoningSnapshot: AIReasoningRequestSnapshot?
        ) -> AITextRequest {
            if !isMultiModelRequest {
                singleModelRequests.append(messages)
                singleModelReasoningConfigurations.append(reasoningConfiguration)
            }
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                onReasoningContinuation: onReasoningContinuation,
                requestFlightID: requestFlightID,
                reasoningConfiguration: reasoningConfiguration,
                reasoningSnapshot: reasoningSnapshot
            )
        }

        override func sendToMultipleModels(
            messages: [Message],
            models: [String],
            temperature: Double?,
            onChunk: @escaping @Sendable (String, String) -> Void,
            onModelComplete: @escaping @Sendable (String) -> Void,
            onAllComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (String, Error) -> Void,
            onPendingToolCall: (@Sendable (String, String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String, String) -> Void)?,
            onReasoningContinuation: (@Sendable (String, ReasoningContinuationState) -> Void)?,
            reasoningConfiguration: ModelReasoningConfiguration?
        ) -> AITextBatchRequest {
            multiModelRequests.append(messages)
            multiModelReasoningConfigurations.append(reasoningConfiguration)
            return super.sendToMultipleModels(
                messages: messages,
                models: models,
                temperature: temperature,
                onChunk: onChunk,
                onModelComplete: onModelComplete,
                onAllComplete: onAllComplete,
                onError: onError,
                onPendingToolCall: onPendingToolCall,
                onReasoning: onReasoning,
                onReasoningContinuation: onReasoningContinuation,
                reasoningConfiguration: reasoningConfiguration
            )
        }
    }

    @MainActor
    private final class ToolReasoningCapturingAIService: AIService {
        private typealias CompletionCallback = @Sendable () -> Void
        private typealias ToolCallback = @Sendable (String, String, [String: Any]) -> Void

        private var completionCallbacks: [CompletionCallback] = []
        private var toolCallbacks: [ToolCallback?] = []
        private(set) var reasoningConfigurations: [ModelReasoningConfiguration?] = []

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
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk _: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError _: @escaping @Sendable (Error) -> Void,
            onToolCall _: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning _: (@Sendable (String) -> Void)?,
            onReasoningContinuation _: (@Sendable (ReasoningContinuationState) -> Void)?,
            requestFlightID: RequestFlightID?,
            reasoningConfiguration: ModelReasoningConfiguration?,
            reasoningSnapshot: AIReasoningRequestSnapshot?
        ) -> AITextRequest {
            reasoningConfigurations.append(reasoningConfiguration)
            completionCallbacks.append(onComplete)
            toolCallbacks.append(onToolCallRequested)
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil,
                onReasoningContinuation: nil,
                requestFlightID: requestFlightID,
                reasoningConfiguration: reasoningConfiguration,
                reasoningSnapshot: reasoningSnapshot
            )
        }

        func emitToolRequest(requestIndex: Int, id: String, name: String) {
            guard toolCallbacks.indices.contains(requestIndex) else { return }
            toolCallbacks[requestIndex]?(id, name, [:])
        }

        func emitCompletion(requestIndex: Int) {
            guard completionCallbacks.indices.contains(requestIndex) else { return }
            completionCallbacks[requestIndex]()
        }
    }

    @MainActor
    private final class MultiModelReasoningCapturingAIService: AIService {
        private typealias ReasoningCallback = @Sendable (String, String) -> Void

        private var reasoningCallbacks: [ReasoningCallback?] = []

        var reasoningCallbackCount: Int {
            reasoningCallbacks.count
        }

        init() {
            super.init(responseSimulator: { _, _ in })
        }

        override func sendToMultipleModels(
            messages: [Message],
            models _: [String],
            temperature: Double?,
            onChunk _: @escaping @Sendable (String, String) -> Void,
            onModelComplete _: @escaping @Sendable (String) -> Void,
            onAllComplete _: @escaping @Sendable () -> Void,
            onError _: @escaping @Sendable (String, Error) -> Void,
            onPendingToolCall _: (@Sendable (String, String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String, String) -> Void)?,
            onReasoningContinuation _: (@Sendable (String, ReasoningContinuationState) -> Void)?,
            reasoningConfiguration: ModelReasoningConfiguration?
        ) -> AITextBatchRequest {
            reasoningCallbacks.append(onReasoning)
            return super.sendToMultipleModels(
                messages: messages,
                models: [],
                temperature: temperature,
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, _ in },
                onPendingToolCall: nil,
                onReasoning: nil,
                onReasoningContinuation: nil,
                reasoningConfiguration: reasoningConfiguration
            )
        }

        func emitReasoning(requestIndex: Int, model: String, reasoning: String) {
            guard reasoningCallbacks.indices.contains(requestIndex) else { return }
            reasoningCallbacks[requestIndex]?(model, reasoning)
        }
    }

    @MainActor
    private final class SingleModelReasoningCapturingAIService: AIService {
        private typealias ReasoningCallback = @Sendable (String) -> Void

        private var reasoningCallbacks: [ReasoningCallback?] = []

        var reasoningCallbackCount: Int {
            reasoningCallbacks.count
        }

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
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk _: @escaping @Sendable (String) -> Void,
            onComplete _: @escaping @Sendable () -> Void,
            onError _: @escaping @Sendable (Error) -> Void,
            onToolCall _: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested _: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            onReasoningContinuation _: (@Sendable (ReasoningContinuationState) -> Void)?,
            requestFlightID: RequestFlightID?,
            reasoningConfiguration: ModelReasoningConfiguration?,
            reasoningSnapshot: AIReasoningRequestSnapshot?
        ) -> AITextRequest {
            reasoningCallbacks.append(onReasoning)
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: { _ in },
                onComplete: {},
                onError: { _ in },
                onToolCall: nil,
                onToolCallRequested: nil,
                onReasoning: nil,
                onReasoningContinuation: nil,
                requestFlightID: requestFlightID,
                reasoningConfiguration: reasoningConfiguration,
                reasoningSnapshot: reasoningSnapshot
            )
        }

        func emitReasoning(requestIndex: Int, reasoning: String) {
            guard reasoningCallbacks.indices.contains(requestIndex) else { return }
            reasoningCallbacks[requestIndex]?(reasoning)
        }
    }

#endif
