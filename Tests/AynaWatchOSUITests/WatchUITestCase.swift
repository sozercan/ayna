import XCTest

enum UITestTimeout {
    static let immediate: TimeInterval = 2
    static let normal: TimeInterval = 5
    static let async: TimeInterval = 8
}

class WatchUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "com.sertacozercan.ayna.watchkitapp")
        app.launchArguments += ["--ui-testing"]
        app.launchArguments += ["-AYNA_UI_TESTING", "YES"]
        app.launchEnvironment["AYNA_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: UITestTimeout.normal), "Watch app did not launch in time")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }

    func tapNewChatButton() {
        let newChatButton = app.buttons["watch.newChatButton"].firstMatch
        XCTAssertTrue(newChatButton.waitForExistence(timeout: UITestTimeout.normal), "New chat button not found")
        newChatButton.tap()
    }

    func sendNewChatMessage(_ text: String) throws {
        let textField = app.textFields["watch.newChat.composerTextField"]
        XCTAssertTrue(textField.waitForExistence(timeout: UITestTimeout.normal), "New chat text field not found")
        textField.tap()

        let hasKeyboardFocus = (textField.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        guard hasKeyboardFocus || app.keyboards.firstMatch.waitForExistence(timeout: UITestTimeout.immediate) else {
            throw XCTSkip("watchOS simulator Quickboard did not grant keyboard focus to composerTextField")
        }

        textField.typeText(text)

        let returnKey = app.keyboards.buttons["return"]
        guard returnKey.waitForExistence(timeout: UITestTimeout.immediate), returnKey.isHittable else {
            throw XCTSkip("watchOS simulator keyboard submission is unavailable")
        }
        returnKey.tap()
    }

    func sendChatMessage(_ text: String) {
        let textField = app.textFields["watch.chat.composerTextField"]
        XCTAssertTrue(textField.waitForExistence(timeout: UITestTimeout.normal), "Chat text field not found")
        textField.tap()
        textField.typeText(text)

        let returnKey = app.keyboards.buttons["return"]
        if returnKey.waitForExistence(timeout: UITestTimeout.immediate) {
            returnKey.tap()
        }
    }
}
