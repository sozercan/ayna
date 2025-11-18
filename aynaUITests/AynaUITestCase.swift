import XCTest

class AynaUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launchArguments += ["-AYNA_UI_TESTING", "YES"]
        app.launchEnvironment["AYNA_UI_TESTING"] = "1"
        app.launch()
        app.activate()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }
}
