import UIKit
import UniformTypeIdentifiers
import XCTest

final class IOSSmokeUITests: IOSUITestCase {
    func testComposerPastesImagesPlainTextAndMixedContent() throws {
        tapNewConversationButton()

        let pasteboard = UIPasteboard.general
        pasteboard.items = []
        defer { pasteboard.items = [] }

        let composer = try XCTUnwrap(
            app.waitForTextInput(
                identifier: "newchat.composer.textEditor",
                timeout: UITestTimeout.normal
            )
        )
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        pasteboard.image = image

        pasteFromEditMenu(into: composer)

        let attachments = app.descendants(matching: .any)["newchat.composer.attachmentsList"]
        XCTAssertTrue(
            attachments.waitForExistence(timeout: UITestTimeout.async),
            "Image paste should create a composer attachment"
        )
        XCTAssertTrue(
            app.buttons["newchat.composer.sendButton"].waitForExistence(timeout: UITestTimeout.normal),
            "Image-only paste should enable sending"
        )

        let pastedText = "Plain clipboard text"
        pasteboard.string = pastedText
        pasteFromEditMenu(into: composer)

        XCTAssertEqual(composer.value as? String, pastedText)

        let attachmentPredicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier CONTAINS %@",
            "newchat.composer.attachment.",
            ".remove."
        )
        let attachmentElements = app.descendants(matching: .any).matching(attachmentPredicate)
        let nextAttachment = attachmentElements.element(boundBy: attachmentElements.count)
        let mixedText = " plus mixed clipboard text"
        let mixedImageData = try XCTUnwrap(image.pngData())
        pasteboard.items = [[
            UTType.png.identifier: mixedImageData,
            UTType.plainText.identifier: mixedText,
        ]]

        pasteFromEditMenu(into: composer)

