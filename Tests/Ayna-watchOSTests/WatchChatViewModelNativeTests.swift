//
//  WatchChatViewModelNativeTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for WatchChatViewModel running natively on watchOS
//

@testable import Ayna_watchOS_Watch_App
import XCTest

@MainActor
final class WatchChatViewModelNativeTests: XCTestCase {
    private var viewModel: WatchChatViewModel!
    private var store: WatchConversationStore!

    override func setUp() async throws {
        store = WatchConversationStore.shared
        // Clear existing conversations
        store.updateConversations([])
        viewModel = WatchChatViewModel()
    }

    override func tearDown() async throws {
        store.updateConversations([])
        viewModel = nil
        store = nil
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.streamingContent.isEmpty)
        XCTAssertNil(viewModel.currentToolName)
        XCTAssertNil(viewModel.failedMessage)
    }

    // MARK: - Conversation Management Tests

    func testCreateNewConversation() {
        let conversationId = viewModel.createNewConversation()

        XCTAssertNotNil(store.conversation(for: conversationId))
    }

    func testSetConversation() {
        let conversation = store.createConversation(model: "gpt-4o")

        viewModel.setConversation(conversation.id)

        // State should be reset
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.streamingContent.isEmpty)
        XCTAssertNil(viewModel.currentToolName)
        XCTAssertNil(viewModel.failedMessage)
    }

    func testSetConversationClearsPreviousError() {
        // Note: We can't directly set errorMessage, so we verify it's nil after setConversation
        let conversation = store.createConversation(model: "gpt-4o")

        viewModel.setConversation(conversation.id)

        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Error Handling Tests

    func testSendMessageWithoutConversation() {
        // Don't call setConversation, so no conversation is selected
        viewModel.sendMessage("Hello")

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.errorMessage, "No conversation selected")
    }

    func testDismissError() {
        let conversation = store.createConversation(model: "gpt-4o")
        viewModel.setConversation(conversation.id)

        // Trigger an error by sending without API key configured
        // This will set failedMessage when the API call fails
        viewModel.sendMessage("Hello")

        // Let any async operations settle
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // Dismiss the error
        viewModel.dismissError()

        XCTAssertNil(viewModel.failedMessage)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Cancel Tests

    func testCancelRequest() {
        let conversation = store.createConversation(model: "gpt-4o")
        viewModel.setConversation(conversation.id)

        viewModel.cancelRequest()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertNil(viewModel.currentToolName)
    }

    // MARK: - State Management Tests

    func testStreamingContentReset() {
        let conversation = store.createConversation(model: "gpt-4o")

        // Set some streaming content manually isn't possible since it's published
        // but we can verify the state is clean after setConversation
        viewModel.setConversation(conversation.id)

        XCTAssertTrue(viewModel.streamingContent.isEmpty)
    }

    // MARK: - Retry Tests

    func testRetryWithoutFailedMessage() {
        // Calling retry when there's no failed message should do nothing
        viewModel.retryFailedMessage()

    // Should not crash and state should remain unchanged
    XCTAssertFalse(viewModel.isLoading)
    }
}
