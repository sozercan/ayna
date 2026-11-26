import XCTest

enum UITestTimeout {
    static let immediate: TimeInterval = 2
    static let normal: TimeInterval = 5
    static let async: TimeInterval = 8
}

extension XCUIApplication {
    func textInput(identifier: String) -> XCUIElement {
        let textField = textFields[identifier]
        let textView = textViews[identifier]
        return textField.exists ? textField : textView
    }

    func waitForTextInput(identifier: String, timeout: TimeInterval) -> XCUIElement? {
        let textField = textFields[identifier]
        let textView = textViews[identifier]

        if textField.waitForExistence(timeout: timeout / 2) {
            return textField
        }
        if textView.waitForExistence(timeout: timeout / 2) {
            return textView
        }
        return nil
    }
}

class IOSUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "com.sertacozercan.ayna")
        app.launchArguments += ["--ui-testing"]
        app.launchArguments += ["-AYNA_UI_TESTING", "YES"]
        app.launchEnvironment["AYNA_UI_TESTING"] = "1"
        app.launch()

        let mainView = app.otherElements.firstMatch
        XCTAssertTrue(mainView.waitForExistence(timeout: UITestTimeout.normal), "App did not launch in time")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }

    func ensureSidebarVisible() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists, backButton.isHittable {
            backButton.tap()
        }
    }

    func tapNewConversationButton() {
        let newButton = app.buttons["sidebar.newConversationButton"]
        if newButton.waitForExistence(timeout: UITestTimeout.normal), newButton.isHittable {
            newButton.tap()
            return
        }

        let emptyStateButton = app.buttons["sidebar.emptyState.newConversationButton"]
        XCTAssertTrue(emptyStateButton.waitForExistence(timeout: UITestTimeout.normal), "New conversation button not found")
        emptyStateButton.tap()
    }

    @discardableResult
    func sendNewChatMessage(_ text: String) -> XCUIElement {
        var composer = app.waitForTextInput(identifier: "newchat.composer.textEditor", timeout: UITestTimeout.immediate)

        if composer == nil {
            let newButton = app.buttons["sidebar.newConversationButton"]
            if newButton.waitForExistence(timeout: UITestTimeout.immediate), newButton.isHittable {
                newButton.tap()
                composer = app.waitForTextInput(identifier: "newchat.composer.textEditor", timeout: UITestTimeout.normal)
            }

            if composer == nil {
                let emptyStateButton = app.buttons["sidebar.emptyState.newConversationButton"]
                if emptyStateButton.waitForExistence(timeout: UITestTimeout.immediate), emptyStateButton.isHittable {
                    emptyStateButton.tap()
                    composer = app.waitForTextInput(identifier: "newchat.composer.textEditor", timeout: UITestTimeout.normal)
                }
            }
        }

        let finalComposer = composer ?? app.textInput(identifier: "newchat.composer.textEditor")
        XCTAssertTrue(finalComposer.waitForExistence(timeout: UITestTimeout.normal), "New chat composer not found")
        finalComposer.tap()
        finalComposer.typeText(text)

        let sendButton = app.buttons["newchat.composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: UITestTimeout.immediate), "Send button not found")
        sendButton.tap()

        return finalComposer
    }

    func sendChatMessage(_ text: String) {
        let composer = app.waitForTextInput(identifier: "chat.composer.textEditor", timeout: UITestTimeout.normal)
            ?? app.textInput(identifier: "chat.composer.textEditor")
        XCTAssertTrue(composer.waitForExistence(timeout: UITestTimeout.normal), "Chat composer not found")
        composer.tap()
        composer.typeText(text)

        let sendButton = app.buttons["chat.composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: UITestTimeout.immediate), "Send button not found")
        sendButton.tap()
    }
}
