import XCTest

/// Smoke tests for iOS app - covers critical user flows
final class IOSSmokeUITests: IOSUITestCase {
    // MARK: - Conversation Tests

    /// Combined test: verifies conversation creation, response, and sidebar listing
    func testNewConversationCreationAndSidebarListing() {
        let messageText = "Hello from iOS UI test"

        // Start a new conversation
        sendNewChatMessage(messageText)

        // Verify the chat composer appears (indicating we're now in an active chat)
        // iOS uses TextField, not TextEditor, so use textFields
        let chatComposer = app.textFields["chat.composer.textEditor"]
        XCTAssertTrue(chatComposer.waitForExistence(timeout: UITestTimeout.normal), "Chat composer should appear after sending message")

        // Verify response appears (mock response in test environment)
        let responsePredicate = NSPredicate(format: "label CONTAINS %@", "UI Test Response")
        let responseElement = app.staticTexts.containing(responsePredicate).firstMatch
        XCTAssertTrue(responseElement.waitForExistence(timeout: UITestTimeout.async), "Mock response should appear")

        // Navigate to sidebar and verify conversation appears
        ensureSidebarVisible()

        let conversationList = app.collectionViews["sidebar.conversationList"]
        XCTAssertTrue(conversationList.waitForExistence(timeout: UITestTimeout.normal), "Conversation list should exist")

        // The conversation title should match the message (auto-generated)
        let conversationTitle = app.staticTexts[messageText]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: UITestTimeout.async), "Conversation should appear in sidebar")
    }

    // MARK: - Sidebar Tests

    func testSearchConversations() {
        // Create first conversation
        sendNewChatMessage("Alpha conversation")
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Alpha conversation"].waitForExistence(timeout: UITestTimeout.async))

        // Create second conversation
        tapNewConversationButton()
        sendNewChatMessage("Beta conversation")
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Beta conversation"].waitForExistence(timeout: UITestTimeout.async))

        // Search for Alpha
        let searchField = app.textFields["sidebar.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: UITestTimeout.normal), "Search field should exist")
        searchField.tap()
        searchField.typeText("Alpha")

        // Verify filtering
        XCTAssertTrue(app.staticTexts["Alpha conversation"].waitForExistence(timeout: UITestTimeout.normal))
        XCTAssertFalse(app.staticTexts["Beta conversation"].exists, "Beta should be filtered out")
    }

    func testSwipeToDeleteConversation() {
        let messageText = "Delete me"
        sendNewChatMessage(messageText)
        ensureSidebarVisible()

        // Wait for conversation to appear
        let conversationCell = app.staticTexts[messageText]
        XCTAssertTrue(conversationCell.waitForExistence(timeout: UITestTimeout.async))

        // Swipe to delete
        conversationCell.swipeLeft()

        // Tap delete button
        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: UITestTimeout.immediate), "Delete button should appear on swipe")
        deleteButton.tap()

        // Verify conversation is deleted
        let deletedPredicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: deletedPredicate, object: conversationCell)
        let result = XCTWaiter.wait(for: [expectation], timeout: UITestTimeout.normal)
        XCTAssertEqual(result, .completed, "Conversation should be deleted")
    }

    // MARK: - Settings Tests

    func testSettingsSheetOpens() {
        ensureSidebarVisible()

        // Tap settings button
        let settingsButton = app.buttons["sidebar.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: UITestTimeout.normal), "Settings button should exist")
        settingsButton.tap()

        // Verify settings sheet appears
        let autoGenerateToggle = app.switches["settings.autoGenerateTitleToggle"]
        XCTAssertTrue(autoGenerateToggle.waitForExistence(timeout: UITestTimeout.normal), "Settings sheet should open with auto-generate toggle")
    }

    // MARK: - Model Selector Tests

    func testModelSelectorOpens() {
        // Send a message to get into a chat
        sendNewChatMessage("Model selector test")

        // Wait for chat view
        let modelSelector = app.buttons["chat.modelSelector"]
        XCTAssertTrue(modelSelector.waitForExistence(timeout: UITestTimeout.async), "Model selector button should exist")
        modelSelector.tap()

        // Verify model selector sheet appears
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: UITestTimeout.normal), "Model selector sheet should open")
    }

    // MARK: - Empty State Tests

    func testEmptyStateShowsWelcome() {
        // On iPhone, we may need to navigate to the detail view first
        // Try to tap the new conversation button if sidebar is showing
        let newButton = app.buttons["sidebar.newConversationButton"]
        if newButton.waitForExistence(timeout: UITestTimeout.immediate), newButton.isHittable {
            newButton.tap()
        }

        // On first launch with no conversations, welcome view should show
        let emptyState = app.otherElements["chat.emptyState"]
        // This may or may not exist depending on whether a new chat composer is shown by default
        // If the app starts with new chat composer, the welcome text might be visible
        let welcomeText = app.staticTexts["How can I help you?"]
        let hasEmptyState = emptyState.waitForExistence(timeout: UITestTimeout.normal) || welcomeText.waitForExistence(timeout: UITestTimeout.normal)
        XCTAssertTrue(hasEmptyState, "Empty state or welcome view should be visible on fresh launch")
    }
}
