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

/// Base class for iOS UI tests with common setup/teardown
class IOSUITestCase: XCTestCase {
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
        let mainView = app.otherElements.firstMatch
        XCTAssertTrue(mainView.waitForExistence(timeout: UITestTimeout.normal), "App did not launch in time")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }

    // MARK: - Helper Methods

    /// Navigates to the sidebar (if collapsed on iPhone)
    func ensureSidebarVisible() {
        // On iPhone, the sidebar might be hidden; tap back button if present
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists, backButton.isHittable {
            backButton.tap()
        }
    }

    /// Taps the new conversation button in the sidebar
    func tapNewConversationButton() {
        // Try the bottom bar button first
        let newButton = app.buttons["sidebar.newConversationButton"]
        if newButton.waitForExistence(timeout: UITestTimeout.normal), newButton.isHittable {
            newButton.tap()
            return
        }
        
        // Fallback to empty state button if bottom bar button isn't available
        let emptyStateButton = app.buttons["sidebar.emptyState.newConversationButton"]
        XCTAssertTrue(emptyStateButton.waitForExistence(timeout: UITestTimeout.normal), "New conversation button not found")
        emptyStateButton.tap()
    }

    /// Types a message and sends it in the new chat composer
    @discardableResult
    func sendNewChatMessage(_ text: String) -> XCUIElement {
        // On iPhone, we might need to navigate to the detail view first
        // Check if the new chat composer is visible; if not, tap New Conversation button
        let composer = app.textFields["newchat.composer.textEditor"]

        if !composer.waitForExistence(timeout: UITestTimeout.immediate) {
            // Try tapping the bottom bar new conversation button first
            let newButton = app.buttons["sidebar.newConversationButton"]
            if newButton.waitForExistence(timeout: UITestTimeout.immediate), newButton.isHittable {
                newButton.tap()
                // Wait for navigation animation to complete
                _ = composer.waitForExistence(timeout: UITestTimeout.normal)
            }
            
            // If still not visible, try the empty state button (shown when no conversations exist)
            if !composer.exists {
                let emptyStateButton = app.buttons["sidebar.emptyState.newConversationButton"]
                if emptyStateButton.waitForExistence(timeout: UITestTimeout.immediate), emptyStateButton.isHittable {
                    emptyStateButton.tap()
                    // Wait for navigation animation to complete
                    _ = composer.waitForExistence(timeout: UITestTimeout.normal)
                }
            }
        }

        XCTAssertTrue(composer.waitForExistence(timeout: UITestTimeout.normal), "New chat composer not found")
        composer.tap()
        composer.typeText(text)

        let sendButton = app.buttons["newchat.composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: UITestTimeout.immediate), "Send button not found")
        sendButton.tap()

        return composer
    }

    /// Types a message and sends it in the active chat composer
    func sendChatMessage(_ text: String) {
        // iOS uses TextField, not TextEditor, so use textFields
        let composer = app.textFields["chat.composer.textEditor"]
        XCTAssertTrue(composer.waitForExistence(timeout: UITestTimeout.normal), "Chat composer not found")
        composer.tap()
        composer.typeText(text)

        let sendButton = app.buttons["chat.composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: UITestTimeout.immediate), "Send button not found")
        sendButton.tap()
    }
}
