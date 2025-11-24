import XCTest

class AynaUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        let application: XCUIApplication = MainActor.assumeIsolated {
            let application = XCUIApplication()
            application.launchArguments += ["--ui-testing"]
            application.launchArguments += ["-AYNA_UI_TESTING", "YES"]
            application.launchEnvironment["AYNA_UI_TESTING"] = "1"
            application.launch()
            application.activate()

            // Wait for the main window to appear before querying children
            let window = application.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10), "App window did not appear in time")

            return application
        }

        app = application
    }

    override func tearDownWithError() throws {
        let application = app
        MainActor.assumeIsolated {
            application?.terminate()
        }

        app = nil
        try super.tearDownWithError()
    }
}

/// Central place to keep the accessibility identifiers we rely on in UI tests.
enum TestIdentifiers {
    enum Sidebar {
        static let searchField = "sidebar.searchField"
        static let newConversationButton = "sidebar.newConversationButton"
        static let conversationList = "sidebar.conversationList"

        static func conversationRow(for conversationId: UUID) -> String {
            "sidebar.conversationRow.\(conversationId.uuidString)"
        }
    }

    enum ChatComposer {
        static let textEditor = "chat.composer.textEditor"
        static let sendButton = "chat.composer.sendButton"
    }

    enum NewChatComposer {
        static let textEditor = "newchat.composer.textEditor"
        static let sendButton = "newchat.composer.sendButton"
    }
}
