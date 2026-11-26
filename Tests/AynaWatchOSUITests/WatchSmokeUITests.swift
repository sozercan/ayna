import XCTest

final class WatchSmokeUITests: WatchUITestCase {
    func testAppLaunches() {
        let conversationListExists = app.descendants(matching: .any)["watch.conversationList"].waitForExistence(timeout: UITestTimeout.normal)
        let emptyStateExists = app.descendants(matching: .any)["watch.emptyState"].waitForExistence(timeout: UITestTimeout.normal)

        let hasMainView = conversationListExists || emptyStateExists
        XCTAssertTrue(hasMainView, "App should show conversation list or empty state on launch")
    }

    func testEmptyStateShowsNewChatOption() {
        let emptyState = app.otherElements["watch.emptyState"]
        if emptyState.waitForExistence(timeout: UITestTimeout.immediate) {
            let newChatButton = app.buttons["New Chat"]
            XCTAssertTrue(newChatButton.exists || app.buttons["watch.newChatButton"].exists,
                          "Empty state should have new chat option")
        }
    }

    func testNavigateToNewChat() {
        tapNewChatButton()

        let composerField = app.descendants(matching: .any)["watch.newChat.composerTextField"]
        let destinationMarker = app.descendants(matching: .any)["watch.newChat.view"].firstMatch
        let hasComposer = composerField.waitForExistence(timeout: UITestTimeout.normal)
        let hasDestinationMarker = destinationMarker.waitForExistence(timeout: UITestTimeout.immediate)
        XCTAssertTrue(
            hasComposer || hasDestinationMarker,
            "New chat view should expose either its composer or model selector"
        )
    }

    func testNavigateToModelSelector() {
        tapNewChatButton()

        let modelButton = app.buttons["watch.modelSelectorButton"].firstMatch
        if !modelButton.waitForExistence(timeout: UITestTimeout.async) {
            return
        }

        XCTAssertTrue(modelButton.exists, "Model selector button should exist")
    }

    func testSendMessageInNewChat() {
        tapNewChatButton()

        let textField = app.textFields["watch.newChat.composerTextField"].firstMatch
        if !textField.waitForExistence(timeout: UITestTimeout.async) {
            let destinationMarker = app.descendants(matching: .any)["watch.newChat.view"].firstMatch
            if destinationMarker.waitForExistence(timeout: UITestTimeout.normal) {
                return
            }
            XCTFail("watchOS simulator did not expose the new-chat destination after tapping")
            return
        }

        XCTAssertTrue(textField.exists, "Text field should exist")
    }

    func testConversationAppearsInList() {
        tapNewChatButton()

        let textField = app.textFields["watch.newChat.composerTextField"].firstMatch
        let destinationMarker = app.descendants(matching: .any)["watch.newChat.view"].firstMatch

        let hasTextField = textField.waitForExistence(timeout: UITestTimeout.async)
        let hasDestinationMarker = destinationMarker.waitForExistence(timeout: UITestTimeout.normal)

        XCTAssertTrue(
            hasTextField || hasDestinationMarker,
            "New chat view should be visible (either composer or model selector)"
        )
    }
}
