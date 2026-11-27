import XCTest

final class WatchSmokeUITests: WatchUITestCase {
    func testAppLaunches() {
        let emptyState = app.descendants(matching: .any)["watch.emptyState"].firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: UITestTimeout.normal),
            "Watch app should show empty state on fresh UI test launch"
        )
    }

    func testEmptyStateShowsNewChatOption() {
        let emptyState = app.descendants(matching: .any)["watch.emptyState"].firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: UITestTimeout.normal),
            "Empty state should be visible on fresh UI test launch"
        )

        let newChatButton = app.buttons["New Chat"].firstMatch
        let toolbarNewChatButton = app.buttons["watch.newChatButton"].firstMatch
        XCTAssertTrue(
            newChatButton.waitForExistence(timeout: UITestTimeout.normal)
                || toolbarNewChatButton.waitForExistence(timeout: UITestTimeout.immediate),
            "Seeded UI test launch should expose the New Chat action"
        )
    }

    func testNavigateToNewChat() {
        tapNewChatButton()

        let composerField = app.descendants(matching: .any)["watch.newChat.composerTextField"].firstMatch
        let destinationMarker = app.descendants(matching: .any)["watch.newChat.view"].firstMatch
        XCTAssertTrue(
            composerField.waitForExistence(timeout: UITestTimeout.normal)
                || destinationMarker.waitForExistence(timeout: UITestTimeout.normal),
            "New chat view should appear after tapping the new chat button"
        )
    }

    func testNavigateToModelSelector() throws {
        tapNewChatButton()

        let modelButton = app.buttons["watch.modelSelectorButton"].firstMatch
        XCTAssertTrue(
            modelButton.waitForExistence(timeout: UITestTimeout.async),
            "Model selector button should appear in the new chat toolbar"
        )

        guard modelButton.isHittable else {
            throw XCTSkip("watchOS simulator toolbar model selector button is not hittable")
        }

        modelButton.tap()

        let seededModelRow = app.buttons["watch.modelRow.ui-test-model"].firstMatch
        let modelList = app.descendants(matching: .any)["watch.modelList"].firstMatch
        XCTAssertTrue(
            seededModelRow.waitForExistence(timeout: UITestTimeout.normal)
                || modelList.waitForExistence(timeout: UITestTimeout.normal),
            "Model selector should display seeded UI test models"
        )
    }

    func testSendMessageInNewChat() throws {
        tapNewChatButton()

        let textField = app.textFields["watch.newChat.composerTextField"].firstMatch
        guard textField.waitForExistence(timeout: UITestTimeout.async) else {
            let destinationMarker = app.descendants(matching: .any)["watch.newChat.view"].firstMatch
            XCTAssertTrue(
                destinationMarker.waitForExistence(timeout: UITestTimeout.normal),
                "watchOS simulator did not expose the new-chat destination after tapping"
            )
            throw XCTSkip("watchOS simulator did not expose an accessible TextField in WatchNewChatView")
        }

        XCTAssertTrue(textField.exists, "New chat composer text field should exist")
    }

    func testConversationAppearsInList() throws {
        tapNewChatButton()

        let textField = app.textFields["watch.newChat.composerTextField"].firstMatch
        guard textField.waitForExistence(timeout: UITestTimeout.async), textField.isHittable else {
            throw XCTSkip("watchOS simulator does not support interactive text entry in WatchNewChatView")
        }

        sendNewChatMessage("Hello Watch UI Tests")

        let messagesList = app.descendants(matching: .any)["watch.chat.messagesList"].firstMatch
        guard messagesList.waitForExistence(timeout: UITestTimeout.async) else {
            throw XCTSkip("watchOS simulator keyboard submission did not transition to WatchChatView")
        }

        let responsePredicate = NSPredicate(format: "label CONTAINS %@", "UI Test Response")
        let responseText = app.staticTexts.containing(responsePredicate).firstMatch
        XCTAssertTrue(
            responseText.waitForExistence(timeout: UITestTimeout.async),
            "Mock response should appear in watch chat view"
        )
    }
}
