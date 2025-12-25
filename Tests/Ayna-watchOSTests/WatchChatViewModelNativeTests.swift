//
//  WatchChatViewModelNativeTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for WatchChatViewModel running natively on watchOS
//

@testable import Ayna_watchOS_Watch_App
import Foundation
import Testing

@Suite("WatchChatViewModel Native Tests")
@MainActor
struct WatchChatViewModelNativeTests {
    private var viewModel: WatchChatViewModel
    private var store: WatchConversationStore

    init() {
        store = WatchConversationStore.shared
        // Clear existing conversations
        store.updateConversations([])
        viewModel = WatchChatViewModel()
    }

    // MARK: - Initial State Tests

    @Test("Initial state is correct")
    func initialState() {
        #expect(!viewModel.isLoading)
        #expect(!viewModel.isStreaming)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.streamingContent.isEmpty)
        #expect(viewModel.currentToolName == nil)
        #expect(viewModel.failedMessage == nil)
    }

    // MARK: - Conversation Management Tests

    @Test("Create new conversation")
    func createNewConversation() {
        let conversationId = viewModel.createNewConversation()

        #expect(store.conversation(for: conversationId) != nil)
    }

    @Test("Set conversation resets state")
    func setConversation() {
        let conversation = store.createConversation(model: "gpt-4o")

        viewModel.setConversation(conversation.id)

        // State should be reset
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.streamingContent.isEmpty)
        #expect(viewModel.currentToolName == nil)
        #expect(viewModel.failedMessage == nil)
    }

    @Test("Set conversation clears previous error")
    func setConversationClearsPreviousError() {
        let conversation = store.createConversation(model: "gpt-4o")

        viewModel.setConversation(conversation.id)

        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Error Handling Tests

    @Test("Send message without conversation shows error")
    func sendMessageWithoutConversation() {
        // Don't call setConversation, so no conversation is selected
        viewModel.sendMessage("Hello")

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.errorMessage == "No conversation selected")
    }

    @Test("Dismiss error clears state")
    func dismissError() async {
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

    @Test("Cancel request resets loading state")
    func cancelRequest() {
        let conversation = store.createConversation(model: "gpt-4o")
        viewModel.setConversation(conversation.id)

        viewModel.cancelRequest()

        #expect(!viewModel.isLoading)
        #expect(!viewModel.isStreaming)
        #expect(viewModel.currentToolName == nil)
    }

    // MARK: - State Management Tests

    @Test("Streaming content reset on set conversation")
    func streamingContentReset() {
        let conversation = store.createConversation(model: "gpt-4o")

        viewModel.setConversation(conversation.id)

        #expect(viewModel.streamingContent.isEmpty)
    }

    // MARK: - Retry Tests

    @Test("Retry without failed message does nothing")
    func retryWithoutFailedMessage() {
        // Calling retry when there's no failed message should do nothing
        viewModel.retryFailedMessage()

        // Should not crash and state should remain unchanged
        #expect(!viewModel.isLoading)
    }
}