        XCTAssertTrue(
            nextAttachment.waitForExistence(timeout: UITestTimeout.async),
            "Mixed paste should import its image representation"
        )
        XCTAssertTrue(
            (composer.value as? String)?.contains(mixedText) == true,
            "Mixed paste should preserve its text representation"
        )
    }

    func testNewConversationCreationAndSidebarListing() {
        let messageText = "Hello from iOS UI test"

        sendNewChatMessage(messageText)

        let chatComposer = app.waitForTextInput(identifier: "chat.composer.textEditor", timeout: UITestTimeout.normal)
            ?? app.textInput(identifier: "chat.composer.textEditor")
        XCTAssertTrue(chatComposer.waitForExistence(timeout: UITestTimeout.normal), "Chat composer should appear after sending message")

        let responsePredicate = NSPredicate(format: "label CONTAINS %@", "UI Test Response")
        let responseElement = app.staticTexts.containing(responsePredicate).firstMatch
        XCTAssertTrue(responseElement.waitForExistence(timeout: UITestTimeout.async), "Mock response should appear")

        ensureSidebarVisible()

        let conversationList = app.collectionViews["sidebar.conversationList"]
        XCTAssertTrue(conversationList.waitForExistence(timeout: UITestTimeout.normal), "Conversation list should exist")

        let conversationTitle = app.staticTexts[messageText]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: UITestTimeout.async), "Conversation should appear in sidebar")
    }

    func testSelectAndReopenSavedConversation() {
        let messageText = "Reopen saved conversation test"

        sendNewChatMessage(messageText)

        let initialComposer = app.waitForTextInput(identifier: "chat.composer.textEditor", timeout: UITestTimeout.normal)
            ?? app.textInput(identifier: "chat.composer.textEditor")
        XCTAssertTrue(initialComposer.waitForExistence(timeout: UITestTimeout.normal), "Chat composer should appear after sending message")

        let responsePredicate = NSPredicate(format: "label CONTAINS %@", "UI Test Response")
        let messagePredicate = NSPredicate(format: "label CONTAINS %@", messageText)
        let initialResponse = app.staticTexts.matching(responsePredicate).firstMatch
        XCTAssertTrue(initialResponse.waitForExistence(timeout: UITestTimeout.async), "Mock response should appear")

        let conversationList = app.collectionViews["sidebar.conversationList"]

        for attempt in 1 ... 2 {
            ensureSidebarVisible()

            XCTAssertTrue(
                conversationList.waitForExistence(timeout: UITestTimeout.normal),
                "Conversation list should exist on sidebar return (attempt \(attempt))"
            )

            let savedConversationRow = conversationList.staticTexts[messageText].firstMatch
            XCTAssertTrue(
                savedConversationRow.waitForExistence(timeout: UITestTimeout.async),
                "Saved conversation row should exist in sidebar (attempt \(attempt))"
            )
            savedConversationRow.tap()

            let chatComposer = app.waitForTextInput(identifier: "chat.composer.textEditor", timeout: UITestTimeout.normal)
                ?? app.textInput(identifier: "chat.composer.textEditor")
            XCTAssertTrue(
                chatComposer.waitForExistence(timeout: UITestTimeout.normal),
                "Chat composer should appear after selecting saved conversation (attempt \(attempt))"
            )

            let messagesList = app.descendants(matching: .any)["chat.messagesList"].firstMatch
            XCTAssertTrue(
                messagesList.waitForExistence(timeout: UITestTimeout.normal),
                "Chat messages list should appear after selecting saved conversation (attempt \(attempt))"
            )
            XCTAssertTrue(
                messagesList.staticTexts.matching(messagePredicate).firstMatch.waitForExistence(timeout: UITestTimeout.async),
                "Saved user message should appear when opening conversation (attempt \(attempt))"
            )
            XCTAssertTrue(
                messagesList.staticTexts.matching(responsePredicate).firstMatch.waitForExistence(timeout: UITestTimeout.async),
                "Saved assistant response should appear when opening conversation (attempt \(attempt))"
            )
        }
    }

    func testSearchConversations() {
        sendNewChatMessage("Alpha conversation")
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Alpha conversation"].waitForExistence(timeout: UITestTimeout.async))

        tapNewConversationButton()
        sendNewChatMessage("Beta conversation")
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Beta conversation"].waitForExistence(timeout: UITestTimeout.async))

        let searchField = app.textFields["sidebar.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: UITestTimeout.normal), "Search field should exist")
        searchField.tap()
        searchField.typeText("Alpha")

        XCTAssertTrue(app.staticTexts["Alpha conversation"].waitForExistence(timeout: UITestTimeout.normal))
        XCTAssertFalse(app.staticTexts["Beta conversation"].exists, "Beta should be filtered out")
    }

    func testSwipeToDeleteConversation() {
        let messageText = "Delete me"
        sendNewChatMessage(messageText)
        ensureSidebarVisible()

        let conversationCell = app.staticTexts[messageText]
        XCTAssertTrue(conversationCell.waitForExistence(timeout: UITestTimeout.async))

        conversationCell.swipeLeft()

        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: UITestTimeout.immediate), "Delete button should appear on swipe")
        deleteButton.tap()

        let deletedPredicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: deletedPredicate, object: conversationCell)
        let result = XCTWaiter.wait(for: [expectation], timeout: UITestTimeout.normal)
        XCTAssertEqual(result, .completed, "Conversation should be deleted")
    }

    func testSettingsSheetOpens() {
        ensureSidebarVisible()

        let settingsButton = app.buttons["sidebar.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: UITestTimeout.normal), "Settings button should exist")
        settingsButton.tap()

        let autoGenerateToggle = app.switches["settings.autoGenerateTitleToggle"]
        XCTAssertTrue(autoGenerateToggle.waitForExistence(timeout: UITestTimeout.normal), "Settings sheet should open with auto-generate toggle")
    }

    func testModelSelectorOpens() {
        sendNewChatMessage("Model selector test")

        let modelSelector = app.buttons["chat.modelSelector"]
        XCTAssertTrue(modelSelector.waitForExistence(timeout: UITestTimeout.async), "Model selector button should exist")
        modelSelector.tap()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: UITestTimeout.normal), "Model selector sheet should open")
    }

    func testEmptyStateShowsWelcome() {
        tapNewConversationButton()

        let noModelsText = app.staticTexts["No Models Available"]
        XCTAssertFalse(noModelsText.exists, "Onboarding view is showing - UI test model was not configured")

        let emptyState = app.otherElements["chat.emptyState"]
        let welcomeText = app.staticTexts["How can I help you?"]
        let hasEmptyState = emptyState.waitForExistence(timeout: UITestTimeout.normal) || welcomeText.waitForExistence(timeout: UITestTimeout.normal)
        XCTAssertTrue(hasEmptyState, "Empty state or welcome view should be visible after navigating to new chat")
    }

    private func pasteFromEditMenu(into element: XCUIElement) {
        element.tap()
        element.press(forDuration: 1)

        let pasteMenuItem = app.menuItems["Paste"]
        if pasteMenuItem.waitForExistence(timeout: UITestTimeout.immediate) {
            pasteMenuItem.tap()
            return
        }

        let pasteButton = app.buttons["Paste"]
        XCTAssertTrue(
            pasteButton.waitForExistence(timeout: UITestTimeout.immediate),
            "Paste should be available in the edit menu"
        )
        pasteButton.tap()
    }
}

@MainActor
final class IOSDeepLinkUITests: IOSUITestCase {
    func testUnifiedChatShowsModelConfirmationAndCanCancel() throws {
        let url = try XCTUnwrap(
            URL(string: "ayna://chat?model=ui-deeplink-model&provider=openai&prompt=Should%20not%20send")
        )

        app.open(url)

        let addModelAlert = app.alerts["Add Model"]
        let alertAppeared = addModelAlert.waitForExistence(timeout: UITestTimeout.normal)
        XCTAssertTrue(alertAppeared, "Unified chat should require add-model confirmation")

        addModelAlert.buttons["Cancel"].tap()

        let alertDisappeared = addModelAlert.waitForNonExistence(timeout: UITestTimeout.normal)
        XCTAssertTrue(alertDisappeared, "Cancelling should dismiss model confirmation")
    }
}
