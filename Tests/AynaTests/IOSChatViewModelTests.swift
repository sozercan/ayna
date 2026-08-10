#if os(iOS)

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("iOS Chat View Model Tests", .tags(.viewModel), .serialized)
    @MainActor
    struct IOSChatViewModelTests {
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

#endif
