#if os(watchOS)

    // swiftlint:disable identifier_name

    //
    //  WatchChatViewModelNativeTests.swift
    //  Ayna-watchOSTests
    //
    //  Unit tests for WatchChatViewModel running natively on watchOS
    //

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("WatchChatViewModel Native Tests")
    @MainActor
    struct WatchChatViewModelNativeTests {
        private let viewModel: WatchChatViewModel
        private let store: WatchConversationStore

        init() {
            let suiteName = "WatchChatViewModelNativeTests.\(UUID().uuidString)"
            guard let userDefaults = UserDefaults(suiteName: suiteName) else {
                fatalError("Failed to create isolated UserDefaults suite")
            }
            userDefaults.removePersistentDomain(forName: suiteName)

            let store = WatchConversationStore(
                userDefaults: userDefaults,
                persistenceKey: "state",
                mutationEnqueuer: { _ in }
            )
            let aiService = AIService()
            aiService.modelProviders = ["gpt-4o": .openai]
            aiService.modelEndpoints = [:]
            aiService.modelAPIKeys = [:]

            self.store = store
            viewModel = WatchChatViewModel(
                conversationStore: store,
                aiService: aiService
            )
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

            #expect(conversationId != nil)
            #expect(conversationId.flatMap { store.conversation(for: $0) } != nil)
        }

        @Test
        func `Set conversation resets state`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))

            viewModel.setConversation(conversation.id)

            // State should be reset
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.streamingContent.isEmpty)
            #expect(viewModel.currentToolName == nil)
            #expect(viewModel.failedMessage == nil)
        }

        @Test
        func `Set conversation clears previous error`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))

            viewModel.setConversation(conversation.id)

            #expect(viewModel.errorMessage == nil)
        }

        // MARK: - Error Handling Tests

        @Test
        func `Send message without conversation is rejected`() {
            // Don't call setConversation, so no conversation is selected
            let result = viewModel.sendMessage("Hello")

            #expect(result == .notConsumed)
            #expect(viewModel.errorMessage == "No conversation selected")
        }

        @Test
        func `Dismiss error clears state`() async throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
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
        func `Cancel request resets loading state`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            viewModel.setConversation(conversation.id)

            viewModel.cancelRequest()

            #expect(!viewModel.isLoading)
            #expect(!viewModel.isStreaming)
            #expect(viewModel.currentToolName == nil)
        }

        // MARK: - State Management Tests

        @Test
        func `Streaming content reset on set conversation`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))

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
    }

    // swiftlint:enable identifier_name

#endif
