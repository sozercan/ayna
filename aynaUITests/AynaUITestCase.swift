import XCTest

class AynaUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        let application = XCUIApplication()
        application.launchArguments += ["--ui-testing"]
        application.launchArguments += ["-AYNA_UI_TESTING", "YES"]
        application.launchEnvironment["AYNA_UI_TESTING"] = "1"
        application.launch()
        application.activate()

        // Wait for the main window to appear before querying children
        let window = application.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window did not appear in time")

        app = application
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil

        try super.tearDownWithError()
    }
}
