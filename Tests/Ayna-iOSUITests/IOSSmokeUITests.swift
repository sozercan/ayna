import XCTest

/// Smoke tests for iOS app - covers critical user flows
final class IOSSmokeUITests: IOSUITestCase {
    // MARK: - Conversation Tests

    func testNewConversationCreation() {
        // Start a new conversation
        sendNewChatMessage("Hello from iOS UI test")

        // Verify the chat composer appears (indicating we're now in an active chat)
        // iOS uses TextField, not TextEditor, so use textFields
        let chatComposer = app.textFields["chat.composer.textEditor"]
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 10), "Chat composer should appear after sending message")

        // Verify response appears (mock response in test environment)
        let responsePredicate = NSPredicate(format: "label CONTAINS %@", "UI Test Response")
        let responseElement = app.staticTexts.containing(responsePredicate).firstMatch
        XCTAssertTrue(responseElement.waitForExistence(timeout: 15), "Mock response should appear")
    }

    func testConversationAppearsInSidebar() {
        let messageText = "Sidebar test message"
        sendNewChatMessage(messageText)

        // Navigate to sidebar
        ensureSidebarVisible()

        // Verify conversation appears in list
        let conversationList = app.collectionViews["sidebar.conversationList"]
        XCTAssertTrue(conversationList.waitForExistence(timeout: 5), "Conversation list should exist")

        // The conversation title should match the message (auto-generated)
        let conversationTitle = app.staticTexts[messageText]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 10), "Conversation should appear in sidebar")
    }

    // MARK: - Sidebar Tests

    func testSearchConversations() {
        // Create first conversation
        sendNewChatMessage("Alpha conversation")
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Alpha conversation"].waitForExistence(timeout: 10))

        // Create second conversation
        tapNewConversationButton()
        sendNewChatMessage("Beta conversation")
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Beta conversation"].waitForExistence(timeout: 10))

        // Search for Alpha
        let searchField = app.textFields["sidebar.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should exist")
        searchField.tap()
        searchField.typeText("Alpha")

        // Verify filtering
        XCTAssertTrue(app.staticTexts["Alpha conversation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Beta conversation"].exists, "Beta should be filtered out")
    }

    func testSwipeToDeleteConversation() {
        let messageText = "Delete me"
        sendNewChatMessage(messageText)
        ensureSidebarVisible()

        // Wait for conversation to appear
        let conversationCell = app.staticTexts[messageText]
        XCTAssertTrue(conversationCell.waitForExistence(timeout: 10))

        // Swipe to delete
        conversationCell.swipeLeft()

        // Tap delete button
        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3), "Delete button should appear on swipe")
        deleteButton.tap()

        // Verify conversation is deleted
        let deletedPredicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: deletedPredicate, object: conversationCell)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "Conversation should be deleted")
    }

    // MARK: - Settings Tests

    func testSettingsSheetOpens() {
        ensureSidebarVisible()

        // Tap settings button
        let settingsButton = app.buttons["sidebar.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        settingsButton.tap()

        // Verify settings sheet appears
        let autoGenerateToggle = app.switches["settings.autoGenerateTitleToggle"]
        XCTAssertTrue(autoGenerateToggle.waitForExistence(timeout: 5), "Settings sheet should open with auto-generate toggle")
    }

    // MARK: - Model Selector Tests

    func testModelSelectorOpens() {
        // Send a message to get into a chat
        sendNewChatMessage("Model selector test")

        // Wait for chat view
        let modelSelector = app.buttons["chat.modelSelector"]
        XCTAssertTrue(modelSelector.waitForExistence(timeout: 10), "Model selector button should exist")
        modelSelector.tap()

        // Verify model selector sheet appears
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Model selector sheet should open")
    }

    // MARK: - Empty State Tests

    func testEmptyStateShowsWelcome() {
        // On iPhone, we may need to navigate to the detail view first
        // Try to tap the new conversation button if sidebar is showing
        let newButton = app.buttons["sidebar.newConversationButton"]
        if newButton.waitForExistence(timeout: 3), newButton.isHittable {
            newButton.tap()
        }

        // On first launch with no conversations, welcome view should show
        let emptyState = app.otherElements["chat.emptyState"]
        // This may or may not exist depending on whether a new chat composer is shown by default
        // If the app starts with new chat composer, the welcome text might be visible
        let welcomeText = app.staticTexts["How can I help you?"]
        let hasEmptyState = emptyState.waitForExistence(timeout: 5) || welcomeText.waitForExistence(timeout: 5)
        XCTAssertTrue(hasEmptyState, "Empty state or welcome view should be visible on fresh launch")
    }
}
