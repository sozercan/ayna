//
//  WatchChatViewModelNativeTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for WatchChatViewModel running natively on watchOS
//

#if os(watchOS)

    // SwiftFormat's descriptive Swift Testing names intentionally use backticks.
    // swiftlint:disable identifier_name

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("WatchChatViewModel Native Tests", .serialized)
    @MainActor
    struct WatchChatViewModelNativeTests {
        private let viewModel: WatchChatViewModel
        private let store: WatchConversationStore

        init() {
            store = WatchConversationStore.shared
            // Clear existing conversations
            store.updateConversations([])
            viewModel = WatchChatViewModel()
        }

        // MARK: - Initial State Tests

        @Test
        func `Initial state is correct`() {
            #expect(!viewModel.isLoading)
            #expect(!viewModel.isStreaming)
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.streamingContent.isEmpty)
            #expect(viewModel.currentToolName == nil)
            #expect(viewModel.failedMessage == nil)
        }

        // MARK: - Conversation Management Tests

        @Test
        func `Create new conversation`() {
            let conversationId = viewModel.createNewConversation()

            #expect(store.conversation(for: conversationId) != nil)
        }

        @Test
        func `Set conversation resets state`() {
            let conversation = store.createConversation(model: "gpt-4o")

            viewModel.setConversation(conversation.id)

            // State should be reset
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.streamingContent.isEmpty)
            #expect(viewModel.currentToolName == nil)
            #expect(viewModel.failedMessage == nil)
        }

        @Test
        func `Set conversation clears previous error`() {
            let conversation = store.createConversation(model: "gpt-4o")

            viewModel.setConversation(conversation.id)

            #expect(viewModel.errorMessage == nil)
        }

        // MARK: - Error Handling Tests

        @Test
        func `Send message without conversation shows error`() {
            // Don't call setConversation, so no conversation is selected
            viewModel.sendMessage("Hello")

            #expect(viewModel.errorMessage != nil)
            #expect(viewModel.errorMessage == "No conversation selected")
        }

        @Test
        func `Dismiss error clears state`() async {
            let conversation = store.createConversation(model: "gpt-4o")
            viewModel.setConversation(conversation.id)

            // Trigger an error by sending without API key configured
            viewModel.sendMessage("Hello")

            // Let any async operations settle
            try? await Task.sleep(for: .milliseconds(100))

            // Dismiss the error
            viewModel.dismissError()

            #expect(viewModel.failedMessage == nil)
            #expect(viewModel.errorMessage == nil)
        }

        // MARK: - Cancel Tests

        @Test
        func `Cancel request resets loading state`() {
            let conversation = store.createConversation(model: "gpt-4o")
            viewModel.setConversation(conversation.id)

            viewModel.cancelRequest()

            #expect(!viewModel.isLoading)
            #expect(!viewModel.isStreaming)
            #expect(viewModel.currentToolName == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func `Stopping during tool execution does not start a continuation request`() async {
            let model = "watch-tool-test-model"
            let service = SuspendedToolAIService()
            let connectivityService = WatchConnectivityService.shared
            let previousSelectedModel = connectivityService.selectedModel
            let previousAvailableModels = connectivityService.availableModels
            let viewModel = WatchChatViewModel(aiService: service)
            defer {
                viewModel.cancelRequest()
                service.finishToolExecution()
                connectivityService.selectedModel = previousSelectedModel
                connectivityService.availableModels = previousAvailableModels
            }

            service.modelProviders[model] = .openai
            connectivityService.selectedModel = model
            connectivityService.availableModels = [model]

            let conversation = store.createConversation(model: model)
            viewModel.setConversation(conversation.id)
            viewModel.sendMessage("Search for Swift news")
            #expect(service.sendCount == 1)

            service.requestToolCall()
            await service.waitForToolExecutionToStart()

            viewModel.cancelRequest()
            service.finishToolExecution()
            await service.waitForToolExecutionToFinish()

            #expect(service.sendCount == 1)
            #expect(service.cancelCount == 1)
            #expect(!viewModel.isLoading)
            #expect(!viewModel.isStreaming)
            #expect(viewModel.currentToolName == nil)
            #expect(store.conversation(for: conversation.id)?.messages.count == 2)
        }

        @Test(.timeLimit(.minutes(1)))
        func `Stopping after completion is queued does not finalize the turn`() async {
            let model = "watch-completion-test-model"
            let service = SuspendedToolAIService()
            let connectivityService = WatchConnectivityService.shared
            let previousSelectedModel = connectivityService.selectedModel
            let previousAvailableModels = connectivityService.availableModels
            let viewModel = WatchChatViewModel(aiService: service)
            defer {
                viewModel.cancelRequest()
                connectivityService.selectedModel = previousSelectedModel
                connectivityService.availableModels = previousAvailableModels
            }

            service.modelProviders[model] = .openai
            connectivityService.selectedModel = model
            connectivityService.availableModels = [model]

            let conversation = store.createConversation(model: model)
            viewModel.setConversation(conversation.id)
            viewModel.sendMessage("Do not finalize")

            service.complete()
            await Task.yield()
            viewModel.cancelRequest()
            await Task.yield()

            #expect(store.conversation(for: conversation.id)?.title == "New Chat")
            #expect(store.conversation(for: conversation.id)?.messages.count == 2)
            #expect(service.sendCount == 1)
        }

        // MARK: - State Management Tests

        @Test
        func `Streaming content reset on set conversation`() {
            let conversation = store.createConversation(model: "gpt-4o")

            viewModel.setConversation(conversation.id)

            #expect(viewModel.streamingContent.isEmpty)
        }

        // MARK: - Retry Tests

        @Test
        func `Retry without failed message does nothing`() {
            // Calling retry when there's no failed message should do nothing
            viewModel.retryFailedMessage()

            // Should not crash and state should remain unchanged
            #expect(!viewModel.isLoading)
        }

        @Test
        func `Partial assistant failure preserves output and keeps retry available`() {
            let user = WatchMessage(from: Message(role: .user, content: "Search for Swift news"))
            let partialAssistant = WatchMessage(
                from: Message(role: .assistant, content: "I found a few relevant updates")
            )

            let resolution = WatchChatViewModel.failureResolution(
                messages: [user, partialAssistant],
                failedUserMessageId: user.id,
                assistantPlaceholderId: partialAssistant.id,
                failedUserMessagePolicy: .removeForRetry
            )

            #expect(resolution.messagesAfterFailure.count == 2)
            #expect(resolution.messagesAfterFailure[1].content == partialAssistant.content)
            #expect(resolution.retryPrompt == user.content)
            #expect(resolution.failedMessageId == nil)
        }

        @Test
        func `Empty assistant failure removes placeholder and replaces user on retry`() {
            let user = WatchMessage(from: Message(role: .user, content: "Retry this"))
            let placeholder = WatchMessage(from: Message(role: .assistant, content: ""))

            let resolution = WatchChatViewModel.failureResolution(
                messages: [user, placeholder],
                failedUserMessageId: user.id,
                assistantPlaceholderId: placeholder.id,
                failedUserMessagePolicy: .removeForRetry
            )

            #expect(resolution.messagesAfterFailure.map(\.id) == [user.id])
            #expect(resolution.retryPrompt == user.content)
            #expect(resolution.failedMessageId == user.id)
        }

        @Test
        func `Tool continuation carries web search result without orphaned tool role`() {
            let original = Message(role: .user, content: "What changed in Swift?")

            let continuation = WatchChatViewModel.toolContinuationMessages(
                requestMessages: [original],
                partialAssistantContent: "Let me check.",
                toolName: WebSearchCoordinator.toolName,
                result: "Swift 6.2 was announced."
            )

            #expect(continuation.map(\.role) == [.user, .assistant, .user])
            #expect(!continuation.contains { $0.role == .tool })
            #expect(continuation.last?.content.contains("web_search") == true)
            #expect(continuation.last?.content.contains("Swift 6.2 was announced.") == true)
        }

        @Test
        func `Watch tool chains retain the constrained depth limit`() {
            #expect(WatchChatViewModel.maxToolCallDepth == 5)
        }

        @Test(.timeLimit(.minutes(1)))
        func `Reasoning-only response is persisted and completes visibly`() async {
            let model = "watch-reasoning-test-model"
            let service = SuspendedToolAIService()
            let connectivityService = WatchConnectivityService.shared
            let previousSelectedModel = connectivityService.selectedModel
            let previousAvailableModels = connectivityService.availableModels
            let viewModel = WatchChatViewModel(aiService: service)
            defer {
                viewModel.cancelRequest()
                connectivityService.selectedModel = previousSelectedModel
                connectivityService.availableModels = previousAvailableModels
            }

            service.modelProviders[model] = .openai
            connectivityService.selectedModel = model
            connectivityService.availableModels = [model]

            let conversation = store.createConversation(model: model)
            viewModel.setConversation(conversation.id)
            viewModel.sendMessage("Think carefully")

            service.emitReasoning("Compare the constraints first.")
            await waitUntil {
                store.conversation(for: conversation.id)?.messages.last?.reasoning != nil
            }
            service.complete()
            await waitUntil { !viewModel.isLoading }

            let assistant = store.conversation(for: conversation.id)?.messages.last
            #expect(assistant?.content.isEmpty == true)
            #expect(assistant?.reasoning == "Compare the constraints first.")
        }

        private func waitUntil(_ condition: @MainActor () -> Bool) async {
            while !condition() {
                await Task.yield()
            }
        }
    }

    @MainActor
    private final class SuspendedToolAIService: WatchChatAIService {
        private static let toolResult = "Swift news result"

        private var toolResultContinuation: CheckedContinuation<String, Never>?
        private var toolExecutionStartedContinuation: CheckedContinuation<Void, Never>?
        private var toolExecutionFinishedContinuation: CheckedContinuation<Void, Never>?
        private var callbacks: WatchStreamingCallbacks?
        private var shouldFinishToolExecution = false
        private(set) var cancelCount = 0
        private(set) var sendCount = 0
        private(set) var toolExecutionStarted = false
        private(set) var toolExecutionFinished = false
        var modelProviders: [String: AIProvider] = [:]

        func isModelConfigured(_: String) -> Bool {
            true
        }

        func getAllAvailableTools() -> [[String: Any]]? {
            [[
                "type": "function",
                "function": ["name": WebSearchCoordinator.toolName]
            ]]
        }

        func isBuiltInTool(_ toolName: String) -> Bool {
            toolName == WebSearchCoordinator.toolName
        }

        func executeBuiltInTool(
            name _: String,
            arguments _: [String: Any],
            conversationId _: UUID? = nil
        ) async -> String {
            toolExecutionStarted = true
            toolExecutionStartedContinuation?.resume()
            toolExecutionStartedContinuation = nil

            let result: String
            if shouldFinishToolExecution {
                result = Self.toolResult
            } else {
                result = await withCheckedContinuation { continuation in
                    if shouldFinishToolExecution {
                        continuation.resume(returning: Self.toolResult)
                    } else {
                        toolResultContinuation = continuation
                    }
                }
            }

            toolExecutionFinished = true
            toolExecutionFinishedContinuation?.resume()
            toolExecutionFinishedContinuation = nil
            return result
        }

        func sendWatchMessage(
            messages _: [Message],
            model _: String,
            stream _: Bool,
            tools _: [[String: Any]]?,
            conversationId _: UUID,
            callbacks: WatchStreamingCallbacks
        ) {
            sendCount += 1
            self.callbacks = callbacks
        }

        func cancelCurrentRequest() {
            cancelCount += 1
        }

        func requestToolCall() {
            callbacks?.onToolCallRequested("tool-call", WebSearchCoordinator.toolName, ["query": "Swift news"])
        }

        func emitReasoning(_ reasoning: String) {
            callbacks?.onReasoning(reasoning)
        }

        func complete() {
            callbacks?.onComplete()
        }

        func waitForToolExecutionToStart() async {
            guard !toolExecutionStarted else { return }
            await withCheckedContinuation { continuation in
                toolExecutionStartedContinuation = continuation
            }
        }

        func finishToolExecution() {
            shouldFinishToolExecution = true
            toolResultContinuation?.resume(returning: Self.toolResult)
            toolResultContinuation = nil
        }

        func waitForToolExecutionToFinish() async {
            guard !toolExecutionFinished else { return }
            await withCheckedContinuation { continuation in
                toolExecutionFinishedContinuation = continuation
            }
        }
    }

    // swiftlint:enable identifier_name

#endif
