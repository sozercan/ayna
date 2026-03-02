import XCTest

/// Standardized timeout values for UI tests to improve test speed
enum UITestTimeout {
    /// For elements that should appear immediately (buttons, labels already on screen)
    static let immediate: TimeInterval = 2
    /// For elements that require navigation or state changes
    static let normal: TimeInterval = 5
    /// For elements that depend on async operations (mock network responses)
    static let async: TimeInterval = 8
}

/// Base class for watchOS UI tests with common setup/teardown
class WatchUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launchArguments += ["-AYNA_UI_TESTING", "YES"]
        app.launchEnvironment["AYNA_UI_TESTING"] = "1"
        app.launch()

        // Wait for the app to be ready
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: UITestTimeout.normal), "Watch app did not launch in time")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }

    // MARK: - Helper Methods

    /// Taps the new chat button in the conversation list
    func tapNewChatButton() {
        // Use .buttons specifically and take the first match to avoid multiple match issues
        let newChatButton = app.buttons["watch.newChatButton"].firstMatch
        XCTAssertTrue(newChatButton.waitForExistence(timeout: UITestTimeout.normal), "New chat button not found")
        newChatButton.tap()
    }

    /// Types a message in the new chat composer and submits
    func sendNewChatMessage(_ text: String) {
        let textField = app.textFields["watch.newChat.composerTextField"]
        XCTAssertTrue(textField.waitForExistence(timeout: UITestTimeout.normal), "New chat text field not found")
        textField.tap()
        textField.typeText(text)

        // Submit via keyboard return if available
        let returnKey = app.keyboards.buttons["return"]
        if returnKey.waitForExistence(timeout: UITestTimeout.immediate) {
            returnKey.tap()
        }
    }

    /// Types a message in the active chat composer and submits
    func sendChatMessage(_ text: String) {
        let textField = app.textFields["watch.chat.composerTextField"]
        XCTAssertTrue(textField.waitForExistence(timeout: UITestTimeout.normal), "Chat text field not found")
        textField.tap()
        textField.typeText(text)

        // Submit via keyboard return if available
        let returnKey = app.keyboards.buttons["return"]
        if returnKey.waitForExistence(timeout: UITestTimeout.immediate) {
            returnKey.tap()
        }
    }
}
